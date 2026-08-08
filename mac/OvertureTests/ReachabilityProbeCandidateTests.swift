import Testing
import Foundation

// #1308 Layer 2 Phase 3: which shows on a date are worth an opt-in reachability check. Only still-open
// pre-commitment candidates count: a booked, sent, or drafted show is past the keep/dismiss moment, and an
// already-probed show already has its answer. The date-header "Check reachability" control appears only
// when two or more such candidates share a date (the whole value is comparing several).
@MainActor
@Suite("Reachability probe candidates (#1308)")
struct ReachabilityProbeCandidateTests {
    private func item(_ key: String, status: ReviewStatus = .new, booked: Bool = false,
                      sent: Bool = false, probed: Bool = false) -> QueueItem {
        var i = QueueItem(id: key, groupName: key, discipline: "music", venue: "Weill Recital Hall",
                          performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status)
        if booked { i.performanceStatus = .booked }
        if sent { i.sentAt = Date(timeIntervalSince1970: 1_780_000_000) }
        if probed { i.reachabilityProbedAt = Date(timeIntervalSince1970: 1_780_000_000) }
        return i
    }

    // #1595 / #1587: candidacy now comes from the shared OpenForDecision predicate, so this list and the
    // Scout list Dan triages cannot answer "is he still deciding" differently. Two changes from #1308:
    // a KEPT show is no longer a candidate (it is past the keep-or-dismiss moment, and Prep is about to
    // find its contact anyway), and a run that has already OPENED is no longer a candidate (the Scout list
    // drops it, so paying to research it would be money on a show Overture refuses to display).
    @Test func onlyStillOpenUnprobedShowsAreCandidates() {
        let items = [
            item("a"),                              // new, open -> candidate
            item("b", status: .queued),             // KEPT: past the decision -> no longer a candidate
            item("c", status: .drafted),            // already being pursued -> no
            item("d", sent: true),                  // already pitched -> no
            item("e", booked: true),                // booked -> no
            item("f", probed: true),                // freshly probed: has its answer -> no
        ]
        // `now` just after f's probe, so f is still fresh (not stale) and stays excluded.
        let now = Date(timeIntervalSince1970: 1_780_000_100)
        #expect(QueueModel.reachabilityProbeCandidateKeys(items, now: now, today: "2026-09-01") == ["a"])
    }

