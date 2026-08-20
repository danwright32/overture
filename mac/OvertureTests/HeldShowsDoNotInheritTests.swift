import Testing
import Foundation

// #3014, phase 6 of the revised #2765 plan. The organisation fan-out, and Dan's call of 2026-08-18:
// BLOCK THE SPREADING, do not widen the exclusion to the organisation.
//
// `OrgAnswerLedger.inherited` moves one organisation's answer onto its sibling shows. So a check on org
// X's show A can change what is displayed on org X's show C while a prep is drafting C, and NEITHER run's
// key set contains C. Show-level exclusion cannot see that, which is why widening the exclusion was the
// obvious answer and the wrong one: it would take shows out of a paid run to protect against a fan-out
// measured at ZERO on the live store (0 of 724 shows inheriting on 2026-07-29, all 12 stored
// `OrgReachabilityAnswer` rows refused by `ProducerGate.qualifies`). Blocking the spreading closes the
// same hole precisely, costs no show its place in a run, and keeps working if the fan-out ever becomes
// live, which the widening answer would only appear to.
//
// `heldKeys` carries NO DEFAULT. `inherited` already ends `overrides: ProducerOverrides = .none`, and
// cloning that shape would hand every existing caller and every existing test "nothing is held", silently
// and in the fail-open direction, with the compiler never naming the caller that forgot (L168).
@Suite("A show a live run holds does not inherit an org answer (#3014)")
struct HeldShowsDoNotInheritTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    // Mirrors OrgAnswerLedgerTests' own fixture. The org key must come from `OrgKey.stored(for:)`,
    // which is what the fan-out looks a presenter up by: a hand-spelled key silently matches nothing and
    // every assertion below then passes on a fan-out that never ran. That is exactly what the positive
    // control caught on this suite's first run.
    private func answer(_ org: String, emails: [String] = ["hello@tenet.example"]) -> OrgAnswerLedger.Answer {
        OrgAnswerLedger.Answer(orgKey: OrgKey.stored(for: org)!, result: .emailFound,
                               probedAt: now.addingTimeInterval(-86_400),
                               presenterName: org, emails: emails)
    }

    // Two shows under one presenter at two venues, which is what `ProducerGate` needs before it will call
    // the presenter a producer rather than a room. Built as the ledger's own value type, so this suite
    // never touches the store.
    private func shows() -> [OrgAnswerLedger.Show] {
        [
            OrgAnswerLedger.Show(key: "answered", presenter: "Tenet Vocal Artists",
                                 venue: "Church of the Ascension", hasOwnAnswer: false),
            OrgAnswerLedger.Show(key: "sibling", presenter: "Tenet Vocal Artists",
                                 venue: "House of the Redeemer", hasOwnAnswer: false),
        ]
    }

    // THE POSITIVE CONTROL, and it comes first on purpose: the whole suite is worthless if the fan-out
    // does not fire in this fixture at all, which is exactly the state the live store is in (L159, L147).
    @Test func theFanOutDoesReachASiblingShowWhenNothingIsHeld() {
        let map = OrgAnswerLedger.inherited(from: [answer("Tenet Vocal Artists")], shows: shows(),
                                            now: now, heldKeys: [])
        #expect(map["sibling"] != nil,
                "the fan-out did not reach the sibling at all, so every assertion below would pass on a mechanism that never runs")
    }

    @Test func aHeldSiblingDoesNotInherit() {
        let map = OrgAnswerLedger.inherited(from: [answer("Tenet Vocal Artists")], shows: shows(),
                                            now: now, heldKeys: ["sibling"])
        #expect(map["sibling"] == nil,
                "a show a live run is drafting had its displayed contact changed by a check on a different show")
    }

    @Test func holdingOneShowDoesNotBlockTheOthers() {
        let three = shows() + [OrgAnswerLedger.Show(key: "other", presenter: "Tenet Vocal Artists",
                                                    venue: "Church of the Ascension", hasOwnAnswer: false)]
        let map = OrgAnswerLedger.inherited(from: [answer("Tenet Vocal Artists")], shows: three,
                                            now: now, heldKeys: ["sibling"])
        #expect(map["sibling"] == nil)
        #expect(map["other"] != nil,
                "holding one show suppressed the fan-out for a show nobody holds: the block is per show, not per organisation")
    }

    // Holding a key nothing in the fan-out names changes nothing. Stated because the held set is the
    // OTHER run's whole coverage, most of which has no bearing on any organisation here.
    @Test func holdingAnUnrelatedShowChangesNothing() {
        let map = OrgAnswerLedger.inherited(from: [answer("Tenet Vocal Artists")], shows: shows(),
                                            now: now, heldKeys: ["something else entirely"])
        #expect(map["sibling"] != nil)
    }

    // The block is evaluated on every queue build rather than latched, so a run ending releases it with no
    // separate step. Asserted rather than assumed, which is what #2620's 2026-08-18 note asked for.
    @Test func theBlockIsReleasedTheMomentTheKeyIsNoLongerHeld() {
        let held = OrgAnswerLedger.inherited(from: [answer("Tenet Vocal Artists")], shows: shows(),
                                             now: now, heldKeys: ["sibling"])
        let released = OrgAnswerLedger.inherited(from: [answer("Tenet Vocal Artists")], shows: shows(),
                                                 now: now, heldKeys: [])
        #expect(held["sibling"] == nil)
        #expect(released["sibling"] != nil,
                "the same inputs with nothing held must inherit again, or the block outlives the run that caused it")
    }
}

