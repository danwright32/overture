import Testing
import Foundation
import SwiftData

// #2758 / #2999: which row an incoming show belongs to, and what happens when the store cannot say.
//
// The scout's upsert picks between five arms, and every arm below the first WRITES the incoming key onto
// a stored row. Each is safe only because the first arm proved nobody holds that key. Every one of those
// reads was `try?`, which cannot tell "nobody holds this key" from "the store could not answer", and the
// two lead to opposite outcomes.
//
// What the wrong one costs was measured under #2754: a key collision does NOT throw. `save()` succeeds
// and SwiftData MERGES the two rows into one, taking some fields from each, so a card's keep decision,
// its contacts and its outreach record go with no error raised anywhere (L5, L105).
//
// `RunNightDrop` already refuses this exact situation with a three-answer read. This is its sibling on
// the scout's path (L30), and the seam is the same one: the lookups are closures, because a healthy
// in-memory store never throws and a fixture that only ever asks one proves nothing about the branch
// that matters most (L140).
@MainActor
@Suite("Which row the scout's upsert should land on (#2758)")
struct ScoutUpsertTargetTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func prospect(_ key: String, in ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                         venue: "Carnegie Hall", performanceDate: "2026-11-14",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 9, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private struct StoreIsDown: Error {}

    private func target(storedByKey: @escaping () throws -> Prospect? = { nil },
                        byConcert: @escaping () throws -> Prospect? = { nil },
                        byAnyRunURL: @escaping () throws -> Prospect? = { nil },
                        byStableSource: @escaping () throws -> Prospect? = { nil })
    -> ScoutService.UpsertTarget {
        ScoutService.upsertTarget(storedByKey: storedByKey, byConcert: byConcert,
                                  byAnyRunURL: byAnyRunURL, byStableSource: byStableSource)
    }

    // The ordinary case, and the one that makes every arm below it safe.
    @Test func anExactKeyMatchIsUpdatedInPlace() throws {
        let ctx = ModelContext(try container())
        let held = prospect("aurora|2026-11-14|carnegie", in: ctx)

        #expect(target(storedByKey: { held }) == .updateInPlace(held))
    }

    // A key nobody holds, with nothing to re-key: a new row.
    @Test func aFreeKeyWithNoMatchIsAnInsert() throws {
        #expect(target() == .insert)
    }

    // Each of the three re-key arms, in the order the upsert asks them, since the order is the rule:
    // a concert identity beats a shared run URL beats a stable source listing.
    @Test func aFreeKeyWithAMatchIsARekey() throws {
        let ctx = ModelContext(try container())
        let concert = prospect("by-concert", in: ctx)
        let byURL = prospect("by-url", in: ctx)
        let stable = prospect("by-source", in: ctx)

        #expect(target(byConcert: { concert }, byAnyRunURL: { byURL }, byStableSource: { stable })
                == .reKey(concert))
        #expect(target(byAnyRunURL: { byURL }, byStableSource: { stable }) == .reKey(byURL))
        #expect(target(byStableSource: { stable }) == .reKey(stable))
    }

    // THE refusal. A store that cannot answer must never read as a key nobody holds, because the arms
    // below the first would then write that key onto a row and merge two shows.
    @Test func aStoreThatCannotAnswerRefusesTheRow() throws {
        #expect(target(storedByKey: { throw StoreIsDown() }) == .storeUnreadable)
    }

    // The three real fetches must PROPAGATE a failed read, which the seam above cannot see: it injects
    // closures, so a helper that put `try?` back would go on satisfying every test here (measured with
    // `scripts/mutate.sh`, which reported SURVIVED). A source guard is the only reader that can reach the
    // property, since the helpers are private and a healthy in-memory store never throws.
    @Test func theRealLookupsDoNotSwallowAFailedRead() {
        let source = SourceGuardHelper.source("Overture/Integration/ScoutService.swift")
        #expect(!source.isEmpty, "the guard read no source, so every check below passes on nothing")

        for helper in ["matchByConcertIdentity", "matchByAnyRunURL", "matchByStableSource"] {
            guard let declaration = source.range(of: "private static func \(helper)") else {
                Issue.record(Comment(rawValue: "\(helper) is not declared where this guard looks"))
                continue
            }
            // The signature runs to its opening brace; `throws` has to be inside it.
            let signature = source[declaration.lowerBound...].prefix(while: { $0 != "{" })
            #expect(signature.contains("throws"),
                    Comment(rawValue: "\(helper) no longer declares throws, so an unreadable store reads "
                            + "as no match and the chain falls through to the most destructive arm"))

            // And the BODY has to propagate, which the signature does not say: a helper declared `throws`
            // that swallows its own fetch satisfies the line above while behaving exactly as before.
            // Measured with `scripts/mutate.sh`: putting `try?` back inside a body was reported SURVIVED
            // while this guard read only the signature.
            let afterSignature = source[declaration.lowerBound...].dropFirst(signature.count)
            let body = afterSignature.range(of: "\n    private static func").map {
                String(afterSignature[..<$0.lowerBound])
            } ?? String(afterSignature)
            #expect(!body.contains("try?"),
                    Comment(rawValue: "\(helper) swallows its own read, so a store that cannot answer "
                            + "reads as no match rather than reaching the refusal"))
        }
        // And the call site hands those helpers through UNSWALLOWED. Scoped to the `upsertTarget(` call
        // rather than the whole file on purpose: ScoutService has three other `try?` prospect fetches
        // (the repeat-client history, the reconcile's stored set, the venue-brand corpus), and each of
        // those DEGRADES on an unreadable store rather than destroying anything, so a file-wide rule
        // would condemn three correct lines and be switched off (L93).
        guard let call = source.range(of: "switch upsertTarget(") else {
            Issue.record("the upsert no longer calls upsertTarget, so this guard reads nothing")
            return
        }
        let closures = source[call.lowerBound...].prefix(while: { $0 != ")" || false }).prefix(1200)
        #expect(!closures.contains("try?"),
                "a lookup handed to upsertTarget swallows its own failure, so the refusal never fires")
    }

    // And it refuses on EVERY read, not only the first. The other three fetch too, so a store that stops
    // answering partway sends the chain to the final insert, which is the most destructive of the five:
    // it puts a new row on a key another row already holds.
    @Test func aStoreThatStopsAnsweringPartWayThroughAlsoRefuses() throws {
        let ctx = ModelContext(try container())
        let stable = prospect("by-source", in: ctx)

        #expect(target(byConcert: { throw StoreIsDown() }) == .storeUnreadable)
        #expect(target(byAnyRunURL: { throw StoreIsDown() }) == .storeUnreadable)
        #expect(target(byStableSource: { throw StoreIsDown() }) == .storeUnreadable)
        // The refusal is not "anything threw anywhere": a later read that would not have been reached
        // cannot refuse a row the earlier arms already settled.
        #expect(target(byConcert: { stable }, byAnyRunURL: { throw StoreIsDown() }) == .reKey(stable))
    }
}