    @Test func aRunThatHasAlreadyOpenedIsNotACandidate() {
        // The show opens on 2026-09-12; today is after it, so the run is underway and Dan will not pitch
        // it. The Scout list already drops it (#1540); this rule used to keep offering to pay for it.
        #expect(QueueModel.reachabilityProbeCandidateKeys([item("a")],
                                                          now: Date(timeIntervalSince1970: 1_780_000_100),
                                                          today: "2026-09-20") == [])
    }

    // #1332: a probe result that has aged past the freshness window shows Dan a "worth re-checking" badge
    // (#1325) telling him to run Check reachability again, so that stale show must become a candidate
    // AGAIN, or the advice points at a control that never includes it. A freshly probed show stays out.
    @Test func aStaleProbedShowBecomesACandidateAgainSoItCanBeRechecked() {
        let probedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var stale = item("s"); stale.reachabilityProbedAt = probedAt
        var fresh = item("t"); fresh.reachabilityProbedAt = probedAt

        let afterWindow = probedAt.addingTimeInterval(Reachability.probeFreshness + 1)
        #expect(QueueModel.reachabilityProbeCandidateKeys([stale], now: afterWindow) == ["s"])

        let withinWindow = probedAt.addingTimeInterval(1)
        #expect(QueueModel.reachabilityProbeCandidateKeys([fresh], now: withinWindow) == [])
    }

    // #1595, then Dan's walk (2026-07-27): both the visibility rule and the headline selector are gone.
    // The control renders wherever there is a candidate and shows nothing but its button, so all that is
    // left to assert here is candidacy itself. A stale result still surfaces on the ROW badge, tested in
    // ReachabilityTests.
    // A booked sibling on the date is not a candidate, so it neither adds to the count nor keeps the
    // control alive on a date whose only open show has been answered.
    @Test func aBookedSiblingIsNotACandidate() {
        #expect(QueueModel.reachabilityProbeCandidateKeys(
            [item("a"), item("x", booked: true)],
            now: Date(timeIntervalSince1970: 1_780_000_100)) == ["a"])
    }

    // #1609: a show somewhere Dan has refused to travel must never be offered a PAID check.
    //
    // Every stage list was safe only by accident of ordering: StageNavigation applies the geography gate
    // upstream (#1570), so a Scout row reaching this rule had already been filtered. The #308 away-alert
    // leads list renders through the same date section with no stage focus, skips that filter entirely,
    // and its rows are untriaged, so the Check button appeared on them. Narrow, but it spends real money
    // and real minutes researching a show Overture refuses to display anywhere else.
    //
    // The gate is applied HERE now rather than relied on upstream, so it holds on every path.
    //
    // These fixtures are THEATER on purpose. Dan travels for a production but not for music, so a music
    // show anywhere outside the boroughs is already out of range on the discipline rule alone. Written
    // with music, every test below would have passed whether or not his refusals reached this rule, which
    // is exactly the vacuous-green trap: the first draft of these did, and proved nothing.
    private let now = Date(timeIntervalSince1970: 1_780_000_100)

    private func placed(_ key: String, _ location: String?) -> QueueItem {
        var i = QueueItem(id: key, groupName: key, discipline: "theater", venue: "A Theatre",
                          performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .new)
        i.location = location
        return i
    }

    // Both halves, so the test fails if the refusal set stops reaching this rule.
    @Test func aShowInARefusedTownIsNeverOfferedAPaidCheck() {
        let show = [placed("refused", "Larchmont, NY")]
        #expect(QueueModel.reachabilityProbeCandidateKeys(show, now: now) == ["refused"],
                "with no refusal, a theater show up the line is worth checking")
        #expect(QueueModel.reachabilityProbeCandidateKeys(
            show, now: now, geo: GeoRefusals(userExcludedTowns: ["larchmont"])) == [],
                "once he has refused the town, paying to research it is money on a show he will not take")
    }

    // A place Overture judges out of range on its own, with no refusal from Dan at all.
    @Test func aShowOverturePlacesOutOfRangeIsNotACandidate() {
        #expect(QueueModel.reachabilityProbeCandidateKeys(
            [placed("here", "New York, NY"), placed("abroad", "Beijing, China")], now: now) == ["here"])
    }

    // The asymmetry that keeps this from losing him a show (#970): a positive placement out of range
    // excludes, but anything Overture CANNOT read is always kept. Most rows carry no location at all, so
    // a gate that treated silence as refusal would quietly stop offering checks on almost the whole queue.
    @Test func aShowWithNoReadablePlaceStaysACandidate() {
        #expect(QueueModel.reachabilityProbeCandidateKeys(
            [placed("unknown", nil), placed("blank", ""), placed("vague", "the usual spot")],
            now: now, geo: GeoRefusals(userExcludedTowns: ["larchmont"])) == ["unknown", "blank", "vague"])
    }

    // A SEED town (one of the built-in far places, not a refusal of Dan's) is excluded by default and
    // becomes a candidate again once he un-skips it (#1221). Without threading the allow through, his
    // un-skip would be honoured by the queue and ignored by the paid check, so a town he had explicitly
    // taken back would never be offered one.
    @Test func aSeedTownIsExcludedUntilHeAllowsItBack() {
        let show = [placed("buffalo", "Buffalo, NY")]
        #expect(QueueModel.reachabilityProbeCandidateKeys(show, now: now) == [],
                "a built-in far town is not worth paying to research")
        #expect(QueueModel.reachabilityProbeCandidateKeys(
            show, now: now, geo: GeoRefusals(allowedSeedTowns: ["buffalo"])) == ["buffalo"],
                "once he takes a seed town back, its shows are worth checking again")
    }

    // The multi-date confirm must not COUNT or charge for a refused show either. This is the sheet that
    // tells Dan how many shows a run covers, so a refused row leaking in here would make him approve a
    // number he cannot get.
    @Test func theMultiDateConfirmExcludesARefusedShow() {
        let rows = [placed("keep", "New York, NY"), placed("refused", "Larchmont, NY")]
        let refusals = GeoRefusals(userExcludedTowns: ["larchmont"])
        let picked = QueueModel.probeSelection(dates: ["2026-09-12"], in: rows, among: rows,
                                               today: "2026-09-01", stage: .scout, now: now,
                                               geo: refusals)
        #expect(picked?.1 == ["keep"], "only the show he would actually travel to is paid for")
    }

    // A working gate and a WIRED gate are two claims, and the default here is deliberately "no refusals"
    // so every existing caller and preview is unchanged. That default means a call site which forgets to
    // pass Dan's real refusals silently gets no gate at all, which is exactly the bug this issue is. Three
    // places ask the question in the live view, and a SwiftUI body cannot be asserted on, so the wiring is
    // pinned at the source.
    @Test func everyLiveCallSitePassesDansRealRefusals() throws {
        let source = try String(contentsOf: RepoRoot.mac
            .appendingPathComponent("Overture/UI/QueueView.swift"), encoding: .utf8)
        #expect(!source.contains("reachabilityProbeCandidateKeys(group.items)"),
                "the per-date tick box must ask with the refusals applied")
        #expect(source.contains("reachabilityProbeCandidateKeys(group.items, geo: geo)"))
        #expect(source.contains("geo: geo,"), "the date control must be handed the refusals too")
    }
}
