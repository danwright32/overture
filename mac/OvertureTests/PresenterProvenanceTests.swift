import Testing
import Foundation
import SwiftData

// #2453: a presenter somebody DECIDED on, against a scout that erases one every time it re-reads the page.
//
// The erasure is already live, and it is not a future hazard waiting on a new adapter.
// `ExtractedEventGuard.presenterThatIsNotTheRoom` runs on both ingest doors
// (`ScoutService.swift:546` for the native feeds, `ScoutExtractResults.swift:50` for the agent extract),
// so a listing that bills the room as its own presenter arrives at the upsert with the field already
// drained to nil. `ScoutService.apply` then wrote `existing.presenter = p.presenter`
// (`ScoutService.swift:1420`) unconditionally, three lines below the `groupNameOverriddenByDan` guard
// that exists because the scout used to clobber the field beside it.
//
// So any presenter written by something OTHER than the scout (#2454's stored-row sweep, #2456's batched
// AI pass, or Dan) lived only until the next ordinary run of the same source, and it left no trace it had
// ever been answered, so the next batch would select and pay for the same show again.
//
// The fix is provenance: the row records WHO wrote its presenter, and the re-read consults that instead of
// overwriting blind. The rule is narrow on purpose, and it is the one thing the defect is about: a BLANK
// may not beat real data. A re-read that actually names a producer still wins, because that is the page
// speaking and the page is what the field is about; it just re-stamps the row so nothing claims a
// provenance it no longer has.
@MainActor
@Suite("A deliberately written presenter survives an ordinary scout re-read (#2453)")
struct PresenterProvenanceTests {

    private let clearCalendar = BlockedCalendar.build(bookings: [], exportedBlockedDates: [], daysOff: [])

    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    // A real Green Room 42 row, through the real adapter and the real boundary, in the order a scout runs
    // them. Hand-building an ExtractedEvent here would prove nothing about what an ordinary run writes:
    // the whole defect is that the room's own name is drained BEFORE the upsert sees it, so these events
    // carry a nil presenter unless the feed's supertitle names a producing company.
    private func feedEvents(superTitle: String?) -> [ExtractedEvent] {
        let event = VenueTixCalendar.VTEvent(title: "Summer Lovin'", superTitle: superTitle, subTitle: nil,
                                             date: Date(timeIntervalSince1970: 1_786_000_000),
                                             eventId: "hHr5I9OT5vhNwIimQeaY", seriesId: nil)
        return VenueTixCalendar.extractedEvents(from: [event], presenter: "The Green Room 42",
                                                venue: "The Green Room 42",
                                                location: "New York, NY")
            .map(ExtractedEventGuard.presenterThatIsNotTheRoom)
    }

    private func today(_ events: [ExtractedEvent]) -> String {
        guard let date = events.first?.performanceDate else { return "2026-01-01" }
        return String(date.dropLast(2)) + "01"
    }

    @discardableResult
    private func ingest(_ events: [ExtractedEvent], into ctx: ModelContext) -> ScoutService.Outcome {
        ScoutService.apply(events: events, clients: [], history: [], blocked: clearCalendar,
                           today: today(events), into: ctx)
    }

