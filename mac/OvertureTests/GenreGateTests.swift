import Testing
import Foundation
import SwiftData

// #2687: nothing leaves the queue without a genre.
//
// Dan, 2026-08-13: "file a p1 issue that won't let me keep/dismiss an event if it says no genre read. I
// should have to correct the genre before acting on them." Scope confirmed in the same conversation:
// Keep and every Dismiss, including the whole-night bulk dismiss.
//
// Nothing in the triage path consulted the genre before this. Three controls that share no code had to
// start asking one question, which is why the predicate is in the domain and these tests are about it
// rather than about three copies of it (L30).
@MainActor
@Suite("Genre gate")
struct GenreGateTests {

    // MARK: the predicate

    // Every genre the classifier can read passes. `Ranker` renders `.other` as "No genre read", and that
    // is the one state Dan asked to be stopped on.
    @Test func onlyAnUnreadGenreBlocks() {
        for read in Discipline.allCases where read != .other {
            #expect(!GenreGate.blocks(discipline: read.rawValue), "\(read) should not block")
        }
        #expect(GenreGate.blocks(discipline: Discipline.other.rawValue))
    }

    // Fails CLOSED, into the gate. An empty or unrecognised raw value is the same state as `.other`
    // (nothing readable was stored), and the cost of a wrong block is one click on a control already on
    // the row, against a show leaving the queue with the thing Dan asked to be forced to set still unset.
    @Test func anUnreadableValueBlocksLikeNoGenreAtAll() {
        #expect(GenreGate.blocks(discipline: ""))
        #expect(GenreGate.blocks(discipline: "klezmer-adjacent"))
    }

    // The refusal comes from the same function that decides, so a disabled control can never sit beside
    // no reason. #2544 is the defect this shape prevents (L109).
    @Test func theRefusalAndTheBlockAreOneDecision() {
        #expect(GenreGate.refusal(discipline: Discipline.other.rawValue) == GenreGateCopy.blocked)
        #expect(GenreGate.refusal(discipline: Discipline.opera.rawValue) == nil)
    }

    // MARK: the whole night

