import Testing
import Foundation
import SwiftData

// #2261: asking for a reachability check to be run AGAIN on a show that already has an answer.
//
// Until now the only thing that released a show was the 90-day clock. Measured on Dan's live store
// 2026-08-07: 28 shows have ever been checked and all 28 sit inside the freshness window, 11 of them on
// "No email found" and 4 on "contact form only". The earliest becomes re-checkable on 2026-10-26, by
// which time most of those shows have been and gone. So every improvement to what a check FINDS (#2265,
// #2259, #2258) reaches only shows scouted afterwards, and the shows most in need of a re-run are exactly
// the ones already carrying a wrong "No email found" (L4).
//
// The request is a FLAG, never a clearing of the verdict. A re-check that wiped the answer first and then
// failed would leave the card worse than before Dan pressed it (L5), so the old answer stands until a new
// one lands.
@MainActor
@Suite("Re-checking a show that already has an answer (#2261)")
struct ReachabilityRecheckTests {

    private let probedAt = Date(timeIntervalSince1970: 1_780_000_000)
    private var justAfter: Date { probedAt.addingTimeInterval(100) }

    private func item(_ key: String, status: ReviewStatus = .new, booked: Bool = false,
                      sent: Bool = false, probed: Bool = true,
                      inherited: OrgAnswerLedger.Inherited? = nil,
                      recheckRequestedAt: Date? = nil) -> QueueItem {
        var i = QueueItem(id: key, groupName: key, discipline: "music", venue: "Weill Recital Hall",
                          performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: status)
        if booked { i.performanceStatus = .booked }
        if sent { i.sentAt = probedAt }
        if probed { i.reachabilityProbedAt = probedAt }
        i.inheritedReachability = inherited
        i.reachabilityRecheckRequestedAt = recheckRequestedAt
        return i
    }

    private func inheritedAnswer() -> OrgAnswerLedger.Inherited {
        OrgAnswerLedger.Inherited(result: .emailFound, probedAt: probedAt,
                                  organisation: "The Green Room 42", emails: ["box@example.org"])
    }

    // The whole point: a show frozen on its own fresh answer is offered again once Dan asks for it.
    @Test func aFreshlyAnsweredShowBecomesACandidateOnceARecheckIsAsked() {
        let frozen = item("a")
        #expect(QueueModel.reachabilityProbeCandidateKeys([frozen], now: justAfter,
                                                          today: "2026-09-01") == [])

        let asked = item("a", recheckRequestedAt: justAfter)
        #expect(QueueModel.reachabilityProbeCandidateKeys([asked], now: justAfter,
                                                          today: "2026-09-01") == ["a"])
    }

    // The exclusion most likely to be missed. A show can be frozen not by its OWN check but by one paid
    // for on a sibling show of the same organisation. A re-check that only overrode the own-answer gate
    // would silently refuse on exactly those rows, and the button would read as broken.
    @Test func aShowFrozenByItsOrganisationsAnswerIsAlsoReleased() {
        let inheriting = item("a", probed: false, inherited: inheritedAnswer())
        #expect(QueueModel.reachabilityProbeCandidateKeys([inheriting], now: justAfter,
                                                          today: "2026-09-01") == [])

        let asked = item("a", probed: false, inherited: inheritedAnswer(), recheckRequestedAt: justAfter)
        #expect(QueueModel.reachabilityProbeCandidateKeys([asked], now: justAfter,
                                                          today: "2026-09-01") == ["a"])
    }

    // A request releases the FRESHNESS gate and nothing else. Whether a paid check is worth offering at
    // all is a separate question (is Dan still deciding, does he travel there), and a re-check that
    // bypassed it would offer to spend money researching a show already booked, already pitched, or in a
    // town he has refused.
    @Test func aRequestDoesNotOfferAShowThatIsPastDeciding() {
        let booked = item("a", booked: true, recheckRequestedAt: justAfter)
        let pitched = item("b", sent: true, recheckRequestedAt: justAfter)
        let kept = item("c", status: .queued, recheckRequestedAt: justAfter)

        #expect(QueueModel.reachabilityProbeCandidateKeys([booked, pitched, kept], now: justAfter,
                                                          today: "2026-09-01") == [])
    }

    // #1617: the date heading claims "Reachability checked" only when its shows really are all answered.
    // A date holding a show Dan has asked to re-check is not finished, and a heading still claiming so
    // would be a promise contradicted by the row underneath it.
    @Test func aDateHoldingARequestedRecheckIsNotFullyChecked() {
        let items = [item("a"), item("b", recheckRequestedAt: justAfter)]
        #expect(QueueModel.dateReachabilityIsFullyChecked(items, now: justAfter,
                                                          today: "2026-09-01") == false)
    }
}

// What the ROW offers about re-checking, decided beside the data rather than in the view body, because
// it is three distinct states and a view cannot be tested for getting them wrong (#885).
@Suite("What a row offers about re-checking (#2261)")
struct ReachabilityRecheckOfferTests {

    private let probedAt = Date(timeIntervalSince1970: 1_780_000_000)
    private var justAfter: Date { probedAt.addingTimeInterval(100) }
    private var longAfter: Date { probedAt.addingTimeInterval(Reachability.probeFreshness + 1) }

