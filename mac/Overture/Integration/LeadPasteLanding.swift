import Foundation
import SwiftData

// #4339 (A11): the lead paste lands the way the ingest and the scout's own sweep land, and through the same
// shared pieces, so the three entry points cannot come to disagree about what a landing is (L263).
//
// WHAT CHANGED, carried from the #4332 and #4334 agents (comment on #4339, 2026-10-02). `LeadIntakeModel.importAll`
// used to call `ScoutService.apply` with no classify pass, so `apply` read the whole show table for the brand
// corpus ON THE MAIN THREAD (`venueBrandCorpus(in:)`), the history came from a second whole table fetch on the
// main thread whose failure read as an empty store (`(try? fetch) ?? []`, L215), nothing waited its turn for
// the store, and a save that failed left every write pending for the next save to carry while the sheet said
// the shows were added. Now, in order:
//   1. the entry flush (`ScoutService.flushBeforeLanding`): a background context reads only what is SAVED, so
//      anything pending is saved first, or the paste is refused by name before anything is read;
//   2. the read phase OFF the main thread, through a context of its own: Downbeat's export (a file), the show
//      table read ONCE for both the brand corpus and the history, and Dan's producer corrections. A read that
//      fails is recorded on the outcome (`degradedReads`), never read as an empty store;
//   3. the classify pass off the main thread (`ScoutClassify.offTheCallersActor`);
//   4. the store, taken through `LandingSingleFlight.begin` at Dan's priority, after the last read-phase await
//      (the 2026-09-29 token scope decision), so a paste waits at the FRONT of the queue for the landing in
//      progress rather than interleaving with it;
//   5. the entry flush again, now the store is held, then `apply` with the pre-classified pass;
//   6. a failed save put back through `ScoutService.isolateFailedSave`, and said.
// #4536: and, between 5 and 6, a landing record (`LandingRun`) carrying how many of the two entry flushes saved
// pending edits, stamped landed only once the shows saved, so the paste is counted where runScout's and the
// ingest's landings are (`scripts/landing-flush-rate.sh`).
// The paste still never reconciles (#826): `apply` is given no `feed`.
@MainActor
enum LeadPasteLanding {
    enum Result: Equatable {
        case landed(ScoutService.Outcome)
        // Nothing from the page is in the store, in Dan's words.
        case refused(String)
    }

    // What the read phase hands back across the actor boundary: values only.
    private struct ReadPhase: Sendable {
        let clients: [DownbeatClient]
        let bookings: [OvertureBooking]
        let blockedDates: [String]
        let health: DownbeatBridge.Health
        let history: [HistoryRecord]
        let corpus: ScoutService.CorpusRead
    }

    typealias ExportLoad = @Sendable () -> (clients: [DownbeatClient], bookings: [OvertureBooking],
                                            blockedDates: [String], health: DownbeatBridge.Health)

