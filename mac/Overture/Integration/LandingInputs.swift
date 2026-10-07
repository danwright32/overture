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
// main thread, and the results file and the blocked calendar stay where they are.
//
// #4558: the ONE builder of these inputs for every landing: the calendar ingest and the kept copies offered
// again (`read`), the idle landing recovery (#4526) and `runScout` (`readRefusingUnreadableShowTable`), and the
// lead paste (`readWithBrandCorpus`). The scout run and the paste used to build them beside this, which let an
// entry point come to judge a show against a different history from the others (L370);
// `LandingInputsHaveOneBuilderTests` keeps a second builder from coming back. Downbeat's export is read off the
// main thread with the table, as the paste's own read phase read it (#4493), by every one of them now: the others
// read it on the main thread only because 0.3 ms was not worth moving on its own (#4500), and one read phase
// for all four is.
@MainActor
enum LandingInputs {
    struct Inputs {
        let clients: [DownbeatClient]
        let history: [HistoryRecord]
        let blocked: BlockedCalendar
        // A show table that could not be read, so the history is the imported record alone. Recorded on the
        // outcome by the caller rather than read as an empty store (L215); it used to be `(try? fetch) ?? []`.
        let degradedReads: [ScoutService.StoreRead]
        // #4558: the rest of Downbeat's export, which `runScout` reads beside the three: its booking reconcile
        // reads the bookings, and the client list warning on its outcome the export's health.
        let bookings: [OvertureBooking]
        let exportHealth: DownbeatBridge.Health
    }

    typealias Export = (clients: [DownbeatClient], bookings: [OvertureBooking], blockedDates: [String],
                        health: DownbeatBridge.Health)
    // How Downbeat's export is read, from a file at a time. Injected only so a test can see which thread reads it.
    typealias ExportLoad = @Sendable (URL, Date) -> Export
    nonisolated static let loadExportFile: ExportLoad = { DownbeatBridge.loadWithHealth(from: $0, now: $1) }

    // The results file, read and decoded, with its bytes kept beside it so an ingest that has to wait for the
    // store can copy exactly what it decoded (`ScoutExtractLanding`). nil when the file is absent or refused,
    // which `HandoffFile.read` has already recorded against the file (#2879).
    static func readResultsFile(at url: URL = ScoutExtractResultsDecoder.defaultURL)
        -> (data: Data, results: ScoutExtractResults)? {
        guard let file = HandoffFile.read(at: url, decode: { ($0, try ScoutExtractResultsDecoder.decode($0)) }).value
        else { return nil }
        return (file.0, file.1)
    }

    // Everything else a landing reads before it lands. A show table that cannot be read lands against the
    // imported history alone, and says so in `degradedReads`.
    static func read(exportURL: URL = DownbeatBridge.defaultURL, historyURL: URL = LocalHistory.importedURL,
                     now: Date = Date(),
                     readProspectTable: @escaping ScoutLandingStore.SendableRead = ScoutService.readProspectTable,
                     loadExport: @escaping ExportLoad = LandingInputs.loadExportFile,
                     into context: ModelContext) async -> Inputs {
        let phase = await readPhase(Ask(exportURL: exportURL, historyURL: historyURL, now: now,
                                        readProspectTable: readProspectTable, loadExport: loadExport,
                                        readProducerOverrides: nil), into: context)
        return degrading(phase, into: context)
    }

    // #4526: the same read for the idle landing recovery, which REFUSES when the show table cannot be read rather
    // than landing against the imported history alone. A recovery replays a kept copy and retires it once it
    // lands, so a copy landed matched against a store it never saw could not be landed again (L215); refusing
    // keeps the copy for the next idle minute.
    // #4558: and for `runScout`, which has refused on it since #3071 (`StoreReadFailure`, `.repeatClientHistory`):
    // an empty answer there means a repeat client is not recognised as one, so a show Dan has already shot reads
    // as cold and gets pitched as a stranger. Refusing is the one deliberate difference from `read`.
    static func readRefusingUnreadableShowTable(
        exportURL: URL = DownbeatBridge.defaultURL, historyURL: URL = LocalHistory.importedURL, now: Date = Date(),
        readProspectTable: @escaping ScoutLandingStore.SendableRead = ScoutService.readProspectTable,
        loadExport: @escaping ExportLoad = LandingInputs.loadExportFile,
        into context: ModelContext) async -> Swift.Result<Inputs, ShowTableUnreadable> {
        let phase = await readPhase(Ask(exportURL: exportURL, historyURL: historyURL, now: now,
                                        readProspectTable: readProspectTable, loadExport: loadExport,
                                        readProducerOverrides: nil), into: context)
        switch phase.history {
        case .read(let history): return .success(assemble(phase.export, history: history, into: context))
        case .unreadable(let unreadable, _): return .failure(unreadable)
        }
    }

