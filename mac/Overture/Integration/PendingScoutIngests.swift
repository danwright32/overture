import Foundation
import CryptoKit

// #4330 (A13, the L665 correction): the calendar results an ingest was holding when it had to wait for the
// store, kept by content hash so a refusal loses nothing.
//
// Before an ingest waits in `LandingSingleFlight.begin`, the exact bytes it decoded are copied into a folder
// named by their SHA-256 and an entry beside them records the run's landing sequence. The reader's own
// results file (`ScoutExtractResultsDecoder.defaultURL`) is NOT what is kept, because the next extract run
// rewrites it: an ingest refused at its deadline and later offered again from that path would land the
// NEXT run's results under this run's sequence and lose its own. So a pending entry is offered only ever
// from its own copy (`ScoutExtractLanding.offerPending`), at launch and at the end of every landing, and
// removed once it has landed.
//
// Same directory as the other handoff files, so under test it is redirected the same way
// (`StoreLocation.writableHandoffDirectory`).
struct PendingScoutIngests {
    let directory: URL

    static var live: PendingScoutIngests {
        PendingScoutIngests(directory: StoreLocation.handoffDirectory
            .appendingPathComponent("scout-extract-pending", isDirectory: true))
    }

    struct Entry: Codable, Equatable, Sendable {
        var contentHash: String
        // The landing sequence minted when this run's read phase started. Kept so the re-offer is judged
        // against the sources' `lastTouchedSequence` as the run it really is, never as a fresh one: a
        // re-offered copy stamped with a new number would land over a later run's reading of the same page.
        var sequence: Int
        var recordedAt: Date
    }

    // One entry the folder holds, or the reason it could not be read. An unreadable entry is reported by
    // path rather than skipped: a skipped one is a pending result nobody ever hears of again (L98).
    enum Listed: Equatable {
        case entry(Entry)
        case unreadable(path: String, why: String)
    }

    static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func folder(_ hash: String) -> URL { directory.appendingPathComponent(hash, isDirectory: true) }
    func resultsURL(_ hash: String) -> URL { folder(hash).appendingPathComponent("results.json") }
    private func entryURL(_ hash: String) -> URL { folder(hash).appendingPathComponent("entry.json") }

    // Writes the copy first and the entry second, so an entry never exists without the bytes it names.
    // Re-recording the same bytes keeps the EARLIER entry (the older sequence), because it is the same run.
    @discardableResult
    func record(_ data: Data, sequence: Int, now: Date) throws -> Entry {
        let hash = Self.contentHash(of: data)
        let fm = FileManager.default
        try fm.createDirectory(at: folder(hash), withIntermediateDirectories: true)
        if let existing = try? entry(hash) { return existing }
        try data.write(to: resultsURL(hash), options: .atomic)
        let entry = Entry(contentHash: hash, sequence: sequence, recordedAt: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: entryURL(hash), options: .atomic)
        return entry
    }

    func entry(_ hash: String) throws -> Entry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Entry.self, from: Data(contentsOf: entryURL(hash)))
    }

    func results(_ entry: Entry) throws -> (data: Data, results: ScoutExtractResults) {
        let data = try Data(contentsOf: resultsURL(entry.contentHash))
        return (data, try ScoutExtractResultsDecoder.decode(data))
    }

    func remove(_ hash: String) throws {
        let url = folder(hash)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // Every pending entry, oldest first. An absent folder is an empty list; an unlistable one throws, so a
    // failed listing never reads as nothing pending.
    func list() throws -> [Listed] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let names = try fm.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
        let listed: [Listed] = names.map { name in
            do { return .entry(try entry(name)) } catch {
                return .unreadable(path: entryURL(name).path, why: String(describing: error))
            }
        }
        return listed.sorted { a, b in
            switch (a, b) {
            case (.entry(let x), .entry(let y)): return x.recordedAt < y.recordedAt
            case (.unreadable, .entry): return false
            case (.entry, .unreadable): return true
            case (.unreadable(let x, _), .unreadable(let y, _)): return x < y
            }
        }
    }

    // The floor a new landing sequence is minted above. A pending entry from a session that has ended can
    // hold a number the store never saw (it never landed), and a new run minted at or below it would be
    // judged OLDER than a copy it actually postdates. A folder that cannot be listed leaves the floor to the
    // store and this process's own mints; the same failure is what `ScoutExtractLanding.offerPending`
    // reports by name, so it does not pass in silence.
    var highestSequence: Int {
        ((try? list()) ?? []).reduce(0) { top, listed in
            if case .entry(let e) = listed { return max(top, e.sequence) }
            return top
        }
    }
}
