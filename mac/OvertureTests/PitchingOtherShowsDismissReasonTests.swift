import Testing
import Foundation
import SwiftData

// #1821: Dan reaches out about one show a night, occasionally two, so on a busy night the other good
// shows are cut for a reason no existing option stated. "Date conflict" was the closest, and it is a lie
// about the night: the night worked fine, he spent it.
//
// The point of a separate case is that it is separable LATER. Folded into "Date conflict", "I was booked
// or away" and "I picked a different show" are permanently indistinguishable, and no future change can
// recover the difference because it was never written down (#16 is the intended home for that reporting).
//
// It must behave exactly like `dateConflict` where that is right (neutral in history, score unchanged)
// and NOT where it is wrong (it captures no day off: he is working that night).
@MainActor
@Suite("Pitching other shows dismiss reason (#1821)")
struct PitchingOtherShowsDismissReasonTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func dismissed(_ ctx: ModelContext, group: String, reason: DismissReason) {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "music", venue: "The Green Room 42",
                         performanceDate: "2026-08-03", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .dismissed, dismissReason: reason)
        ctx.insert(p)
    }

    // (a) Dan picks it himself. It is his own decision, not an Overture-only cut like `wentBy` or
    // `tooFar`, so it rides in the list both dismiss menus render from.
    @Test func isOfferedToDan() {
        #expect(DismissReason.danCanChoose.contains(.pitchingOtherShows))
        // The #864 rule the new case must not break.
        #expect(!DismissReason.danCanChoose.contains(.wentBy))
        #expect(!DismissReason.danCanChoose.contains(.tooFar))
    }

    // (b) A value of its own, distinct from every other reason and above all from the one it replaces.
    // The whole reporting argument rests on this raw value being separable from `date_conflict` forever.
    @Test func isItsOwnStoredValue() {
        #expect(DismissReason.pitchingOtherShows != .dateConflict)
        #expect(DismissReason.pitchingOtherShows.rawValue == "pitching_other_shows")
        let raws = DismissReason.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
    }

    // (c) Its own wording, so the menu never shows two reasons reading the same.
    @Test func hasItsOwnLabel() {
        #expect(DismissReason.pitchingOtherShows.label == "Pitching other shows that night")
        let labels = DismissReason.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
    }

    // (d) Neutral, exactly as `dateConflict` is: the org is recorded `declined`, which Ranker weights 0
    // (#1362). Nothing to re-teach and no backfill, which is the whole reason this is safe to add.
    @Test func recordsTheOrgAsDeclinedJustLikeADateConflict() throws {
        let ctx = ModelContext(try container())
        dismissed(ctx, group: "Feminine Rage", reason: .pitchingOtherShows)
        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.count == 1)
        #expect(records.first?.status == "declined")
    }

    // (e) The reader the issue did not list, and the one place this must NOT copy `dateConflict`.
    // Dismissing for a date conflict offers to block the date as a day off (#924). Here the date is not
    // blocked at all: Dan is out shooting or pitching that night. Offering to mark it off would write the
    // opposite of what happened and stop Overture pitching him for a night he actively works.
    @Test func neverOffersToBlockTheNightAsADayOff() {
        #expect(DayOffOffer.offer(reason: .pitchingOtherShows,
                                  performanceDate: "2026-08-03", runEndDate: nil) == nil)
        // The reasons that DO capture a day off are unchanged by this addition.
        #expect(DayOffOffer.offer(reason: .dateConflict, performanceDate: "2026-08-03", runEndDate: nil) != nil)
        #expect(DayOffOffer.offer(reason: .alreadyBooked, performanceDate: "2026-08-03", runEndDate: nil) != nil)
    }

    // (f) Old rows are not rewritten. Nobody can say retrospectively which `date_conflict` rows were
    // really this, so the new reason applies going forward only. The launch migration touches exactly one
    // legacy value (#940's `day_doesnt_work`) and must not grow a second rule off the back of this.
    @Test func existingDateConflictRowsAreLeftAlone() throws {
        let ctx = ModelContext(try container())
        dismissed(ctx, group: "Booked Elsewhere Ensemble", reason: .dateConflict)
        DismissReasonMigration.run(in: ctx)
        let after = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(after.first?.dismissReasonRaw == "date_conflict")
    }

    // (g) The two assembled sentences Dan reads, rendered whole. A label only reads well in a menu until
    // something drops it into the middle of a sentence, and both of these do (AGENTS.md's cold read).
    @Test func readsCorrectlyInsideTheSentencesThatQuoteIt() {
        #expect(BulkDismiss.confirmMessage(count: 5, reason: .pitchingOtherShows, runs: [],
                                           dateLabel: "Aug 3")
                == "They all leave your queue, filed as Pitching other shows that night.")
        #expect(BulkDismiss.confirmMessage(count: 1, reason: .pitchingOtherShows, runs: [],
                                           dateLabel: "Aug 3")
                == "It leaves your queue, filed as Pitching other shows that night.")
        #expect(ActionAck.nightDismissed(count: 5, reason: .pitchingOtherShows, dateLabel: "Aug 3")
                == "5 shows on Aug 3 are dismissed as Pitching other shows that night")
    }
}
