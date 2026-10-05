import Foundation
import SwiftData

// #4339 (A11): the inputs a calendar results landing reads before it lands, lifted out of RootView so the
// product and the first hold probe (`LandingFirstHoldProbeTests`) call the same code, and the first hold is
// measured as the product holds it.
//
// What a landing reads besides the store's own rows: Downbeat's export (a file: clients, bookings and blocked
// days), the history the matcher sees (the show table plus the imported booking history, a file), and the
// blocked calendar built from the export and the store's own day records.
//
// MEASURED, 2026-10-04, each member alone on the main thread of a live store clone (1,372 shows, and 5,500 at 4x;
// `LandingFirstHoldProbeTests`, median of three): the results file read and decode 1.2 ms (4.6 at 4x), Downbeat's
// export 0.3 ms, the blocked calendar 1.3 ms, the whole show table read 204.5 ms (812.8 at 4x), and the history
// built from those rows and the imported file 40.0 ms (203.1 at 4x). So the two show table members leave the
// main thread, through `history(...)` below, and the three under 10 ms stay where they are.
@MainActor
enum LandingInputs {
    struct Inputs {
        let clients: [DownbeatClient]
        let history: [HistoryRecord]
        let blocked: BlockedCalendar
        // A show table that could not be read, so the history is the imported record alone. Recorded on the
        // outcome by the caller rather than read as an empty store (L215); it used to be `(try? fetch) ?? []`.
        let degradedReads: [ScoutService.StoreRead]
    }

    // The results file, read and decoded, with its bytes kept beside it so an ingest that has to wait for the
    // store can copy exactly what it decoded (`ScoutExtractLanding`). nil when the file is absent or refused,
    // which `HandoffFile.read` has already recorded against the file (#2879).
    static func readResultsFile(at url: URL = ScoutExtractResultsDecoder.defaultURL)
        -> (data: Data, results: ScoutExtractResults)? {
        guard let file = HandoffFile.read(at: url, decode: { ($0, try ScoutExtractResultsDecoder.decode($0)) }).value
        else { return nil }
        return (file.0, file.1)
    }

    // Everything else a landing reads before it lands.
    static func read(exportURL: URL = DownbeatBridge.defaultURL, historyURL: URL = LocalHistory.importedURL,
                     now: Date = Date(),
                     readProspectTable: @escaping ScoutLandingStore.SendableRead = ScoutService.readProspectTable,
                     into context: ModelContext) async -> Inputs {
        let loaded = DownbeatBridge.loadWithHealth(from: exportURL, now: now)
        let history = await history(importedFrom: historyURL, readProspectTable: readProspectTable, into: context)
        let records: [HistoryRecord]
        var degraded: [ScoutService.StoreRead] = []
        switch history {
        case .success(let read): records = read
        case .failure:
            degraded.append(.repeatClientHistory)
            records = LocalHistory.forMatching(existing: [], importedFrom: historyURL)
        }
        return Inputs(clients: loaded.clients, history: records,
                      blocked: ScoutService.blockedCalendar(export: (loaded.bookings, loaded.blockedDates, loaded.health),
                                                            context: context),
                      degradedReads: degraded)
    }

    // The show table could not be read, carried across the actor boundary as its description.
    struct ShowTableUnreadable: Error, CustomStringConvertible {
        let description: String
    }

    // The history the matcher sees: the show table, read ONCE, plus the imported booking history. OFF the main
    // thread through a context of its own, which reads only what is SAVED, so only while the main context holds
    // nothing pending. With an edit of Dan's pending, the read stays on the main thread exactly as before, where
    // the context sees it: this read phase SAVES NOTHING (`ScoutReadPhaseWriteScanTests`), so it never flushes
    // to make the background read possible; the landing's own entry flush, later, is the one that saves. The
    // failure of the table read is returned, never folded into an empty history: `runScout` refuses on it
    // (`StoreReadFailure`) and the ingest records it.
    static func history(importedFrom historyURL: URL = LocalHistory.importedURL,
                        readProspectTable: @escaping ScoutLandingStore.SendableRead = ScoutService.readProspectTable,
                        into context: ModelContext) async -> Swift.Result<[HistoryRecord], ShowTableUnreadable> {
        guard !context.hasChanges else {
            do {
                let rows = try readProspectTable(context)
                return .success(LocalHistory.forMatching(existing: rows, importedFrom: historyURL))
            } catch {
                return .failure(ShowTableUnreadable(description: String(describing: error)))
            }
        }
        return await historyOffMain(container: context.container, read: readProspectTable, historyURL: historyURL)
    }

    // `Task.detached`, never a plain `Task`, which would inherit the main actor (the reason
    // `ScoutClassify.offTheCallersActor` gives). The context never saves, so nothing it fetched crosses back:
    // only `HistoryRecord` values do.
    nonisolated private static func historyOffMain(container: ModelContainer,
                                                   read: @escaping ScoutLandingStore.SendableRead,
                                                   historyURL: URL) async -> Swift.Result<[HistoryRecord], ShowTableUnreadable> {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            do {
                // The context is handed to the injected read alone, on a line of its own, so the guard that
                // follows a second context's hand-ons (`OnlyTheMainContextWritesGuardTests`) can see it only reads.
                let rows = try read(context)
                return .success(LocalHistory.forMatching(existing: rows, importedFrom: historyURL))
            } catch {
                return .failure(ShowTableUnreadable(description: String(describing: error)))
            }
        }.value
    }
}
