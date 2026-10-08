import Testing
import Foundation
import SwiftData

// #4339 (A11): the lead paste lands like every other entry point. Its whole table reads (the brand corpus and
// the history it matches against) run off the main thread behind the entry flush, it takes its turn for the
// store at Dan's priority, a whole table read that fails is recorded rather than read as an empty store, and a
// save that fails is put back and said, never left pending and never counted as shows added.
@MainActor
@Suite("#4339 the lead paste lands off the main thread, in turn, and puts back a failed save", .serialized)
struct LeadPasteLandingTests {

    // Thread facts recorded from a background read, so they are lock protected.
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var onMain: [Bool] = []
        func note() { lock.lock(); onMain.append(Thread.isMainThread); lock.unlock() }
        var all: [Bool] { lock.lock(); defer { lock.unlock() }; return onMain }
    }

    struct Refused: Error {}

    private static let today = "2026-10-05"
    private static let now = ISO8601DateFormatter().date(from: "2026-10-05T16:00:00Z")!

    private func event(_ title: String) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: "Pier Nine Players", venue: "Pier Nine Room",
                       performanceDate: "2026-11-21", sourceUrl: "https://piernine.example/" + title.lowercased(),
                       location: "New York, NY")
    }

    private func seeded() throws -> (ModelContainer, ModelContext) {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        let context = container.mainContext
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: "Stored Show", performanceDate: "2026-10-30",
                                                             venue: "Pier Nine Room"),
                         groupName: "Stored Show", discipline: "music", venue: "Pier Nine Room",
                         performanceDate: "2026-10-30", sourceListingURL: "https://piernine.example/stored",
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "invented",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         ingestedAt: Self.now)
        context.insert(p)
        try context.save()
        return (container, context)
    }

    private func count(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<Prospect>())
    }

    @Test func theShowTableIsReadOffTheMainThreadAndOnlyThere() async throws {
        let (container, context) = try seeded()
        let reads = Reads()
        let result = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            readProspectTable: { reads.note(); return try $0.fetch(FetchDescriptor<Prospect>()) },
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
            into: context)
        guard case .landed(let outcome) = result else {
            Issue.record("the paste did not land: \(result)")
            return
        }
        #expect(outcome.inserted == 1)
        #expect(try count(container) == 2)
        // The read phase reads the table ONCE, off the main thread, for the corpus and the history together.
        // What follows it on the main thread is the landing's own working set (`ScoutLandingStore`, A4's),
        // read under the token as every entry point's landing block reads it.
        #expect(reads.all.first == false, "the read phase read the show table on the main thread: \(reads.all)")
        #expect(reads.all.filter { !$0 }.count == 1, "the show table was read off the main thread \(reads.all.filter { !$0 }.count) times")
    }

    @Test func anUnreadableShowTableIsRecordedRatherThanReadAsEmpty() async throws {
        // The container is held for the whole test: a context whose container has been released traps in
        // SwiftData on its first use, which is a fault of the test, not of the landing.
        let (container, context) = try seeded()
        defer { withExtendedLifetime(container) {} }
        // Unreadable in the read phase only; the landing's own working set, on the main thread, still reads.
        let result = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            readProspectTable: { context in
                guard Thread.isMainThread else { throw Refused() }
                return try context.fetch(FetchDescriptor<Prospect>())
            },
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
            into: context)
        guard case .landed(let outcome) = result else {
            Issue.record("the paste did not land: \(result)")
            return
        }
        #expect(outcome.degradedReads.contains(.repeatClientHistory), "degraded: \(outcome.degradedReads)")
        #expect(outcome.degradedReads.contains(.venueBrandCorpus), "degraded: \(outcome.degradedReads)")
    }

    /// #4490: a show table that cannot be read at all, the landing's own working set included, is a recorded
    /// outcome (the show counted as store unreadable, the reads named), never a trap. The trap first reported
    /// there was this file releasing its container; this holds the real behaviour.
    @Test func aShowTableUnreadableEverywhereIsRecordedNotATrap() async throws {
        let (container, context) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let result = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            readProspectTable: { _ in throw Refused() },
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
            into: context)
        // Said as a failed read, never as a page with nothing new on it (L215).
        #expect(result == .refused(LeadIntake.storeUnreadableMessage), "said \(result)")
        #expect(try count(container) == 1)
    }

    /// #4339 review: a paste where some shows landed and some could not be checked against the store says so
    /// beside the run's note, rather than reporting the added count as the whole page.
    @Test func aPartlyUnreadablePasteNamesTheShowsItCouldNotAdd() {
        #expect(LeadIntake.withUnreadableShows("Read two months.", count: 0) == "Read two months.")
        #expect(LeadIntake.withUnreadableShows(nil, count: 0) == nil)
        let one = LeadIntake.withUnreadableShows(nil, count: 1)
        #expect(one?.hasPrefix("One show on that page wasn't added") == true, "said \(one ?? "nothing")")
        let three = LeadIntake.withUnreadableShows("Read two months.", count: 3)
        #expect(three?.hasPrefix("Read two months. 3 shows on that page weren't added") == true,
                "said \(three ?? "nothing")")
    }

    @Test func aSaveThatFailsIsPutBackAndSaidAndCountsNoShows() async throws {
        let (container, context) = try seeded()
        let result = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights"), event("Low Tide")], today: Self.today, now: Self.now,
            landings: LandingSingleFlight(),
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
            saveSource: { _ in throw Refused() }, into: context)
        guard case .refused(let sentence) = result else {
            Issue.record("a paste whose save failed reported \(result)")
            return
        }
        #expect(sentence == LeadIntake.saveFailedMessage, "said: \(sentence)")
        // Not `!hasChanges`, which a revert cannot give (a field written back to its committed value still reads
        // as changed): the context holds exactly what the store holds, with no pending insert or delete.
        #expect(try ScoutFailedSaveIsolationTests.holdsOnlyWhatTheStoreHolds(context, container),
                "the failed save's writes were left pending for a later save to carry")
        #expect(try count(container) == 1)
        // #4536: the paste is on the record as a landing that started and did not land, with its flush count.
        let run = try #require(try runs(container).first)
        #expect(try runs(container).count == 1)
        #expect(run.landedAt == nil, "a paste whose save failed was recorded as landed")
        #expect(run.entryFlushSaves == 0)
    }

    // MARK: - #4536: the paste's landing record

    private func runs(_ container: ModelContainer) throws -> [LandingRun] {
        try ModelContext(container).fetch(FetchDescriptor<LandingRun>())
    }

    /// #4536: the paste records a landing as runScout and the ingest do (#4335), under its own run identity, so
    /// its entry flushes are counted with theirs by `scripts/landing-flush-rate.sh` (#4338). With an edit of Dan's
    /// pending, the read phase flush saves it and the flush under the store finds nothing more, so one; with
    /// nothing pending, zero, which is a recorded count and not "no count" (nil).
    @Test func aLandedPasteRecordsItsLandingAndHowManyOfItsEntryFlushesSaved() async throws {
        let (container, context) = try seeded()
        let stored = try #require(try context.fetch(FetchDescriptor<Prospect>()).first)
        stored.groupName = "Renamed By Dan"
        let result = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
            into: context)
        guard case .landed = result else {
            Issue.record("the paste did not land: \(result)")
            return
        }
        #expect(!context.hasChanges, "the paste left its record unsaved")
        let run = try #require(try runs(container).first, "the paste recorded no landing")
        #expect(try runs(container).count == 1)
        #expect(run.entryPointRaw == LandingSingleFlight.EntryPoint.leadPaste.rawValue)
        #expect(run.runIdentity.hasPrefix("paste-"), Comment(rawValue: run.runIdentity))
        #expect(run.startedAt == Self.now)
        #expect(run.landedAt == Self.now, "a paste that landed was not stamped as landed")
        #expect(run.entryFlushSaves == 1)

        // A second paste is a landing of its own, under its own identity, and with nothing pending counts zero.
        _ = await LeadPasteLanding.landPastedLead(
            [event("Low Tide")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
            into: context)
        let both = try runs(container)
        #expect(Set(both.map(\.runIdentity)).count == 2, Comment(rawValue: "\(both.map(\.runIdentity))"))
        #expect(both.map(\.entryFlushSaves).sorted { ($0 ?? -1) < ($1 ?? -1) } == [0, 1])
    }

    /// The flush under the store counts too: an edit Dan makes while the paste waits its turn is saved by it.
    @Test func anEditSavedByTheFlushUnderTheStoreIsCounted() async throws {
        let (container, context) = try seeded()
        let flight = LandingSingleFlight(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        let held = try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout, deadline: .seconds(60))
        let stored = try #require(try context.fetch(FetchDescriptor<Prospect>()).first)
        stored.groupName = "Renamed Before"
        let paste = Task { @MainActor in
            await LeadPasteLanding.landPastedLead([event("Harbor Lights")], today: Self.today, now: Self.now,
                                                  landings: flight,
                                                  exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
                                                  into: context)
        }
        let waiting = await waitUntil("the paste waits its turn", timeout: .seconds(30)) { flight.queue == [.leadPaste] }
        #expect(waiting, "the paste never queued for the store: \(flight.queue)")
        stored.groupName = "Renamed While Waiting"
        held.end()
        guard case .landed = await paste.value else {
            Issue.record("the paste did not land")
            return
        }
        #expect(try runs(container).map(\.entryFlushSaves) == [2])
    }

    /// A paste that read nothing it could judge refuses, and its record says it did not land.
    @Test func aPasteRefusedForAnUnreadableStoreIsRecordedAsNotLanded() async throws {
        let (container, context) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let result = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            readProspectTable: { _ in throw Refused() },
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
            into: context)
        #expect(result == .refused(LeadIntake.storeUnreadableMessage), "said \(result)")
        let run = try #require(try runs(container).first, "the refused paste recorded no landing")
        #expect(run.landedAt == nil, "a refused paste was recorded as landed")
        #expect(!context.hasChanges, "the refused paste left its record unsaved")
    }

    /// The stamp rides a save of its own after the shows', so a store that refuses it leaves the shows landed,
    /// the stamp put back, and nothing pending.
    @Test func aStampTheStoreRefusesIsPutBackAndThePasteStillLanded() async throws {
        let (container, context) = try seeded()
        let result = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
            saveClosing: { _ in throw Refused() }, into: context)
        guard case .landed = result else {
            Issue.record("a paste whose shows saved reported \(result)")
            return
        }
        #expect(try count(container) == 2)
        // The record itself reached the store with the shows' save; only its stamp was refused.
        let stored = try runs(container)
        #expect(stored.count == 1, "the record went with the refused stamp: \(stored.count) rows")
        #expect(stored.first?.landedAt == nil, "a stamp the store refused reached it")
        #expect(stored.first?.entryFlushSaves == 0)
        #expect(try ScoutFailedSaveIsolationTests.holdsOnlyWhatTheStoreHolds(context, container),
                "the refused stamp was left pending for a later save to carry")
    }

    /// #4339: a failed save that could not all be put back tells Dan to paste again, and says what that does:
    /// the next paste runs the entry flush first, which saves what was left or names the shows it still cannot
    /// save, before adding anything. Both halves of that sentence are driven here, so it cannot promise a step
    /// the paste does not take.
    @Test func aSaveThatCannotBePutBackSaysToPasteAgainAndTheNextPasteDoesWhatItSays() async throws {
        let (container, context) = try seeded()
        // The deletion is the injected save's own: nothing on the landing path deletes a committed row, and a
        // committed row deleted cannot be brought back without `rollback()`, which is banned.
        let first = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
            saveSource: { ctx in
                if let stored = try? ctx.fetch(FetchDescriptor<Prospect>()).first(where: { $0.groupName == "Stored Show" }) {
                    ctx.delete(stored)
                }
                throw Refused()
            }, into: context)
        #expect(first == .refused(LeadIntake.notRevertedMessage), "said \(first)")
        #expect(LeadIntake.notRevertedMessage.contains("Paste the page again"),
                "the not reverted sentence gives Dan nothing to do: \(LeadIntake.notRevertedMessage)")
        #expect(context.hasChanges, "nothing was left unsaved, so this proves nothing about the next paste")
        // #4536: what is left is only what could not be put back, never the paste's own unsaved record, which
        // the next paste's refusal would otherwise name as one more record of Dan's.
        #expect(!context.insertedModelsArray.contains { $0 is LandingRun },
                "the paste's record was left pending for a later save to carry")

        // "or tells you which shows it still can't save": a flush that cannot save names them and adds nothing.
        let refused = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
            saveEntry: { _ in throw Refused() }, into: context)
        #expect(refused == .refused(LeadIntake.recentEditsUnsaved(["Stored Show"])), "said \(refused)")
        #expect(try count(container) == 1, "a paste that could not save what was left added shows")

        // "Overture saves what is left first": the next paste that can save does, then adds the page.
        let landed = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
            into: context)
        guard case .landed = landed else {
            Issue.record("the paste after a not reverted save did not land: \(landed)")
            return
        }
        #expect(!context.hasChanges, "the paste left the earlier failure's changes unsaved")
        let fresh = try ModelContext(container).fetch(FetchDescriptor<Prospect>()).map(\.groupName).sorted()
        #expect(fresh == ["Harbor Lights"], "the store holds \(fresh)")
    }

    @Test func aPendingEditIsSavedBeforeThePasteLandsAndAFlushThatFailsRefusesIt() async throws {
        let (container, context) = try seeded()
        let stored = try #require(try context.fetch(FetchDescriptor<Prospect>()).first)
        stored.groupName = "Renamed By Dan"
        let refused = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
            saveEntry: { _ in throw Refused() }, into: context)
        #expect(refused == .refused(LeadIntake.recentEditsUnsaved(["Renamed By Dan"])), "said \(refused)")
        #expect(try count(container) == 1, "a refused paste landed shows")
        #expect(stored.groupName == "Renamed By Dan" && context.hasChanges, "the refusal touched Dan's edit")

        let landed = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
            into: context)
        guard case .landed = landed else {
            Issue.record("the paste did not land: \(landed)")
            return
        }
        let fresh = try ModelContext(container).fetch(FetchDescriptor<Prospect>()).map(\.groupName).sorted()
        #expect(fresh == ["Harbor Lights", "Renamed By Dan"], "the store holds \(fresh)")
    }

    /// The second entry flush, the one taken once the store is held: an edit Dan makes while the paste reads and
    /// waits is saved before anything is applied, so the put back of a failed save, which restores COMMITTED
    /// values, cannot take his edit with it.
    @Test func anEditMadeWhileThePasteWaitsSurvivesItsFailedSave() async throws {
        let (container, context) = try seeded()
        let flight = LandingSingleFlight(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        let held = try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout, deadline: .seconds(60))
        let paste = Task { @MainActor in
            await LeadPasteLanding.landPastedLead([event("Harbor Lights")], today: Self.today, now: Self.now,
                                                  landings: flight,
                                                  exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
                                                  saveSource: { _ in throw Refused() },
                                                  into: context)
        }
        let waiting = await waitUntil("the paste waits its turn", timeout: .seconds(30)) { flight.queue == [.leadPaste] }
        #expect(waiting, "the paste never queued for the store: \(flight.queue)")
        let stored = try #require(try context.fetch(FetchDescriptor<Prospect>()).first)
        stored.groupName = "Renamed While Waiting"
        held.end()
        let result = await paste.value
        #expect(result == .refused(LeadIntake.saveFailedMessage), "said \(result)")
        let fresh = try ModelContext(container).fetch(FetchDescriptor<Prospect>()).map(\.groupName)
        #expect(fresh == ["Renamed While Waiting"], "the store holds \(fresh) after the paste's failed save")
        #expect(stored.groupName == "Renamed While Waiting", "the put back undid Dan's edit")
    }

    /// #4339 review: through the sheet's model, a paste waiting for the store says it is working, and a sheet
    /// Dan closed or restarted meanwhile is not overwritten by the landing's answer when it finishes.
    @Test func theSheetSaysWorkingWhileThePasteWaitsAndAResetIsNotOverwritten() async throws {
        let (container, context) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let flight = LandingSingleFlight(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        let held = try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout, deadline: .seconds(60))
        let url = URL(string: "https://piernine.example/season")!
        let leadId = LeadIntakeModel.sourceId(for: url)
        let answer = ScoutExtractResults(version: 1, generatedAt: Self.today + "T12:00:00Z", results: [
            ScoutExtractResult(sourceId: leadId, verdict: .upcomingListings,
                               events: [ScoutExtractEvent(title: "Harbor Lights", presenter: "Pier Nine Players",
                                                          venue: "Pier Nine Room", performanceDate: "2026-11-21",
                                                          sourceUrl: "https://piernine.example/harbor-lights",
                                                          location: "New York, NY")],
                               note: nil)])
        let defaults = ScratchDefaults.make("LeadPasteLandingTests.reset")
        let model = LeadIntakeModel(
            defaults: defaults,
            fetch: { FetchedPage(normalizedHTML: LandingOracleCorpus.leadPage, finalURL: $0.absoluteString,
                                 contentHash: "lead-paste-reset") },
            pin: { _, _ in URL(fileURLWithPath: "/dev/null/lead-paste-reset.html") },
            launch: { _ in },
            readResults: { $0 == leadId ? answer : nil },
            isRunAlive: { false },
            landings: flight,
            exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history)
        model.urlText = url.absoluteString
        let start = Task { @MainActor in
            await model.start(into: context, now: Self.now, today: Self.today, pollEvery: 0, giveUpAfter: 0,
                              sleep: { _ in })
        }
        let waiting = await waitUntil("the paste waits its turn", timeout: .seconds(30)) { flight.queue == [.leadPaste] }
        #expect(waiting, "the paste never queued for the store: \(flight.queue)")
        if case .working = model.phase {} else { Issue.record("a waiting paste shows \(model.phase), not working") }
        model.reset()
        held.end()
        await start.value
        #expect(model.phase == .idle, "the landing wrote \(model.phase) over the sheet Dan reset")
        // The shows landed, so the link is recorded as handed over, reset or not.
        #expect(try count(container) == 2)
        #expect(LeadSubmissions.contains(url, in: defaults), "a link whose shows landed was not recorded as handed over")
    }

    @Test func thePasteWaitsForTheLandingInProgressAtTheFrontOfTheQueue() async throws {
        let (container, context) = try seeded()
        let flight = LandingSingleFlight(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        let held = try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout, deadline: .seconds(60))
        // A scout landing queued FIRST, so the paste reaches the front only by its priority, never by its order.
        let scoutWaiting = Task { @MainActor in
            try await flight.begin(entryPoint: .runScoutLanding, priority: .scout, deadline: .seconds(60))
        }
        let scoutQueued = await waitUntil("the scout landing queues", timeout: .seconds(30)) {
            flight.queue == [.runScoutLanding]
        }
        #expect(scoutQueued, "the scout landing never queued: \(flight.queue)")
        let paste = Task { @MainActor in
            await LeadPasteLanding.landPastedLead([event("Harbor Lights")], today: Self.today, now: Self.now,
                                                  landings: flight,
                                                  exportURL: AbsentHandoff.export, importedHistory: AbsentHandoff.history,
                                                  into: context)
        }
        let waiting = await waitUntil("the paste waits at the front", timeout: .seconds(30)) {
            flight.queue == [.leadPaste, .runScoutLanding]
        }
        #expect(waiting, "the paste is not waiting at the front of the queue: \(flight.queue)")
        #expect(try count(container) == 1, "the paste landed while another landing held the store")
        held.end()
        let result = await paste.value
        (try? await scoutWaiting.value)?.end()
        guard case .landed = result else {
            Issue.record("the paste did not land once the store was free: \(result)")
            return
        }
        #expect(try count(container) == 2)
        #expect(!flight.isHeld, "the paste kept the store after it landed")
    }
}
