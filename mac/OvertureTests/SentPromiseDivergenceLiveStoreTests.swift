import Testing
import Foundation
import SwiftData

// #3959: how many SENT rows name, in the words that went, nights the store can no longer reproduce.
//
// OPT IN, because it is a measurement and not a guard: it reports a count and asserts nothing about its
// size. The guard for the class is `Recipient.promisedNights`, frozen at send from this same extraction,
// so every row sent after it shipped carries what its email promised however the feed moves afterwards.
// This measures the rows that went BEFORE it, which answer 6 (2026-09-17) says record nothing.
//
// Through the SHIPPED predicates, never SQL beside the app (L107): the stored nights come from
// `Prospect.playingNights`, the named ones from `EventDateInDraft.namedDays` over the frozen sent subject
// and body. Reads a clone under `RealStoreTestLock` and writes nothing to the store.
//
// Run it with:
//   TEST_RUNNER_OVERTURE_MEASURE_PROMISES=<an output file> \
//     mac/scripts/run-tests-locked.sh -only-testing:OvertureTests/SentPromiseDivergenceLiveStoreTests
// The report names rows by primary key only; this repository is public (L482).
@Suite("Sent rows whose email names nights the store no longer holds (#3959, opt in)")
struct SentPromiseDivergenceLiveStoreTests {

    static var outputPath: String? {
        guard let path = ProcessInfo.processInfo.environment["OVERTURE_MEASURE_PROMISES"], !path.isEmpty
        else { return nil }
        return path
    }

    static var enabled: Bool {
        outputPath != nil && FileManager.default.fileExists(
            atPath: StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false).path)
    }

    // The primary key out of a SwiftData identifier, whose description ends ".../Prospect/p433".
    static func pk(_ p: Prospect) -> String {
        let text = "\(p.persistentModelID)"
        guard let range = text.range(of: #"/p\d+"#, options: [.regularExpression, .backwards]) else { return "?" }
        return String(text[range].dropFirst(2))
    }

    struct Tally {
        var sent = 0, multiNight = 0, noBody = 0, noAnchor = 0, agree = 0
        var namesANightNotStored: [String] = []
        var storedNightNotNamed: [String] = []
        var namesNothing: [String] = []
        // Per disagreeing row: which dates the body names beyond the store, and which stored nights it
        // does not name. Dates only, never the text around them.
        var detail: [String] = []
    }

    static func measure(_ rows: [Prospect]) -> Tally {
        var t = Tally()
        for p in rows where p.sentAt != nil {
            t.sent += 1
            let stored: Set<String>
            switch p.playingNights {
            case .recorded(let nights): stored = Set(nights)
            case .spanOnly(let opening, let last): stored = Set(EasternDate.days(from: opening, through: last))
            case .undated: stored = []
            }
            if stored.count > 1 { t.multiNight += 1 }
            guard let body = p.sentBody else { t.noBody += 1; continue }
            guard let anchor = p.performanceDate, EasternDate.date(from: anchor) != nil else {
                t.noAnchor += 1; continue
            }
            let named = Set(EventDateInDraft.namedDays(in: [p.sentSubject, body].compactMap { $0 }
                                                           .joined(separator: "\n"),
                                                       assumingYearOf: anchor).map(\.day))
            if named.isEmpty { t.namesNothing.append(pk(p)); continue }
            let extra = named.subtracting(stored)
            let missing = stored.subtracting(named)
            if extra.isEmpty && missing.isEmpty { t.agree += 1 }
            if !extra.isEmpty { t.namesANightNotStored.append(pk(p)) }
            if !missing.isEmpty { t.storedNightNotNamed.append(pk(p)) }
            if !extra.isEmpty || !missing.isEmpty {
                t.detail.append("pk \(pk(p)): named not stored \(extra.sorted()), stored not named \(missing.sorted()), stored \(stored.count) nights")
            }
        }
        return t
    }

    @Test(.enabled(if: enabled, "opt in: set TEST_RUNNER_OVERTURE_MEASURE_PROMISES and have a live store"))
    func measureTheSentRows() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("promise-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: dir) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let url = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let schema = Schema([Prospect.self, Recipient.self])
            let context = ModelContext(try ModelContainer(
                for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]))
            let rows = try context.fetch(FetchDescriptor<Prospect>())
            let t = Self.measure(rows)
            let report = """
            store rows: \(rows.count)
            sent rows: \(t.sent) (\(t.multiNight) of them multi-night by their stored nights)
            no frozen sent body: \(t.noBody)
            no show date to anchor a year: \(t.noAnchor)
            body names no date at all: \(t.namesNothing.count) pks \(t.namesNothing.sorted().joined(separator: ","))
            stored nights and named nights agree exactly: \(t.agree)
            body names a night the store does not hold: \(t.namesANightNotStored.count) pks \(t.namesANightNotStored.sorted().joined(separator: ","))
            store holds a night the body does not name: \(t.storedNightNotNamed.count) pks \(t.storedNightNotNamed.sorted().joined(separator: ","))
            \(t.detail.sorted().joined(separator: "\n"))
            """
            try report.write(toFile: Self.outputPath!, atomically: true, encoding: .utf8)
            // A measurement that measured nothing must not read as a clean one (L98).
            #expect(t.sent > 0, "the clone held no sent rows, so this measured nothing")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
