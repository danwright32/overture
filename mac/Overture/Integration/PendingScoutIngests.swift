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
    // #2879: where an entry the sequence floor cannot read is reported, so it reaches the masthead rather
    // than being skipped in silence. Tests hand in their own.
    var readFailures: HandoffReadFailures = .shared

    static let folderName = "scout-extract-pending"

    static var live: PendingScoutIngests {
        PendingScoutIngests(directory: StoreLocation.handoffDirectory
            .appendingPathComponent(folderName, isDirectory: true))
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
        // An entry that is there and cannot be read is NOT absent (L215): written over, it would lose the
        // sequence the run was kept with, so the copy refuses instead and the landing stops before applying.
        // And a record whose results file is gone or is not these bytes is no copy at all (L421): it is written
        // again, under the sequence it was kept with, so the run stays the same run.
        let existing = try existingEntry(hash)
        if let existing, resultsAreThese(existing) { return existing }
        let sequence = existing?.sequence ?? sequence
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let incoming = directory.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: incoming) }   // gone already once it has been moved into place
        try data.write(to: incoming.appendingPathComponent(Self.resultsName), options: .atomic)
        try Self.encoded(Entry(contentHash: hash, sequence: sequence, recordedAt: existing?.recordedAt ?? now))
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

    // nil only when no entry was ever written there; an entry that is there and cannot be read THROWS,
    // naming its path, so no caller can read a damaged record as a missing one.
    func existingEntry(_ hash: String) throws -> Entry? {
        let url = entryURL(hash)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try entry(hash)
        } catch {
            throw UnreadableEntry(path: url.path, why: String(describing: error))
        }
    }

    // Whether a kept copy's results file is there and holds exactly the bytes its record names.
    // Through the shared reader, so a results file that is there and cannot be read is recorded as such
    // (#2879) rather than read as absent; either way it is no copy, and the copy step writes it again.
    func resultsAreThese(_ entry: Entry) -> Bool {
        switch HandoffFile.data(at: resultsURL(entry.contentHash), recorder: readFailures) {
        case .read(let data): return Self.contentHash(of: data) == entry.contentHash
        case .absent, .unreadable: return false
        }
    }

    struct UnreadableEntry: Error, CustomStringConvertible {
        let path: String
        let why: String
        var description: String { "the record of the copy already kept at \(path) could not be read: \(why)" }
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
            // Recovered only when its entry was never WRITTEN; one that is there and cannot be read is
            // reported by path and left, never rewritten as sequence 0 (which forgets which run it was).
            do {
                if let found = try existingEntry(name) { return .entry(found) }
            } catch let unreadable as UnreadableEntry {
                return .unreadable(path: unreadable.path, why: unreadable.why)
            } catch {
                return .unreadable(path: entryURL(name).path, why: String(describing: error))
            }
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
        // #2879: through the shared reader, which tells a results file that is not there (nothing to lose,
        // so the folder goes) from one that is there and cannot be read (reported by path, left in place).
        // Reported by `list()` itself, so not also recorded for the masthead.
        let resultsFile = incoming.appendingPathComponent(Self.resultsName)
        let data: Data
        switch HandoffFile.data(at: resultsFile, recorder: .reportedByItsOwnSurface) {
        case .absent:
            try? fm.removeItem(at: incoming)
            return nil
        case .unreadable(let reason):
            return .unreadable(path: resultsFile.path, why: reason)
        case .read(let read):
            data = read
        }
        let hash = Self.contentHash(of: data)
        do {
            if try existingEntry(hash) != nil {
                try? fm.removeItem(at: incoming)
                return nil
            }
        } catch {
            // A copy of these bytes is in place with a record nobody can read: moving this one over it would
            // remove it, so both are left and the damaged one is reported.
            return .unreadable(path: entryURL(hash).path, why: String(describing: error))
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
    // results-only folder carries no sequence and is recovered as 0, so it adds nothing to the floor (an
    // ABSENT entry is not a failure). An entry that is there and cannot be read is REPORTED to `readFailures`
    // by its own path (#2879), and cleared once it reads again; it adds nothing to the floor meanwhile.
    var highestSequence: Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return 0 }
        let listing = Self.folderName + "/"
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: directory.path)
            readFailures.clear(file: listing)
        } catch {
            readFailures.record(file: listing, reason: HandoffDecodeFailure.describe(error))
            return 0
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.reduce(0) { top, name in
            let url = directory.appendingPathComponent(name).appendingPathComponent(Self.entryName)
            let label = "\(Self.folderName)/\(name)/\(Self.entryName)"
            switch HandoffFile.read(at: url, recorder: .reportedByItsOwnSurface,
                                    decode: { try decoder.decode(Entry.self, from: $0) }) {
            case .absent:
                return top
            case .unreadable(let reason):
                readFailures.record(file: label, reason: reason)
                return top
            case .read(let entry):
                readFailures.clear(file: label)
                return max(top, entry.sequence)
            }
        }
    }
}