    // One confirm covering many shows, so it says HOW MANY are blocked. A single-show sentence here would
    // tell Dan nothing about which of the night's rows he has to go and fix.
    @Test func theNightRefusalNamesHowManyAreBlocked() {
        let night = [Discipline.opera.rawValue, Discipline.other.rawValue,
                     Discipline.dance.rawValue, Discipline.other.rawValue]

        #expect(GenreGate.nightRefusal(disciplines: night, dateLabel: "Aug 19")
                == GenreGateCopy.nightBlocked(count: 2, dateLabel: "Aug 19"))
        #expect(GenreGateCopy.nightBlocked(count: 2, dateLabel: "Aug 19").contains("2 shows on Aug 19"))
        // Singular reads as English, because a night with one unread show is the common case near the end
        // of a triage pass.
        #expect(GenreGateCopy.nightBlocked(count: 1, dateLabel: "Aug 19").contains("1 show on Aug 19"))
        // And it names the DATE, never "tonight": this menu covers any night in the queue, most of them
        // weeks out. Caught by reading the generated inventory cold rather than by any test.
        #expect(!GenreGateCopy.nightBlocked(count: 2, dateLabel: "Aug 19").contains("tonight"))
    }

    // And a night with nothing blocked is not refused, which is the half that keeps the control usable. A
    // gate that fired on every night would be switched off within a day (L93).
    @Test func aNightWithEveryGenreSetIsNotRefused() {
        #expect(GenreGate.nightRefusal(disciplines: [Discipline.opera.rawValue,
                                                     Discipline.theater.rawValue],
                                       dateLabel: "Aug 19") == nil)
        // An empty night has nothing to block either: nil, never a "0 shows" sentence.
        #expect(GenreGate.nightRefusal(disciplines: [], dateLabel: "Aug 19") == nil)
    }

    // MARK: the three controls actually ask

    // `keepDismissControls` is a computed PROPERTY, not a function, which is why this does not go through
    // `SourceGuard.functionBody`. One helper rather than three copies of the lookup, so the guards below
    // cannot drift into reading three different regions of the same file.
    private func keepDismissControls() throws -> String {
        try #require(SourceGuardHelper.propertyBody(
            "private var keepDismissControls: some View {",
            in: SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")),
                     "the row's keep/dismiss controls were not found where these guards expect them")
    }

    // A predicate nothing consults is not a gate (L3: built is not wired). Each assertion is scoped to the
    // ONE function the control lives in, because these files are large enough that a whole-file search
    // would be answered by a coincidental match somewhere else in them (L135).
    @Test func theKeepButtonAsksTheGate() throws {
        let body = try keepDismissControls()

        // The DISABLING specifically, not merely a mention of the gate. Written as
        // `contains("GenreGate.blocks(...)")` this guard stayed green with `.disabled` deleted, because
        // the same call appears one line below in the `.opacity` that dims the button: a guard answered
        // by a second, legitimate use of the same construct nearby (L135). Caught by mutating it.
        #expect(body.contains(".disabled(GenreGate.blocks(discipline: item.discipline))"),
                "Keep is no longer DISABLED by the genre gate")
        #expect(body.contains(".help(GenreGate.refusal(discipline: item.discipline)"),
                "the blocked Keep no longer carries its reason")
    }

    @Test func theDismissMenuAsksTheGate() throws {
        let body = try keepDismissControls()
        let menu = try #require(SourceGuardHelper.between("Menu {", and: "ShowOutcome.menu(", in: body),
                                "the row's Dismiss menu was not found where this guard expects it")

        #expect(menu.contains("GenreGate.refusal(discipline: item.discipline)"),
                "the Dismiss menu no longer consults the genre gate")
    }

    @Test func theWholeNightDismissAsksTheGate() throws {
        let body = try String(SourceGuard.functionBody(
            named: "nightDismissMenu", in: SourceGuardHelper.source("Overture/UI/QueueView.swift")))

        #expect(body.contains("GenreGate.nightRefusal"),
                "the whole-night dismiss no longer consults the genre gate")
        // Asked of the shows the action would actually TAKE, not of everything drawn under the heading,
        // so the count names the same rows the reasons would have dismissed (L16).
        #expect(body.contains("plan.keys.contains"),
                "the night's blocked count is no longer scoped to the shows the plan covers")
    }

    // MARK: what stays exempt

    // "Went by" is Overture's own retirement of a show whose date passed untriaged, not an action of
    // Dan's. Blocking the app's own sweep on a genre he never set would strand those rows forever, so the
    // gate must not reach it. Proven by running the sweep on a genre-less show, rather than by reading
    // that the sweep does not mention the gate.
    @Test func theWentBySweepIsNotBlocked() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "Aurora|2026-01-05", groupName: "Aurora Strings",
                         discipline: Discipline.other.rawValue, venue: "Jalopy",
                         performanceDate: "2026-01-05", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)

        #expect(GenreGate.blocks(discipline: p.discipline))
        #expect(WentByRetirement.run(in: ctx, today: "2026-08-14") == 1)
        #expect(p.showOutcome == .wentBy)
    }

    // Restore puts a dismissed row back as UNDECIDED, which is not acting on a show: it is undoing having
    // acted. The gate then applies to the next Keep or Dismiss, which is the right moment. Left open
    // deliberately, and asserted so it is not "tidied" into the gate later.
    @Test func restoreIsNotActingOnAShow() throws {
        let body = try keepDismissControls()
        let restore = try #require(SourceGuardHelper.between("onRestore()", and: "buttonStyle", in: body),
                                   "the Restore control was not found where this guard expects it")

        #expect(!restore.contains("GenreGate"))
    }

    // A direct hire inquiry carries no `discipline` field at all and renders its own row with its own
    // controls, so it is exempt STRUCTURALLY rather than by an exemption anybody wrote. That is exactly
    // why the gate is written at the two prospect CONTROLS and not at the queue: phrased as "nothing in
    // the queue can be acted on without a genre" it would make every inquiry permanently unactionable,
    // with no control anywhere that could clear it (L45). Nothing else would notice the day that changes.
    @Test func anInquiryStaysActionable() throws {
        let inquiryRow = SourceGuardHelper.source("Overture/UI/InquiryRowView.swift")
        #expect(!inquiryRow.isEmpty, "the inquiry row could not be read, so this guard measured nothing")
        #expect(!inquiryRow.contains("GenreGate"))
    }
}