    private func onlyRow(_ ctx: ModelContext) throws -> Prospect {
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1, "the same show must update its row, not add a second one")
        return try #require(rows.first)
    }

    // THE DEFECT. A name a paid pass put on the row, gone on the next ordinary read of the same page.
    @Test func aPresenterWrittenByANonScoutPassSurvivesAnOrdinaryReRead() throws {
        let ctx = try context()
        let asScouted = feedEvents(superTitle: nil)   // the room bills itself, so the field arrives empty
        ingest(asScouted, into: ctx)

        let row = try onlyRow(ctx)
        #expect(OrganiserNaming.onlyTheActIsNamed(presenter: row.presenter),
                "the row this test is about is the organiser-less one")

        // What #2456's batched pass will do: name the organisation and say who said so.
        row.setPresenter("ICB Productions", from: .aiBatch)
        try? ctx.save()

        // An ordinary scout, re-reading the same unchanged listing.
        ingest(feedEvents(superTitle: nil), into: ctx)

        let after = try onlyRow(ctx)
        #expect(after.presenter == "ICB Productions",
                "a listing that names nobody is not evidence that nobody presents this show")
        #expect(after.presenterSource == PresenterSource.aiBatch.rawValue,
                "and the row still says who answered it, or the next batch pays for this show again")
    }

    // The correction this must not break: a listing that echoes its own room name as the presenter is
    // still corrected on ingest, and the row records that the blank is a name Overture DISCARDED.
    @Test func aListingEchoingItsOwnRoomNameIsStillCorrectedOnIngest() throws {
        let ctx = try context()
        ingest(feedEvents(superTitle: nil), into: ctx)

        let row = try onlyRow(ctx)
        #expect(row.presenter == nil, "the room is not the producer, whatever the feed bills")
        #expect(row.presenterWasTheRoom == true)
        #expect(row.presenterSource == nil,
                "an emptied field carries no stamp: a stamp on a blank presenter protects nothing")
    }

    // The other side of the guard, and the reason it cannot freeze the store: what the SCOUT wrote, the
    // scout still owns. A page that stops naming a producer takes its own name back.
    @Test func aScoutWrittenPresenterIsStillErasedWhenThePageStopsNamingOne() throws {
        let ctx = try context()
        ingest(feedEvents(superTitle: "ICB Productions'"), into: ctx)

        let row = try onlyRow(ctx)
        #expect(row.presenter == "ICB Productions")
        #expect(row.presenterSource == PresenterSource.scout.rawValue)

        ingest(feedEvents(superTitle: nil), into: ctx)

        #expect(try onlyRow(ctx).presenter == nil,
                "the scout's own answer is the scout's to withdraw")
    }

    // Every presenter in the store today was written by the scout, because until this change the scout was
    // the only writer of the field there had ever been (`RoomPresenterSweep` only ever cleared it). So an
    // unstamped row is treated as scout-written: that is what it measurably is, it keeps today's behaviour
    // for every existing row, and it leaves the room-name corrections still able to reach them. Treating
    // the absent stamp as "deliberate" would have frozen 400-odd unreviewed presenters, room names
    // included, against the very passes that fix them.
    @Test func anUnstampedLegacyRowIsTreatedAsScoutWritten() throws {
        let ctx = try context()
        ingest(feedEvents(superTitle: "ICB Productions'"), into: ctx)

        // A row as it sits in the store today: a presenter, and no provenance column at all.
        let row = try onlyRow(ctx)
        row.presenterSource = nil
        try? ctx.save()

        ingest(feedEvents(superTitle: nil), into: ctx)

        #expect(try onlyRow(ctx).presenter == nil,
                "no stamp means the scout wrote it, which is the only writer the field has ever had")
    }

    // The failure path. A stamp this build cannot read is NOT the absence of a stamp: something took the
    // trouble to record a provenance, and the two possible mistakes are not symmetric. Keeping a presenter
    // this build does not understand costs a stale name on one row; erasing it destroys an answer nothing
    // can reconstruct. So an unreadable stamp fails in the keeping direction.
    @Test func anUnreadableProvenanceStampIsTreatedAsDeliberate() throws {
        let ctx = try context()
        ingest(feedEvents(superTitle: nil), into: ctx)

        let row = try onlyRow(ctx)
        row.presenter = "ICB Productions"
        row.presenterSource = "a-writer-this-build-has-never-heard-of"
        try? ctx.save()

        ingest(feedEvents(superTitle: nil), into: ctx)

        #expect(try onlyRow(ctx).presenter == "ICB Productions")
    }

    // L55, and the reason this cannot be a one-line guard. `presenterWasTheRoom` explains a BLANK
    // presenter ("this row's empty field is a name we discarded"), and the queue card renders it. A kept
    // presenter must not be handed that explanation, or the card asserts the field is empty while naming
    // an organisation.
    @Test func aKeptPresenterIsNeverLabelledAsADiscardedRoomName() throws {
        let ctx = try context()
        ingest(feedEvents(superTitle: nil), into: ctx)

        let row = try onlyRow(ctx)
        #expect(row.presenterWasTheRoom == true, "the flag starts true, which is what makes this the real case")
        row.setPresenter("ICB Productions", from: .aiBatch)
        try? ctx.save()

        ingest(feedEvents(superTitle: nil), into: ctx)

        let after = try onlyRow(ctx)
        #expect(after.presenter == "ICB Productions")
        #expect(after.presenterWasTheRoom != true,
                "a row that names an organisation may not also claim its presenter is a discarded room name")
    }

    // The narrow scope, stated as a test. The guard refuses an ERASURE, not an update: a page that names a
    // producer outranks a guess about that page, and the stamp moves with the value so the row never
    // claims an answer came from somewhere it did not.
    @Test func aReReadThatNamesAProducerReplacesAGuessAndSaysWhereTheNameCameFrom() throws {
        let ctx = try context()
        ingest(feedEvents(superTitle: nil), into: ctx)

        let row = try onlyRow(ctx)
        row.setPresenter("Some Guessed Company", from: .aiBatch)
        try? ctx.save()

        ingest(feedEvents(superTitle: "ICB Productions'"), into: ctx)

        let after = try onlyRow(ctx)
        #expect(after.presenter == "ICB Productions")
        #expect(after.presenterSource == PresenterSource.scout.rawValue)
    }

    // The stored-row half of the room-name correction, which runs at every launch. A deliberate answer
    // that names the row's own room is still wrong, so the sweep still clears it, and it must take the
    // stamp with it: a provenance left standing over an empty field is a claim that an answer exists.
    @Test func theRoomSweepStillClearsADeliberatePresenterAndTakesItsStampWithIt() throws {
        let ctx = try context()
        let row = Prospect(naturalKey: "k|2026-09-01|Chain Theatre", groupName: "Fall One Acts",
                           discipline: "theater", venue: "Chain Theatre", performanceDate: "2026-09-01",
                           sourceListingURL: nil, priorRelationship: "none",
                           production: "self", profile: "strong", coverage: "likely_uncovered",
                           fitScore: 10, tier: "mid", fitReason: "r", matchedClientName: nil,
                           possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        row.setPresenter("Chain Theatre", from: .aiBatch)
        ctx.insert(row)
        try? ctx.save()

        RoomPresenterSweep.run(in: ctx)
        try? ctx.save()

        #expect(row.presenter == nil, "a room's name is wrong in that field whoever wrote it")
        #expect(row.presenterWasTheRoom == true)
        #expect(row.presenterSource == nil, "and nothing is left claiming an answer that is no longer there")
    }

    // The reader itself, at its edges, without a store in the way.
    @Test func theProvenanceReaderAnswersItsEdgeCases() {
        #expect(PresenterProvenance.survivesAnOrdinaryReRead(presenter: "ICB Productions",
                                                             storedSource: PresenterSource.sweep.rawValue))
        #expect(PresenterProvenance.survivesAnOrdinaryReRead(presenter: "ICB Productions",
                                                             storedSource: PresenterSource.dan.rawValue))
        #expect(PresenterProvenance.survivesAnOrdinaryReRead(presenter: "ICB Productions",
                                                             storedSource: PresenterSource.scout.rawValue) == false)
        #expect(PresenterProvenance.survivesAnOrdinaryReRead(presenter: "ICB Productions",
                                                             storedSource: nil) == false)
        // A blank name is nothing to protect, however it is stamped. The extraction boundary writes an
        // empty string rather than nil in places (OrganiserNaming's own note), so whitespace counts as
        // blank here for the same reason it does there.
        #expect(PresenterProvenance.survivesAnOrdinaryReRead(presenter: "   ",
                                                            storedSource: PresenterSource.aiBatch.rawValue) == false)
        #expect(PresenterProvenance.survivesAnOrdinaryReRead(presenter: nil,
                                                            storedSource: PresenterSource.aiBatch.rawValue) == false)
        // An empty stamp is an absent stamp, not an unreadable one.
        #expect(PresenterProvenance.survivesAnOrdinaryReRead(presenter: "ICB Productions",
                                                            storedSource: "  ") == false)
    }
}