// The rule that decides what the fan-out is told to avoid, separately from the ledger that obeys it.
@MainActor
@Suite("What a live run holds, for the org fan-out (#3014)")
struct LiveRunHoldingsTests {

    private func dir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeLive(_ slot: RunSlot, in support: URL) throws {
        try Data().write(to: slot.markerURL(in: support))
    }

    @Test func nothingIsBlockedWhenNoCheckIsRunning() throws {
        let d = dir()
        try RunCoverage.write(keys: ["drafting"], slot: .prep, in: d)
        try makeLive(.prep, in: d)
        // A prep alone cannot have the ground moved under it: no check means no new organisation answer.
        // Blocking here would hide badges Dan should see, on every ordinary Prep run.
        #expect(LiveRunHoldings.holdings(support: d, now: Date()).isEmpty)
    }

    // THE POSITIVE CONTROL, same fixture plus the one thing that makes the conflict possible.
    @Test func aPrepsShowsAreBlockedWhileACheckRuns() throws {
        let d = dir()
        try RunCoverage.write(keys: ["drafting"], slot: .prep, in: d)
        try makeLive(.prep, in: d)
        try makeLive(.check, in: d)
        #expect(LiveRunHoldings.holdings(support: d, now: Date()) == ["drafting"])
    }

    @Test func aCheckAloneBlocksNothing() throws {
        let d = dir()
        try makeLive(.check, in: d)
        #expect(LiveRunHoldings.holdings(support: d, now: Date()).isEmpty,
                "with no prep running there is no draft to protect")
    }

    // Unlike a launch, this yields EMPTY rather than refusing when the prep's coverage cannot be read:
    // refusing would blank every inherited badge on the queue, which is worse for Dan than one that is
    // momentarily stale, and there is no run to stop. Stated as a test so the asymmetry is deliberate
    // rather than discovered (L11).
    @Test func anUnreadableCoverageBlocksNothingHereRatherThanBlankingTheQueue() throws {
        let d = dir()
        try Data("not json".utf8).write(to: RunSlot.prep.coversURL(in: d))
        try makeLive(.prep, in: d)
        try makeLive(.check, in: d)
        #expect(LiveRunHoldings.holdings(support: d, now: Date()).isEmpty)
    }
}
