import Testing
import Foundation
import SwiftData

// #3654 step 4e: narrowing which cards are built cannot change what any card SAYS.
//
// THE CLAIM THIS EXISTS TO DEFEND is the safety argument the whole phase rests on. Every whole-corpus
// table a card is decorated from (`venueBrands`, the organisation ledger's inherited answers, the
// engagement link groups, the per-organisation row counts, the source calendar index) is built from the
// FULL corpus whatever the key set says, so asking for three cards instead of 1,224 changes which ones
// exist and nothing about their content. That is easy to state and easy to break: any one of those tables
// built from `prospects` narrowed to the drawn rows would silently change a presenter line, a linked
// engagement note or a correction control on precisely the rows nobody was looking at when they were
// decided.
//
// THE ORACLE IS THE SHIPPING FUNCTION, invoked with every key requested. It is not a copy kept in the
// test target: a copy is a second definition only tests exercise, so every later change to card
// construction has to be applied to it by hand or the oracle silently agrees with an app that no longer
// exists, and its shared name suppresses anyone diffing the two (L107, L263).
//
// THE COMPARISON IS DERIVED, NEVER LISTED. Hand-writing the fields would check what somebody remembered
// on the day, and a field added later would be exempt from the very test written to catch it (L96). This
// reflects each card and compares every stored member by name.
@MainActor
@Suite("A card built for a narrowed set says exactly what the full build says (#3654)")
struct NarrowedCardsAgreeWithFullOnesTests {
    private static let corpusSize = 40

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, OrgReachabilityAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    /// A corpus shaped so the whole-corpus tables actually have something to say: several shows share a
    /// presenter (so `venueBrands` and the organisation row counts are non-trivial), several share a
    /// production name on different nights (so `EngagementLink` groups them), and a minority carry
    /// contacts, which is the live shape (`LiveContactShape`, L102).
    private func seed(_ ctx: ModelContext) -> [Prospect] {
        var out: [Prospect] = []
        for n in 0..<Self.corpusSize {
            let p = Prospect(naturalKey: "k\(n)", groupName: "Production \(n % 6)", discipline: "choral",
                             venue: "Room \(n % 4)",
                             performanceDate: "2099-02-\(String(format: "%02d", n % 27 + 1))",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered",
                             fitScore: n % 10, tier: n % 2 == 0 ? "high" : "mid", fitReason: "r",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
            p.presenter = "Company \(n % 5)"
            if n % 5 == 0 { p.sentAt = Date() }
            if n % 8 == 0 { p.draftBody = LiveContactShape.draftBody }
            if n % 9 == 0 { p.runNights = ["2099-02-01", "2099-02-02"] }
            ctx.insert(p)
            if n % 4 == 0 {
                let r = Recipient(id: "c\(n)@example.invalid", email: "c\(n)@example.invalid",
                                  name: "Contact \(n)", provenance: .act)
                r.sendState = n % 8 == 0 ? .sent : .pending
                p.recipients.append(r)
            }
            out.append(p)
        }
        return out
    }

    private func differences(_ narrow: QueueItem, _ full: QueueItem) -> [String] {
        let fullFields = Dictionary(uniqueKeysWithValues:
            Mirror(reflecting: full).children.compactMap { child -> (String, Any)? in
                child.label.map { ($0, child.value) }
            })
        var out: [String] = []
        for child in Mirror(reflecting: narrow).children {
            guard let label = child.label else { continue }
            guard let other = fullFields[label] else {
                out.append("\(label): the full build has no such field")
                continue
            }
            if String(describing: child.value) != String(describing: other) {
                out.append("\(label): narrowed \(child.value) against full \(other)")
            }
        }
        return out
    }

    /// Every card in a NARROWED build, compared field by field with the same card from a build that asked
    /// for everything.
    private func compare(narrowedTo wanted: Set<String>, resolvingOnTheSpot onTheSpot: Bool = false)
        throws -> Int {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        try ctx.save()

        let narrowed = QueueModel.scope(from: shows, corpus: shows, cardKeys: wanted)
        let full = QueueModel.scope(from: shows, corpus: shows)

        var compared = 0
        for row in narrowed.rows {
            let mine: QueueItem?
            if onTheSpot {
                // The other half of the mechanism: a card the pass did NOT prebuild, resolved when the
                // row arrives on screen. It must be the same card, because it is decorated from the same
                // tables, and this is where that would break first if the store stopped keeping them.
                mine = narrowed.cards.card(for: row)
            } else {
                mine = narrowed.cards.alreadyBuilt(row.id)
                if mine == nil { continue }
            }
            let theirs = try #require(full.cards.alreadyBuilt(row.id))
            let diffs = differences(try #require(mine), theirs)
            #expect(diffs.isEmpty, Comment(rawValue:
                "the card for \(row.id) differs between a narrowed build and a full one: "
                + diffs.joined(separator: "; ")))
            compared += 1
        }
        return compared
    }

    @Test func aPrebuiltCardMatchesTheFullBuild() throws {
        let compared = try compare(narrowedTo: ["k3", "k7", "k11"])
        #expect(compared == 3, "the narrowed build did not produce the three cards this compares")
    }

    // THE case the store exists for: a row that scrolls into view after the pass has already run.
    @Test func aCardBuiltOnTheSpotMatchesTheFullBuild() throws {
        let compared = try compare(narrowedTo: ["k3"], resolvingOnTheSpot: true)
        #expect(compared == Self.corpusSize,
                "every row should have been resolvable, either prebuilt or built on the spot")
    }

    // The matrix must be seen to FIRE and not only to agree, or it reads as continuous verification while
    // measuring nothing (L1, L557). This is that demonstration, kept rather than done once by hand: two
    // cards that really do differ are reported, and the report NAMES the field.
    @Test func theComparisonReportsAFieldThatReallyDiffers() throws {
        let ctx = ModelContext(try container())
        let shows = seed(ctx)
        try ctx.save()
        let built = QueueModel.scope(from: shows, corpus: shows)
        var mine = try #require(built.cards.alreadyBuilt("k3"))
        let theirs = try #require(built.cards.alreadyBuilt("k3"))
        mine.presenterLine = "something else entirely"

        let diffs = differences(mine, theirs)

        #expect(diffs.count == 1)
        #expect(diffs.first?.hasPrefix("presenterLine:") == true, Comment(rawValue:
            "the comparison found a difference and could not say which field, so a real divergence would "
            + "arrive as a wall of text rather than as a name: \(diffs)"))
    }
}