    static func landPastedLead(
        _ events: [ExtractedEvent], today: String, now: Date,
        landings: LandingSingleFlight = .shared,
        readProspectTable: @escaping ScoutLandingStore.SendableRead = ScoutService.readProspectTable,
        readProducerOverrides: @escaping ScoutService.OverrideRead = ScoutService.readProducerOverrides,
        loadExport: @escaping ExportLoad = { DownbeatBridge.loadWithHealth(now: Date()) },
        importedHistory: URL = LocalHistory.importedURL,
        saveEntry: (ModelContext) throws -> Void = { try $0.save() },
        saveSource: @escaping (ModelContext) throws -> Void = { try $0.save() },
        // #4536: the save that stamps the landing record landed, injected so a test can make it fail.
        saveClosing: (ModelContext) throws -> Void = { try $0.save() },
        into context: ModelContext
    ) async -> Result {
        // #4536: how many of the two entry flushes saved pending edits, for the landing record, as runScout and
        // the ingest count theirs (#4338).
        var entryFlushSaves = 0
        let readPhaseFlush = ScoutService.flushBeforeLanding(context, save: saveEntry)
        if case .recentEditsUnsaved(let rows)? = readPhaseFlush.refusal {
            return .refused(LeadIntake.recentEditsUnsaved(rows))
        }
        if readPhaseFlush == .saved { entryFlushSaves += 1 }
        let read = await readOffTheMainThread(container: context.container, read: readProspectTable,
                                              readOverrides: readProducerOverrides, loadExport: loadExport,
                                              importedHistory: importedHistory)
        let pass = await ScoutClassify.offTheCallersActor(
            events: events, clients: read.clients, history: read.history, venueBrands: read.corpus.brands,
            sourceIds: [WatchedSource.manualId])

        let token: LandingSingleFlight.Token
        do {
            token = try await landings.begin(entryPoint: .leadPaste, priority: .danAction,
                                             deadline: LandingSingleFlight.Deadline.leadPaste)
        } catch is CancellationError {
            return .refused(LeadIntake.stoppedWhileWaitingMessage)
        } catch {
            return .refused(String(describing: error))
        }
        defer { token.end() }
        // Again, now the store is held: whatever Dan edited while the paste read and waited is saved before
        // anything is applied, so a revert, which restores committed values, cannot put back an edit of his.
        let entryFlush = ScoutService.flushBeforeLanding(context, save: saveEntry)
        if case .recentEditsUnsaved(let rows)? = entryFlush.refusal {
            return .refused(LeadIntake.recentEditsUnsaved(rows))
        }
        if entryFlush == .saved { entryFlushSaves += 1 }
        let landing = ScoutLandingStore(context: context, read: readProspectTable, saveSource: saveSource)
        // #4536: the landing's record of itself, as #4335 gave runScout and the ingest, inserted at the start of
        // the landing block and carried by its save, so `scripts/landing-flush-rate.sh` counts the paste's entry
        // flushes and outcome with theirs. Its own identity, minted here, since a paste has no results file to
        // hash. Sequence 0: the paste stamps no source and keeps no journal, so it has no place in the order
        // landings are minted in, and a sequence would only raise the floor every other landing mints above.
        // A settled row, so a failed save of the shows does not take it with them.
        let run = LandingRun.begin(runIdentity: "paste-" + UUID().uuidString, sequence: 0, entryPoint: .leadPaste,
                                   startedAt: now, in: context)
        run.entryFlushSaves = entryFlushSaves
        landing.noteSettled(run)
        let outcome = ScoutService.apply(
            events: events, clients: read.clients, history: read.history,
            // #901: the SAME calendar the scout uses, days off included.
            blocked: ScoutService.blockedCalendar(export: (read.bookings, read.blockedDates, read.health),
                                                  context: context),
            today: today, now: now, sourceIds: [WatchedSource.manualId],
            preClassified: ScoutService.PreClassified(result: pass, degradedReads: read.corpus.degradedReads),
            landing: landing, into: context)
        if !outcome.saveFailed {
            // A paste that added nothing because the store could not say whether its shows were new is a failed
            // read, never "nothing new on that page" (L215, #4339 review).
            let unreadable = outcome.storeUnreadable > 0 && outcome.inserted + outcome.updated == 0
            // #4536: stamped landed only once the shows' save went through, in a closing save of its own, as the
            // ingest stamps its record (#4336). A closing save the store refuses puts the stamp back
            // (`saveLanding`), and the shows are landed all the same, so the answer does not change.
            if !unreadable { run.landedAt = now }
            _ = ScoutService.saveLanding(landing, into: context, save: saveClosing)
            if unreadable { return .refused(LeadIntake.storeUnreadableMessage) }
            return .landed(outcome)
        }
        // Put back, so nothing it wrote is left pending for a later save to carry (#4334's rule).
        switch ScoutService.isolateFailedSave(of: "the pasted page", scope: outcome.saveFailureScope,
                                              landing: landing) {
        case .notReverted?:
            // #4334's rule: a landing that could not put everything back makes no further save. Its record never
            // reached the store, so it is withdrawn rather than left for the next save to carry, which would be
            // the next paste's entry flush naming it among Dan's unsaved edits. This paste's flushes then go
            // uncounted, as a landing refused before its record was written goes uncounted.
            if context.insertedModelsArray.contains(where: { $0.persistentModelID == run.persistentModelID }) {
                _ = LandingRevert.revert(LandingRevert.WriteSet(changed: [], inserted: [run], deleted: []),
                                         in: context)
            }
            return .refused(LeadIntake.notRevertedMessage)
        default:
            // The record, unlanded, in a save of its own, as the ingest saves what a stopped landing left: the
            // paste is on the record as a landing that started and did not land.
            _ = ScoutService.saveLanding(landing, into: context, save: saveClosing)
            return .refused(LeadIntake.saveFailedMessage)
        }
    }

    // The show table is read ONCE, for both the corpus and the history, through a context that never saves,
    // so nothing it fetched crosses back. `Task.detached`, never a plain `Task`, which would inherit the main
    // actor (the reason `ScoutClassify.offTheCallersActor` gives).
    nonisolated private static func readOffTheMainThread(
        container: ModelContainer, read: @escaping ScoutLandingStore.SendableRead,
        readOverrides: @escaping ScoutService.OverrideRead, loadExport: @escaping ExportLoad,
        importedHistory: URL
    ) async -> ReadPhase {
        await Task.detached(priority: .userInitiated) {
            let export = loadExport()
            let context = ModelContext(container)
            let rows: Swift.Result<[Prospect], Error>
            do { rows = .success(try read(context)) } catch { rows = .failure(error) }
            let corpus = ScoutService.buildBrandCorpus(shows: { try rows.get() },
                                                       overrides: { try readOverrides(context) })
            // A table that could not be read is recorded under its own name, and the history is the imported
            // record alone: thinner, never an invented empty store (L215).
            var degraded = corpus.degradedReads
            let existing: [Prospect]
            switch rows {
            case .success(let read): existing = read
            case .failure:
                existing = []
                degraded.append(.repeatClientHistory)
            }
            let history = LocalHistory.forMatching(existing: existing, importedFrom: importedHistory)
            return ReadPhase(clients: export.clients, bookings: export.bookings, blockedDates: export.blockedDates,
                             health: export.health, history: history, corpus: (corpus.brands, degraded))
        }.value
    }
}
