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

    // #3305 REVERSES the whole-night half of #2687. Dan, 2026-08-30: "I should be able to bulk dismiss all
    // shows with a genre if some have genres and some dont." Measured the same day on a queue of 579: two
    // ungenred shows under a heading of four blocked the two that were perfectly well genred, and at the
    // rate #2687 itself measured (357 of 584 undecided rows carrying no genre) almost every night holds at
    // least one, so the bulk control opened and then only ever explained why it would not run.
    //
    // The ROW level gate on Keep and on a single show's Dismiss is NOT reversed and is asserted unchanged
    // above. `theNightRefusalNamesHowManyAreBlocked` was deleted rather than adjusted, because it asserted
    // that SOME blocked refuses the night, which is precisely the decision reversed here (L252).
    @Test func aNightWithSomeGenresUnreadTakesTheRestAndCountsWhatStays() {
        let night = [(key: "a", discipline: Discipline.opera.rawValue),
                     (key: "b", discipline: Discipline.other.rawValue),
                     (key: "c", discipline: Discipline.dance.rawValue),
                     (key: "d", discipline: Discipline.other.rawValue)]

        let split = GenreGate.nightSplit(night)

        #expect(split.dismissableKeys == ["a", "c"])
        #expect(split.heldBack == 2)
        #expect(split.everythingHeldBack == false)
    }

    // The half that still refuses. A night where nothing can be read has no reduced action to offer, so it
    // must not fall through to a menu of reasons over an empty key set: that would be a control that looks
    // like it worked and dismissed nothing (L100).
    @Test func aNightWithNoGenreReadAtAllIsStillHeldEntirely() {
        let night = [(key: "a", discipline: Discipline.other.rawValue),
                     (key: "b", discipline: "")]

        let split = GenreGate.nightSplit(night)

        #expect(split.dismissableKeys.isEmpty)
        #expect(split.heldBack == 2)
        #expect(split.everythingHeldBack)
    }

    // The rule that SURVIVES the reversal, re-expressed against the new shape rather than deleted: a night
    // with every genre set is acted on whole, and an empty night holds nothing back rather than reporting a
    // zero (L430, which is the other half of L252: confirm the decision was reversed before deleting).
    @Test func aNightWithEveryGenreSetHoldsNothingBack() {
        let every = GenreGate.nightSplit([(key: "a", discipline: Discipline.opera.rawValue),
                                          (key: "b", discipline: Discipline.theater.rawValue)])
        #expect(every.dismissableKeys == ["a", "b"])
        #expect(every.heldBack == 0)
        #expect(every.everythingHeldBack == false)

        let none = GenreGate.nightSplit([])
        #expect(none.dismissableKeys.isEmpty)
        #expect(none.heldBack == 0)
        // An empty night is not "everything held back": there is nothing to hold and nothing to say.
        #expect(none.everythingHeldBack == false)
    }

    // Dan's call, 2026-09-16: COUNT the held back rather than naming them. On a night of four naming them
    // is fine; on a night of twenty it is a wall of titles inside a context menu, and the detail already
    // sits on each remaining card's own row level gate, which is where the correcting control is.
    @Test func theHeldBackSentenceCountsThemAndSaysTheyStay() {
        #expect(GenreGateCopy.nightHeldBack(count: 2).contains("2 shows"))
        #expect(GenreGateCopy.nightHeldBack(count: 2).contains("stay"))
        // Singular reads as English, and is the common case near the end of a triage pass.
        #expect(GenreGateCopy.nightHeldBack(count: 1).contains("1 show has"))
        // It does NOT repeat the date. The menu title above it already carries it, and one fact stated
        // twice on one surface is the defect L605 names.
        #expect(!GenreGateCopy.nightHeldBack(count: 2).contains("Aug"))
    }

    // The refusal for a night nothing can be read on keeps naming the DATE, because there it IS the only
    // sentence on screen. Unchanged by #3305; asserted here so the reversal cannot take it with it.
    @Test func theAllHeldNightRefusalStillNamesTheDate() {
        #expect(GenreGateCopy.nightBlocked(count: 2, dateLabel: "Aug 19").contains("2 shows on Aug 19"))
        #expect(GenreGateCopy.nightBlocked(count: 1, dateLabel: "Aug 19").contains("1 show on Aug 19"))
        #expect(!GenreGateCopy.nightBlocked(count: 2, dateLabel: "Aug 19").contains("tonight"))
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

        #expect(body.contains("GenreGate.nightSplit"),
                "the whole-night dismiss no longer consults the genre gate")
        // #3305 inverted which of these two is scoped to the other. It used to ask the gate about the
        // shows the PLAN covered; now the gate decides first and the plan is built from what survives, so
        // the count Dan reads and the rows the action takes come from one decision (L16). Asserted on the
        // filter rather than on the symbol alone, because a body that called `nightSplit` and then planned
        // over every row under the heading would satisfy the line above while dismissing ungenred shows.
        #expect(body.contains("split.dismissableKeys.contains"),
                "the night's plan is no longer built from the shows the genre gate allows")
        // And the night nothing can be read on still refuses whole rather than offering reasons over an
        // empty key set, which is the half of #2687 that #3305 did NOT reverse.
        #expect(body.contains("split.everythingHeldBack"),
                "a night with no genre read anywhere no longer refuses")
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
