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
    func resultsURL(_ hash: String) -> URL { folder(hash).appendingPathComponent(Self.resultsName) }
    private func entryURL(_ hash: String) -> URL { folder(hash).appendingPathComponent(Self.entryName) }

    // L617: written WHOLE or not at all. Both files go into a temporary folder (`.incoming-<uuid>`) that is
    // then renamed into place in one step, so a crash can never leave a folder holding the results and no
    // entry. A temporary folder a crash left behind is recovered by `list()` rather than stranded.
    // Re-recording the same bytes keeps the EARLIER entry (the older sequence), because it is the same run.
    @discardableResult
    func record(_ data: Data, sequence: Int, now: Date) throws -> Entry {
        let hash = Self.contentHash(of: data)
        if let existing = try? entry(hash) { return existing }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let incoming = directory.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: incoming) }   // gone already once it has been moved into place
        try data.write(to: incoming.appendingPathComponent(Self.resultsName), options: .atomic)
        try Self.encoded(Entry(contentHash: hash, sequence: sequence, recordedAt: now))
            .write(to: incoming.appendingPathComponent(Self.entryName), options: .atomic)
        try moveIntoPlace(incoming, hash: hash)
        return try entry(hash)
    }

    private static let resultsName = "results.json"
    private static let entryName = "entry.json"

    private static func encoded(_ entry: Entry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(entry)
    }

    // A folder already at the destination holds no readable entry (`record` returns early when it does),
    // so it is the leftover of a crash and the finished copy replaces it.
    private func moveIntoPlace(_ incoming: URL, hash: String) throws {
        let fm = FileManager.default
        let destination = folder(hash)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: incoming, to: destination)
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
        // L617: first, anything a crash left half done. Recovery can fail too, and then the folder is
        // reported by name below rather than skipped.
        var stranded: [Listed] = []
        for name in try fm.contentsOfDirectory(atPath: directory.path) where name.hasPrefix(".incoming-") {
            if let failed = recoverIncoming(directory.appendingPathComponent(name, isDirectory: true)) {
                stranded.append(failed)
            }
        }
        let names = try fm.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted()
        let listed: [Listed] = names.map { name in
            if let found = try? entry(name) { return .entry(found) }
            do { return .entry(try recoverEntry(name)) } catch {
                return .unreadable(path: folder(name).path, why: String(describing: error))
            }
        }
        return (listed + stranded).sorted { a, b in
            switch (a, b) {
            case (.entry(let x), .entry(let y)): return x.recordedAt < y.recordedAt
            case (.unreadable, .entry): return false
            case (.entry, .unreadable): return true
            case (.unreadable(let x, _), .unreadable(let y, _)): return x < y
            }
        }
    }

    // A temporary folder a crash left before it was moved into place. With its results in it, it is moved
    // into place (its entry recovered below if it never got one); with none, there is nothing to lose.
    // L10: a move that FAILS is returned as unreadable, by path, so it is reported the way any other
    // folder that cannot be read is, rather than retried unseen on every sweep.
    private func recoverIncoming(_ incoming: URL) -> Listed? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: incoming.appendingPathComponent(Self.resultsName)) else {
            try? fm.removeItem(at: incoming)
            return nil
        }
        let hash = Self.contentHash(of: data)
        if (try? entry(hash)) != nil {
            try? fm.removeItem(at: incoming)
            return nil
        }
        do {
            try moveIntoPlace(incoming, hash: hash)
            return nil
        } catch {
            return .unreadable(path: incoming.path, why: String(describing: error))
        }
    }

    // A folder with its results and no readable entry. The run's sequence was never recorded, so it is
    // recovered as the OLDEST reading there can be (sequence 0): the re-validation then sets it aside for
    // any source a run has landed since, and it can never land over newer data. Its time is the results
    // file's own. The folder's name must be the hash of the bytes in it, or it is not recovered.
    private func recoverEntry(_ hash: String) throws -> Entry {
        let data = try Data(contentsOf: resultsURL(hash))
        guard Self.contentHash(of: data) == hash else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: resultsURL(hash).path])
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: resultsURL(hash).path))?[.modificationDate]
        let recovered = Entry(contentHash: hash, sequence: 0, recordedAt: (modified as? Date) ?? Date())
        try Self.encoded(recovered).write(to: entryURL(hash), options: .atomic)
        return try entry(hash)
    }

    // The floor a new landing sequence is minted above. A pending entry from a session that has ended can
    // hold a number the store never saw (it never landed), and a new run minted at or below it would be
    // judged OLDER than a copy it actually postdates.
    //
    // READ ONLY, and deliberately not `list()`: this runs on every sequence mint, and `list()` recovers
    // (it moves folders and writes entries). Only the entries are read, in every folder including a
    // temporary one a crash left, whose entry already holds the sequence it would be moved in with. A
    // results-only folder carries no sequence and is recovered as 0, so it adds nothing to the floor. A
    // folder that cannot be read is skipped here; `list()`, on the sweep, is what reports it by name.
    var highestSequence: Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.reduce(0) { top, name in
            let url = directory.appendingPathComponent(name).appendingPathComponent(Self.entryName)
            guard let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(Entry.self, from: data) else { return top }
            return max(top, entry.sequence)
        }
    }
}