    // #4558: the lead paste's read, which degrades as `read` does, and whose ONE show table read also builds the
    // brand corpus its classify pass needs, with Dan's producer corrections (#4493: the paste reads the table once,
    // for both). The one deliberate difference from `read`. `runScout` reads its corpus apart, after its entry
    // flush and only on a run with a free source (#4332), and the ingest's comes with its classify pass, so
    // neither is built here.
    static func readWithBrandCorpus(
        exportURL: URL = DownbeatBridge.defaultURL, historyURL: URL = LocalHistory.importedURL, now: Date = Date(),
        readProspectTable: @escaping ScoutLandingStore.SendableRead = ScoutService.readProspectTable,
        readProducerOverrides: @escaping ScoutService.OverrideRead = ScoutService.readProducerOverrides,
        loadExport: @escaping ExportLoad = LandingInputs.loadExportFile,
        into context: ModelContext) async -> (inputs: Inputs, corpus: ScoutService.CorpusRead) {
        let phase = await readPhase(Ask(exportURL: exportURL, historyURL: historyURL, now: now,
                                        readProspectTable: readProspectTable, loadExport: loadExport,
                                        readProducerOverrides: readProducerOverrides), into: context)
        // Asked for, so always built; were it ever missing, it is said as both of its reads failing, never as a
        // corpus that read and held nothing (L215).
        return (degrading(phase, into: context),
                phase.corpus ?? (ProducerGate.VenueBrands.none, [.venueBrandCorpus, .producerOverrides]))
    }

    // The show table could not be read, carried across the actor boundary as its description.
    struct ShowTableUnreadable: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - the read phase, ONE for every landing

    // What a read phase is asked for. Values only, so it crosses to the background task whole.
    private struct Ask: Sendable {
        let exportURL: URL
        let historyURL: URL
        let now: Date
        let readProspectTable: ScoutLandingStore.SendableRead
        let loadExport: ExportLoad
        // Present only for the paste, whose corpus is built from the same table read.
        let readProducerOverrides: ScoutService.OverrideRead?
    }

    // What it brings back across the actor boundary: values only, never a fetched row.
    private struct Phase: Sendable {
        enum History: Sendable {
            case read([HistoryRecord])
            // The table could not be read; `importedAlone` is the history a degrading read lands against instead.
            case unreadable(ShowTableUnreadable, importedAlone: [HistoryRecord])
        }
        let export: Export
        let history: History
        let corpus: ScoutService.CorpusRead?
    }

    // The show table, read ONCE, with the imported booking history and Downbeat's export. OFF the main thread
    // through a context of its own, which reads only what is SAVED, so only while the main context holds nothing
    // pending. With an edit of Dan's pending, the read stays on the main thread exactly as before, where the
    // context sees it: this read phase SAVES NOTHING (`ScoutReadPhaseWriteScanTests`), so it never flushes to make
    // the background read possible; the landing's own entry flush, later, is the one that saves. The failure of
    // the table read is returned, never folded into an empty history: `runScout` refuses on it
    // (`StoreReadFailure`) and the ingest records it.
    private static func readPhase(_ ask: Ask, into context: ModelContext) async -> Phase {
        guard !context.hasChanges else { return readTable(ask, in: context) }
        return await readOffMain(ask, container: context.container)
    }

    // `Task.detached`, never a plain `Task`, which would inherit the main actor (the reason
    // `ScoutClassify.offTheCallersActor` gives). The context never saves, so nothing it fetched crosses back.
    nonisolated private static func readOffMain(_ ask: Ask, container: ModelContainer) async -> Phase {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            // The context is handed to `readTable` alone, on a line of its own, so the guard that follows a second
            // context's hand-ons (`OnlyTheMainContextWritesGuardTests`) can see it only reads.
            return readTable(ask, in: context)
        }.value
    }

    nonisolated private static func readTable(_ ask: Ask, in context: ModelContext) -> Phase {
        let export = ask.loadExport(ask.exportURL, ask.now)
        let rows: Swift.Result<[Prospect], Error>
        do { rows = .success(try ask.readProspectTable(context)) } catch { rows = .failure(error) }
        let history: Phase.History
        switch rows {
        case .success(let read):
            history = .read(LocalHistory.forMatching(existing: read, importedFrom: ask.historyURL))
        case .failure(let error):
            history = .unreadable(ShowTableUnreadable(description: String(describing: error)),
                                  importedAlone: LocalHistory.forMatching(existing: [], importedFrom: ask.historyURL))
        }
        let corpus = ask.readProducerOverrides.map { overrides in
            ScoutService.buildBrandCorpus(shows: { try rows.get() }, overrides: { try overrides(context) })
        }
        return Phase(export: export, history: history, corpus: corpus)
    }

    // A table that could not be read lands against the imported history alone, and says so.
    private static func degrading(_ phase: Phase, into context: ModelContext) -> Inputs {
        switch phase.history {
        case .read(let history):
            return assemble(phase.export, history: history, into: context)
        case .unreadable(_, let importedAlone):
            return assemble(phase.export, history: importedAlone, degradedReads: [.repeatClientHistory], into: context)
        }
    }

    // The blocked calendar, built on the main thread from the export and the store's own day records, beside a
    // history already read.
    private static func assemble(_ export: Export, history: [HistoryRecord],
                                 degradedReads: [ScoutService.StoreRead] = [], into context: ModelContext) -> Inputs {
        Inputs(clients: export.clients, history: history,
               blocked: ScoutService.blockedCalendar(export: (export.bookings, export.blockedDates, export.health),
                                                     context: context),
               degradedReads: degradedReads, bookings: export.bookings, exportHealth: export.health)
    }
}