    // Nothing to re-check. A show no check has ever run over is served by the ordinary check control, and
    // offering "check again" beside it would claim an answer exists.
    @Test func aShowWithNoAnswerIsNotOfferedARecheck() {
        #expect(Reachability.recheckState(probedAt: nil, hasInheritedAnswer: false,
                                          recheckRequestedAt: nil, now: justAfter) == .notOffered)
    }

    @Test func aShowCarryingItsOwnFreshAnswerIsOfferedARecheck() {
        #expect(Reachability.recheckState(probedAt: probedAt, hasInheritedAnswer: false,
                                          recheckRequestedAt: nil, now: justAfter) == .offer)
    }

    // The row Dan is most likely to be standing on: its answer was paid for on a sibling show. It is
    // frozen just as hard, so it must be offered just as readily.
    @Test func aShowCarryingItsOrganisationsAnswerIsOfferedARecheck() {
        #expect(Reachability.recheckState(probedAt: nil, hasInheritedAnswer: true,
                                          recheckRequestedAt: nil, now: justAfter) == .offer)
    }

    // Already released by the 90-day clock, so the ordinary control already includes it. A second control
    // saying the same thing is the restatement #843 exists to stop.
    @Test func aShowWhoseAnswerHasAgedOutIsNotOfferedASecondRoute() {
        #expect(Reachability.recheckState(probedAt: probedAt, hasInheritedAnswer: false,
                                          recheckRequestedAt: nil, now: longAfter) == .notOffered)
    }

    // L44: the press gets its own acknowledged state the instant it is accepted. A control that kept
    // offering itself after being pressed reads as broken, so Dan presses it again, and the work is
    // already queued and already going to cost him.
    @Test func aRequestedRecheckStopsOfferingAndSaysSo() {
        #expect(Reachability.recheckState(probedAt: probedAt, hasInheritedAnswer: false,
                                          recheckRequestedAt: justAfter, now: justAfter) == .requested)
    }

    // The acknowledgement holds even once the underlying answer ages out, so a request made just before
    // the clock released it does not flicker back into an unpressed-looking control.
    @Test func anAgedOutShowStillAcknowledgesAnOutstandingRequest() {
        #expect(Reachability.recheckState(probedAt: probedAt, hasInheritedAnswer: false,
                                          recheckRequestedAt: justAfter, now: longAfter) == .requested)
    }
}

// The request has to be SPENT by the check that serves it, or the show is offered forever and Dan pays
// for the same question every time he looks at it. Which check spends it is the whole subtlety: a run
// that never reached the show has not answered the question he asked (L47).
@MainActor
@Suite("A re-check request is spent by the check that answers it (#2261)")
struct ReachabilityRecheckSettleTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, OrgReachabilityAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func newProspect(_ ctx: ModelContext, group: String, requestedAt: Date?) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: "2026-09-12",
                                          venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        p.reachabilityRecheckRequestedAt = requestedAt
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    private func fetch(_ ctx: ModelContext, _ key: String) throws -> Prospect? {
        try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
    }

    private func dir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func writeResults(_ url: URL, _ results: PrepResults) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(results).write(to: url)
    }

    private func answer(_ key: String) -> PrepResult {
        PrepResult(naturalKey: key,
                   contacts: [PrepContact(name: "Jane", role: "Mgr", email: "jane@aurora.org",
                                          method: "named_decision_maker", confidence: "high",
                                          formUrl: nil, provenance: "act")],
                   draft: nil)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "recheck-\(UUID().uuidString)")!
    }

    @Test func aCheckThatAnswersTheShowSpendsTheRequest() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let a = newProspect(ctx, group: "Aurora Strings", requestedAt: now.addingTimeInterval(-60))
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a], startedAt: "s"), to: markerURL)
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [answer(a)]))

        _ = PrepQueueService.settleReachabilityProbe(markerURL: markerURL, resultsURL: resultsURL,
                                                     into: ctx, now: now, defaults: freshDefaults())

        #expect(try fetch(ctx, a)?.reachabilityRecheckRequestedAt == nil,
                "the question Dan asked has been answered, so the request is spent")
    }

    // A run that died before reaching this show has NOT answered what Dan asked. Spending the request
    // there would silently drop the re-check: the show would go straight back to reading its old frozen
    // answer, with nothing anywhere recording that the re-run he asked for never happened (L47).
    @Test func aCheckThatNeverReachedTheShowLeavesTheRequestStanding() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let requestedAt = now.addingTimeInterval(-60)
        let a = newProspect(ctx, group: "Aurora Strings", requestedAt: requestedAt)
        let b = newProspect(ctx, group: "Boreal Brass", requestedAt: requestedAt)
        let d = dir()
        let markerURL = d.appendingPathComponent("probe-run.json")
        let resultsURL = d.appendingPathComponent("results.json")
        try ReachabilityProbeMarker.write(ReachabilityProbeMarker(keys: [a, b], startedAt: "s"),
                                          to: markerURL)
        try writeResults(resultsURL, PrepResults(version: 2, generatedAt: "now", results: [answer(a)]))

        _ = PrepQueueService.settleReachabilityProbe(markerURL: markerURL, resultsURL: resultsURL,
                                                     into: ctx, now: now, defaults: freshDefaults())

        #expect(try fetch(ctx, b)?.reachabilityRecheckRequestedAt == requestedAt,
                "the run never reached this show, so the re-check Dan asked for is still outstanding")
    }
}
