import Testing
import Foundation
import SwiftData

// #4338 (A10, the L371 decisions on #4332, #4334 and #4335): the standing states a scout landing can leave, and
// the two ways out of each. An entry flush refused twice in a row stands until a save goes through or Dan discards
// the edits; a landing the recovery stopped trying, and a landing record nobody can read, each stand with "Try
// again" and "Discard". Every Discard says first what it will change, derived from the state it changes (L180),
// and the edits' discard puts committed values back through A5's revert, never `rollback()` (L443).
//
// Autosave is off and every failure is injected through a save seam, as A5's tests do. Every name is invented.
@MainActor
@Suite("A landing's standing states, and the two ways out of each (#4338)")
final class LandingStandingActionsTests {
    private let sandboxes = TemporarySandboxes()
    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private struct SaveRefused: Error, CustomStringConvertible {
        var description: String { "the store refused the save" }
    }

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory(AppSchema.models)
    }

    private func show(_ title: String, in ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k-\(title)", groupName: title, discipline: "music", venue: "Harbor Stage",
                         performanceDate: "2026-11-20", sourceListingURL: "https://harborstage.example/\(title)",
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "invented", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.presenter = "Harbor Stage Collective"
        ctx.insert(p)
        return p
    }

    // MARK: - the entry flush's standing state

    @Test func twoRefusalsInARowStandUntilASaveGoesThrough() throws {
        let ctx = try container().mainContext
        let record = EntryFlushRecord()
        let stored = show("Tidewater Suite", in: ctx)
        try ctx.save()
        stored.presenter = "Lantern Hall Players"
        let refuse: (ModelContext) throws -> Void = { _ in throw SaveRefused() }

        #expect(ScoutService.flushBeforeLanding(ctx, save: refuse, record: record)
                == .refused(.recentEditsUnsaved(rows: ["Tidewater Suite"])))
        #expect(!record.isStuck, "one refusal is a report, not yet the standing state")
        _ = ScoutService.flushBeforeLanding(ctx, save: refuse, record: record)
        #expect(record.isStuck && record.rows == ["Tidewater Suite"])

        // A flush that saves ends it, and says it saved.
        #expect(ScoutService.flushBeforeLanding(ctx, save: { try $0.save() }, record: record) == .saved)
        #expect(!record.isStuck && record.refusalsInARow == 0)
        // And a flush with nothing pending is not a save, and ends nothing that is not there.
        #expect(ScoutService.flushBeforeLanding(ctx, save: refuse, record: record) == .nothingPending)
    }

    @Test func aSuccessBetweenTwoRefusalsMeansTheyWereNotInARow() throws {
        let ctx = try container().mainContext
        let record = EntryFlushRecord()
        let stored = show("Copper Tide", in: ctx)
        try ctx.save()
        let refuse: (ModelContext) throws -> Void = { _ in throw SaveRefused() }
        stored.presenter = "One"
        _ = ScoutService.flushBeforeLanding(ctx, save: refuse, record: record)
        _ = ScoutService.flushBeforeLanding(ctx, save: { try $0.save() }, record: record)
        stored.presenter = "Two"
        _ = ScoutService.flushBeforeLanding(ctx, save: refuse, record: record)
        #expect(!record.isStuck, Comment(rawValue: "refusals in a row: \(record.refusalsInARow)"))
    }

    // MARK: - try saving again, and discard these unsaved edits

    @Test func tryingToSaveAgainSaysWhatHappenedEitherWay() throws {
        let ctx = try container().mainContext
        let record = EntryFlushRecord()
        let stored = show("Tidewater Suite", in: ctx)
        try ctx.save()
        stored.presenter = "Lantern Hall Players"
        record.refused(rows: ["Tidewater Suite"])
        record.refused(rows: ["Tidewater Suite"])

        #expect(UnsavedEditsDiscard.trySavingAgain(in: ctx, now: now, save: { _ in throw SaveRefused() },
                                                   record: record) == nil)
        #expect(record.isStuck && record.lastTryFailedAt == now, "a failed try must stay stuck and say it was tried")

        #expect(UnsavedEditsDiscard.trySavingAgain(in: ctx, now: now, record: record) == .editsSaved)
        #expect(!record.isStuck && record.lastTryFailedAt == nil)
        #expect(!ctx.hasChanges)
    }

    // The confirmation names each row and the fields that go back, the row that was never saved, and the row the
    // revert cannot bring back, from the same comparison the revert makes.
    @Test func theDiscardConfirmationNamesTheRowsAndTheFieldsItWillChange() throws {
        let ctx = try container().mainContext
        let edited = show("Tidewater Suite", in: ctx)
        let removed = show("Kite Parade", in: ctx)
        try ctx.save()
        edited.presenter = "Lantern Hall Players"
        edited.venue = "Lantern Hall"
        _ = show("Night Ferry", in: ctx)
        ctx.delete(removed)

        let preview = UnsavedEditsDiscard.preview(in: ctx)
        #expect(preview.changed == [.init(name: "Tidewater Suite", fields: ["presenter", "venue"])],
                Comment(rawValue: "\(preview.changed)"))
        #expect(preview.removed == ["Night Ferry"] && preview.staysRemoved == ["Kite Parade"])
        #expect(UnsavedEditsDiscard.consequence(preview) == "Tidewater Suite goes back to its saved presenter and "
                + "venue. Night Ferry, which was never saved, is removed. Overture can't bring back Kite Parade, "
                + "which you removed, so it stays removed. Nothing else changes.")
        // Asking changed nothing.
        #expect(edited.presenter == "Lantern Hall Players" && ctx.hasChanges)
    }

    @Test func aLongListOfEditsIsNamedThenCounted() {
        let rows = (1...8).map { UnsavedEditsDiscard.Row(name: "Show \($0)", fields: ["venue"]) }
        let said = UnsavedEditsDiscard.consequence(.init(changed: rows))
        #expect(said.contains("Show 6 goes back to its saved venue.") && !said.contains("Show 7"))
        #expect(said.contains("2 more records go back to how they were last saved."))
        #expect(UnsavedEditsDiscard.consequence(.init()) == "Nothing is waiting to be saved, so nothing changes.")
    }

    // Discard puts the saved values back on the instance Dan's screen holds (L443: never `rollback()`, which
    // leaves held instances reading the discarded values), takes out the row never saved, and saves.
    @Test func discardingPutsTheSavedValuesBackAndSaves() throws {
        let c = try container()
        let ctx = c.mainContext
        let record = EntryFlushRecord()
        let edited = show("Tidewater Suite", in: ctx)
        try ctx.save()
        edited.presenter = "Lantern Hall Players"
        _ = show("Night Ferry", in: ctx)
        record.refused(rows: ["Night Ferry", "Tidewater Suite"])
        record.refused(rows: ["Night Ferry", "Tidewater Suite"])

        #expect(UnsavedEditsDiscard.perform(in: ctx, record: record) == .editsDiscarded)
        #expect(edited.presenter == "Harbor Stage Collective", "the held instance still reads the discarded value")
        #expect(!ctx.hasChanges && !record.isStuck)
        let fresh = try ModelContext(c).fetch(FetchDescriptor<Prospect>())
        #expect(fresh.map(\.groupName) == ["Tidewater Suite"] && fresh.first?.presenter == "Harbor Stage Collective")
    }

    // When the save after the discard still fails, nothing of Dan's is pending any more, so it is the store
    // refusing, which is said as such, and the standing state stays.
    @Test func aDiscardWhoseSaveStillFailsSaysTheStoreIsRefusing() throws {
        let ctx = try container().mainContext
        let record = EntryFlushRecord()
        let edited = show("Tidewater Suite", in: ctx)
        try ctx.save()
        edited.presenter = "Lantern Hall Players"
        record.refused(rows: ["Tidewater Suite"])
        record.refused(rows: ["Tidewater Suite"])
        let outcome = UnsavedEditsDiscard.perform(in: ctx, save: { _ in throw SaveRefused() }, record: record)
        #expect(outcome == .editsDiscardedButStillNotSaving(why: "the store refused the save"),
                Comment(rawValue: "\(outcome)"))
        #expect(record.isStuck)
        #expect(edited.presenter == "Harbor Stage Collective", "the edit was not put back")
    }

    @Test func aPropertyIsNamedInWords() {
        #expect(LandingRevert.propertyName(\Prospect.venue) == "venue")
        #expect(LandingRevert.propertyName(\Prospect.sourceListingURL) == "source listing URL")
        #expect(LandingRevert.propertyName(\WatchedSource.kindRaw) == "kind")
        #expect(LandingRevert.propertyName(\LandingRun.entryFlushSaves) == "entry flush saves")
    }

    // MARK: - a landing the recovery stopped trying

    private func folders(_ name: String) throws -> (journals: LandingJournals, pending: PendingScoutIngests,
                                                     failures: HandoffReadFailures) {
        let root = try sandboxes.make(named: name)
        let failures = HandoffReadFailures()
        return (LandingJournals(directory: root.appendingPathComponent("journals"), readFailures: failures),
                PendingScoutIngests(directory: root.appendingPathComponent("pending"), readFailures: failures),
                failures)
    }

    private func stopped(in ctx: ModelContext, journals: LandingJournals) throws -> LandingRef {
        for id in ["harbor", "lantern"] {
            ctx.insert(WatchedSource(sourceId: id, orgName: "Org \(id)", listingsURL: "https://\(id).example",
                                     kind: .html))
        }
        try journals.start(LandingJournal(runIdentity: "sweep-stopped", sequence: 7, entryPoint: .runScoutLanding,
                                          sources: [.init(sourceId: "harbor", pageHash: nil),
                                                    .init(sourceId: "lantern", pageHash: nil)], now: now))
        let run = LandingRun(runIdentity: "sweep-stopped", landedAt: nil, sequence: 7, entryPoint: .runScoutLanding,
                             startedAt: now)
        run.attemptCount = LandingRecovery.attemptCap
        ctx.insert(run)
        try ctx.save()
        return LandingRef(runIdentity: "sweep-stopped", sequence: 7)
    }

    // "Try again" gives ONE more attempt, so the recovery takes it up at idle and, if it fails, stops again (L365).
    @Test func tryAgainGivesTheStoppedLandingOneMoreAttempt() throws {
        let ctx = try container().mainContext
        let f = try folders("standing-try-again")
        let ref = try stopped(in: ctx, journals: f.journals)
        #expect(try LandingRecovery.survey(journals: f.journals, pending: f.pending, in: ctx).first?.finding
                == .stoppedRetrying(attempts: LandingRecovery.attemptCap))

        #expect(LandingRecovery.allowAnotherTry(ref, in: ctx) == nil)
        #expect(try LandingRun.record(ref.runIdentity, sequence: ref.sequence, in: ctx)?.attemptCount
                == LandingRecovery.attemptCap - 1)
        #expect(try LandingRecovery.survey(journals: f.journals, pending: f.pending, in: ctx).first?.finding == .sweep)
    }

    @Test func aTryAgainThatCannotBeSavedIsPutBackAndSaysWhy() throws {
        let ctx = try container().mainContext
        let f = try folders("standing-try-again-refused")
        let ref = try stopped(in: ctx, journals: f.journals)
        let why = LandingRecovery.allowAnotherTry(ref, in: ctx, save: { _ in throw SaveRefused() })
        #expect(why == "its record could not be saved (the store refused the save)", Comment(rawValue: why ?? "nil"))
        #expect(try LandingRun.record(ref.runIdentity, sequence: ref.sequence, in: ctx)?.attemptCount
                == LandingRecovery.attemptCap, "a retry nothing recorded was left in the context")
    }

    @Test func discardRetiresTheJournalAndItsKeptCopy() throws {
        let f = try folders("standing-discard")
        let copy = try f.pending.record(Data("{}".utf8), sequence: 8, now: now)
        try f.journals.start(LandingJournal(runIdentity: copy.contentHash, sequence: 8, entryPoint: .scoutExtractIngest,
                                            sources: [], now: now, resultsCopy: copy.contentHash))
        let ref = LandingRef(runIdentity: copy.contentHash, sequence: 8)
        #expect(LandingRecovery.discard(ref, journals: f.journals, pending: f.pending))
        #expect(f.journals.pending(sequence: 8) == nil)
        #expect(try f.pending.list().isEmpty)
        #expect(!LandingRecovery.discard(ref, journals: f.journals, pending: f.pending), "a second discard found one")
    }

    @Test func discardingAStoppedLandingSaysWhatItLeaves() {
        #expect(LandingRecovery.discardConsequence(keptCopy: true, unlanded: 4)
                == "The calendar results it kept are deleted. The 4 calendars it had not saved stay unread, and "
                + "your next scout reads them again.")
        #expect(LandingRecovery.discardConsequence(keptCopy: false, unlanded: 1)
                == "The calendar it had not saved stays unread, and your next scout reads it again.")
        #expect(LandingRecovery.discardConsequence(keptCopy: false, unlanded: 0)
                == "Every calendar in it was already saved, so nothing waits to be read.")
    }

    // MARK: - a landing record nobody can read

    @Test func anUnreadableRecordStandsOnTheLandingLineAndNotTheFileNotice() throws {
        let ctx = try container().mainContext
        let f = try folders("standing-unreadable")
        try FileManager.default.createDirectory(at: f.journals.directory, withIntermediateDirectories: true)
        let name = LandingJournals.fileName(sequence: 11, runIdentity: "sweep-garbled")
        try Data("not a landing record".utf8).write(to: f.journals.directory.appendingPathComponent(name))

        let survey = try LandingRecovery.surveyAll(journals: f.journals, pending: f.pending, in: ctx)
        #expect(survey.unreadable == [f.journals.directory.appendingPathComponent(name + LandingJournals.quarantineSuffix).path])
        #expect(f.failures.current().isEmpty,
                Comment(rawValue: "said twice, once in the file notice: \(f.failures.current())"))
        // Listed again, it is still there, still standing.
        #expect(try LandingRecovery.surveyAll(journals: f.journals, pending: f.pending, in: ctx).unreadable.count == 1)
    }

    @Test func tryAgainReadsTheRecordOnceMoreAndDiscardRemovesIt() throws {
        let f = try folders("standing-reread")
        try FileManager.default.createDirectory(at: f.journals.directory, withIntermediateDirectories: true)
        // A record set aside that reads now: back in place, a pending journal again.
        let good = LandingJournal(runIdentity: "sweep-back", sequence: 12, entryPoint: .runScoutLanding, sources: [],
                                  now: now)
        let setAside = f.journals.url(for: good).path + LandingJournals.quarantineSuffix
        try LandingJournals.encoded(good).write(to: URL(fileURLWithPath: setAside))
        #expect(f.journals.tryReadingAgain(path: setAside) == .readable)
        #expect(f.journals.pending(sequence: 12) == good)

        // One that still does not read stays set aside, and says why.
        let bad = f.journals.directory.appendingPathComponent(
            LandingJournals.fileName(sequence: 13, runIdentity: "sweep-bad") + LandingJournals.quarantineSuffix)
        try Data("garbled".utf8).write(to: bad)
        guard case .stillUnreadable = f.journals.tryReadingAgain(path: bad.path) else {
            Issue.record("a record that still does not read was called readable")
            return
        }
        #expect(FileManager.default.fileExists(atPath: bad.path))

        try f.journals.discardUnreadable(path: bad.path)
        #expect(!FileManager.default.fileExists(atPath: bad.path))
        // Only a journal's file, in this folder, is ever removed.
        let elsewhere = try sandboxes.make(named: "standing-elsewhere").appendingPathComponent("0000000014-x.json")
        try Data("x".utf8).write(to: elsewhere)
        #expect(throws: (any Error).self) { try f.journals.discardUnreadable(path: elsewhere.path) }
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    @Test func discardingAnUnreadableRecordSaysWhatItsNameAndTheStoreCanStillSay() {
        #expect(LandingJournals.runIdentity(inName: "0000000011-sweep-garbled.json.unreadable") == "sweep-garbled")
        #expect(LandingJournals.runIdentity(inName: "0000000011-abc123.json") == "abc123")
        #expect(LandingJournals.runIdentity(inName: "notes.txt") == nil)
        #expect(LandingJournals.discardConsequence(landedAt: now, keptCopy: true)
                == "That landing finished at \(LandingWaitCopy.landedTime(now)), so discarding its record changes nothing else.")
        #expect(LandingJournals.discardConsequence(landedAt: nil, keptCopy: true)
                == "Its calendar results are still kept and Overture will offer them again, so discarding its record changes nothing else.")
        #expect(LandingJournals.discardConsequence(landedAt: nil, keptCopy: false)
                == "Overture can't tell which calendars that landing named, so any it had not saved stay unread until your next scout reads them again.")
    }
}
