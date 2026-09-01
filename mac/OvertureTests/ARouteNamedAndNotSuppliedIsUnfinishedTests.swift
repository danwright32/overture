import Testing
import Foundation
import SwiftData

// #3358 Phase 2, the last of the three siblings it named for "the run did not finish".
//
// Phase 2's constraint is that a verdict the run never earned be impossible to STORE. Two of its three
// siblings are closed: an unsupported results version (#3449) and a run whose own records say it did not
// finish (#3451, #3455). This is the third, and it is different from both because the run finished
// perfectly well and fell short on ONE show.
//
// `EmptyReason.routeNamedButNotSupplied` is the run declaring a way in and supplying none: `method:
// "form_or_dm"` with no `formUrl`, a named decision maker or a generic inbox with no address.
// `Reachability.swift`'s own comment for it says exactly what that means, and says it better than this
// one could: "`namedButNoRoute` is a fact about the WORLD (these people publish nothing), and this is a
// fact about the RUN (it stated a route type and did not finish the step that finds one)."
//
// So it was the one empty reason that says the search did not finish, and it was stored as a settled
// negative with a 90 day lockout, which is the exact shape Phase 2 exists to make unrecordable. The card
// even told Dan "another check is worth more here than a search by hand" while the candidacy rule
// refused to include the show in one for three months (L111).
//
// IT HAS NEVER BEEN WRITTEN ON THIS STORE: 0 rows on 2026-09-01, against seven `emptyReason` values that
// do appear. So its behaviour was UNMEASURED rather than proven benign (L90), and this decides the rule
// before the situation exists rather than after it has cost something.
@MainActor
@Suite("A route named and not supplied is an unfinished search (#3358 Phase 2)")
struct ARouteNamedAndNotSuppliedIsUnfinishedTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let now = Date(timeIntervalSince1970: 1_756_580_000)

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-04-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // A contact naming `form_or_dm` and carrying no form URL: the shape `declaredRouteIsMissing` is
    // written for, and the one #2893 built the reason from.
    private func routeNamedNotSupplied() -> PrepContact {
        PrepContact(name: "Wren Ashbourne", role: "Producer", email: nil,
                    method: "form_or_dm", confidence: "medium", formUrl: nil, provenance: "presenter")
    }

    private func ingest(_ ctx: ModelContext, key: String, contacts: [PrepContact]) {
        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now",
                                            results: [PrepResult(naturalKey: key, contacts: contacts)],
                                            webCalls: PrepResults.WebCalls(recorded: true, total: 8,
                                                                           items: 1, capPerItem: 18,
                                                                           allowance: 18),
                                            runCost: PrepResults.RunCost(recorded: true)),
                                into: ctx, now: now, isProbe: true)
    }

    // THE DEFECT. The run said there was a way in, gave none, and the show was written off for 90 days.
    @Test func aShowWhoseRouteWasNamedAndNotSuppliedIsNotWrittenOff() throws {
        let ctx = ModelContext(try container())
        let key = "kestrel|2027-04-18|rowan hall"
        let p = show(ctx, key)
        p.reachabilityProbedAt = now
        p.reachabilityResult = .noEmailFound

        ingest(ctx, key: key, contacts: [routeNamedNotSupplied()])

        #expect(p.reachabilityProbedAt == nil, "a search that did not finish started a 90 day lockout")
        #expect(p.reachabilityResult == nil, "and stored a verdict the run never earned")
        #expect(p.reachabilityUnansweredAt == now, "and did not route to the unanswered path")
        #expect(Reachability.wasMissedByACheck(probedAt: p.reachabilityProbedAt,
                                               unansweredAt: p.reachabilityUnansweredAt,
                                               now: now.addingTimeInterval(86_400)),
                "so the card cannot offer the re-check its own sentence recommends")
    }

    // The stored REASON goes with it, and that is not an omission. Every `EmptyReason` renders only
    // under the `.noEmailFound` badge (`ProspectRowView`), so a reason left on a row carrying no verdict
    // is counted for a claim no card makes, which is #3430's defect exactly. What the run did wrong is a
    // fact about the RUN and is reported per run by `RunInstructionCompliance`, which is the right unit
    // for it and already existed.
    @Test func noReasonIsStoredForAClaimTheCardCanNoLongerMake() throws {
        let ctx = ModelContext(try container())
        let key = "kestrel|2027-04-18|rowan hall"
        let p = show(ctx, key)
        p.reachabilityEmptyReason = .nothingPublished

        ingest(ctx, key: key, contacts: [routeNamedNotSupplied()])

        #expect(p.reachabilityEmptyReason == nil)
    }

    // THE BOUNDARY, and the reason this is a narrow change rather than a broad one. Every OTHER empty
    // reason is a fact about the show and stays a settled answer: the check finished, and what it found
    // is the answer. Asserted over the whole vocabulary rather than a sample, so a reason added later
    // has to decide which side it is on rather than inheriting one (L113).
    @Test func everyOtherEmptyReasonStillSettlesTheShow() throws {
        for reason in Reachability.EmptyReason.allCases where reason != .routeNamedButNotSupplied {
            let ctx = ModelContext(try container())
            let key = "kestrel|2027-04-18|rowan hall"
            let p = show(ctx, key)

            _ = PrepImporter.ingest(
                PrepResults(version: 2, generatedAt: "now",
                            results: [PrepResult(naturalKey: key, contacts: nil,
                                                 emptyReason: reason.rawValue)],
                            webCalls: PrepResults.WebCalls(recorded: true, total: 8, items: 1,
                                                           capPerItem: 18, allowance: 18),
                            runCost: PrepResults.RunCost(recorded: true)),
                into: ctx, now: now, isProbe: true)

            #expect(p.reachabilityProbedAt == now, "\(reason.rawValue) stopped settling the show")
            #expect(p.reachabilityEmptyReason == reason, "\(reason.rawValue) was not stored")
        }
    }

    // And a run that supplied a real route is untouched, so the rule above cannot pass by refusing every
    // answer that carries a contact (L159).
    @Test func aContactThatSuppliesItsRouteStillSettlesTheShow() throws {
        let ctx = ModelContext(try container())
        let key = "kestrel|2027-04-18|rowan hall"
        let p = show(ctx, key)

        ingest(ctx, key: key, contacts: [
            PrepContact(name: "Wren Ashbourne", role: "Producer", email: nil, method: "form_or_dm",
                        confidence: "medium", formUrl: "https://kestrelquartet.example/contact",
                        provenance: "presenter")
        ])

        #expect(p.reachabilityProbedAt == now)
        #expect(p.reachabilityResult == .contactFormOnly)
    }

    // A mixed answer: one contact supplies its route and another names one it does not. The show is
    // reachable, so it settles. `emptyReason` is only asked when NOTHING usable survived, and this
    // asserts that boundary holds rather than assuming it, because the reason is computed first among
    // its three and a rule reading it too eagerly would throw away a real address.
    @Test func oneBadContactBesideAGoodOneDoesNotUnsettleTheShow() throws {
        let ctx = ModelContext(try container())
        let key = "kestrel|2027-04-18|rowan hall"
        let p = show(ctx, key)

        ingest(ctx, key: key, contacts: [
            routeNamedNotSupplied(),
            PrepContact(name: "Mira Vance", role: "Producer", email: "mira@kestrelquartet.example",
                        method: "named_decision_maker", confidence: "high", formUrl: nil,
                        provenance: "presenter")
        ])

        #expect(p.reachabilityProbedAt == now)
        #expect(p.reachabilityResult == .emailFound)
        #expect(p.reachabilityEmptyReason == nil)
    }

    // THE SIBLING, and it was found by mutation rather than by reading. Widening the computed branch to
    // fire on every reason left `everyOtherEmptyReasonStillSettlesTheShow` green, which could only mean
    // that test drives a DIFFERENT branch: `emptyReason(afterIngesting:)` is only asked when the run
    // emitted contacts, and a run may also DECLARE the reason on an entry carrying none.
    //
    // Both are the run saying it did not finish this show's search, so both unsettle. The rule lives on
    // `EmptyReason` itself for exactly this reason: two spellings of one rule become two rules (L263).
    @Test func aRunThatDECLARESTheReasonWithNoContactsAlsoLeavesTheShowUnsettled() throws {
        let ctx = ModelContext(try container())
        let key = "kestrel|2027-04-18|rowan hall"
        let p = show(ctx, key)

        _ = PrepImporter.ingest(
            PrepResults(version: 2, generatedAt: "now",
                        results: [PrepResult(naturalKey: key, contacts: nil,
                                             emptyReason: "route_named_but_not_supplied")],
                        webCalls: PrepResults.WebCalls(recorded: true, total: 8, items: 1,
                                                       capPerItem: 18, allowance: 18),
                        runCost: PrepResults.RunCost(recorded: true)),
            into: ctx, now: now, isProbe: true)

        #expect(p.reachabilityProbedAt == nil)
        #expect(p.reachabilityResult == nil)
        #expect(p.reachabilityEmptyReason == nil)
        #expect(p.reachabilityUnansweredAt == now)
    }

    // The rule is ONE predicate on the vocabulary, and exactly one case answers yes. Asserted over
    // `allCases` so a reason added later has to decide rather than inherit, and so this cannot quietly
    // grow to cover a reason that is a fact about the show (L113).
    @Test func exactlyOneEmptyReasonSaysTheSearchDidNotFinish() {
        let unfinished = Reachability.EmptyReason.allCases.filter(\.meansTheSearchDidNotFinish)

        #expect(unfinished == [.routeNamedButNotSupplied])
    }
}
