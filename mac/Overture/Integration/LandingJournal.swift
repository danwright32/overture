import Foundation

// #4335 (A6, the first part): the record of what a scout landing set out to do, kept OUTSIDE the store.
//
// A landing writes the store one source at a time, each with its own save. A crash (or a SQLite trigger
// that ends the process, which #4327 step 0.8 measured: no catch runs) between two of those saves leaves
// the store holding some sources and not others, and nothing in the store says a landing was under way.
// So each landing writes its INTENT here before it applies anything, and removes it once it has landed.
// A journal that is still here after the landing that wrote it has gone is an interrupted landing.
//
// What a journal records is intent only (L5): which run, its landing sequence, the entry point, the
// sources in the order the landing meant to land them with each page's hash as it stood at landing start,
// and the landing's original `now` (L37). Which of those sources actually landed is NOT here: it is in the
// store, atomic with the data (`WatchedSource.lastLandedRunID` and `lastLandedSequence`, written in the same
// save as that source's rows), so the journal and the store can never disagree about it.
//
// ONE FILE PER RUN (L393), named `<sequence>-<run identity>.json` with the sequence zero padded, so the
// sequence floor reads the NAMES and never has to decode a file (an unreadable journal still says which
// sequence it held). Written whole or not at all: a temporary file, fsynced, renamed into place, and the
// folder fsynced, so a crash leaves either the previous state or the finished journal (L617).
//
// The folder is a PARAMETER of every landing (`LandingJournals`), resolved to the Application Support
// handoff folder once, at the product call sites, which `EveryProductLandingKeepsAJournalTests` holds to.
// Every test passes its own sandbox (L433, L463).
struct LandingJournal: Codable, Equatable, Sendable {
    // Bumped whenever the shape changes. Each version is decoded by the version it was written under
    // (`LandingJournals.decode`), with a committed fixture per past version under test.
    static let currentVersion = 1

    struct Source: Codable, Equatable, Sendable {
        var sourceId: String
        // The page's hash as it stood when the landing started: for the ingest the `pendingContentHash`
        // the results were read from, for runScout the hash a natively read page will be marked read as.
        // nil for a source whose landing promotes no hash (a native feed, a failed or unchanged check).
        var pageHash: String?
    }

    var version: Int
    // The run identity (L186): the ingest's results file content hash, runScout's sweep id.
    var runIdentity: String
    var sequence: Int
    // `LandingSingleFlight.EntryPoint`'s raw value.
    var entryPoint: String
    var sources: [Source]
    // The landing's own `now`, so a recovery of an ingest stamps what the content really was read at.
    var now: Date

    init(runIdentity: String, sequence: Int, entryPoint: LandingSingleFlight.EntryPoint,
         sources: [Source], now: Date) {
        self.version = Self.currentVersion
        self.runIdentity = runIdentity
        self.sequence = sequence
        self.entryPoint = entryPoint.rawValue
        self.sources = sources
        self.now = now
    }
}

// The folder of landing journals, and everything that reads or writes it.
struct LandingJournals: Sendable {
    let directory: URL
    // Where a journal that cannot be read, a folder that cannot be listed, and a journal that could not be
    // removed are reported, so each reaches the masthead rather than passing in silence (#2879). Tests hand
    // in their own.
    var readFailures: HandoffReadFailures = .shared

    static let folderName = "landing-journals"
    // The suffix an unreadable journal is renamed to. Its sequence stays readable from the name.
    static let quarantineSuffix = ".unreadable"
    private static let journalSuffix = ".json"

    // The product folder. Named at the product call sites only.
    static var live: LandingJournals {
        LandingJournals(directory: StoreLocation.handoffDirectory
            .appendingPathComponent(folderName, isDirectory: true))
    }

    // `<sequence>-<run identity>.json`, the sequence zero padded to ten digits so the names sort in landing
    // order. The identity is reduced to characters a file name can always carry.
    static func fileName(sequence: Int, runIdentity: String) -> String {
        let safe = String(runIdentity.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_"
        })
        return String(format: "%010d", sequence) + "-" + safe + journalSuffix
    }

    // The sequence a journal's name carries, whether it is pending or quarantined. nil for a name that is
    // not a journal's.
    static func sequence(inName name: String) -> Int? {
        guard !name.hasPrefix("."),
              name.hasSuffix(journalSuffix) || name.hasSuffix(journalSuffix + quarantineSuffix),
              let dash = name.firstIndex(of: "-") else { return nil }
        return Int(name[..<dash])
    }

    func url(for journal: LandingJournal) -> URL {
        directory.appendingPathComponent(Self.fileName(sequence: journal.sequence, runIdentity: journal.runIdentity))
    }

    // The landing's start write. A failure THROWS, and the landing refuses by name before it applies
    // anything (L258): a landing that cannot record its intent is one a crash would leave unrecoverable.
    // Re-writing the journal of the same run (a kept copy offered again) replaces it.
    @discardableResult
    func start(_ journal: LandingJournal) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = url(for: journal)
        let temporary = directory.appendingPathComponent(".incoming-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }   // gone already once it has been renamed into place
        try Self.encoded(journal).write(to: temporary)
        try Self.fsync(temporary)
        // rename(2), which replaces an existing journal of the same name in one step.
        guard rename(temporary.path, destination.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: destination.path,
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))])
        }
        try Self.fsync(directory)
        return destination
    }

    // The landing's end: its sources are in the store, so the intent is spent. Removing it is what tells a
    // later launch there is nothing to recover. A removal that fails is reported by name and leaves the
    // journal where it is; its sources all carry this run's sequence, so the recovery (#4335) finds nothing
    // to replay in it and retires it then.
    func retire(_ journal: LandingJournal) {
        let target = url(for: journal)
        let label = Self.folderName + "/" + target.lastPathComponent
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try Self.fsync(directory)
            readFailures.clear(file: label)
        } catch {
            readFailures.record(file: label, reason: "could not be removed after its landing finished: "
                                + HandoffDecodeFailure.describe(error))
        }
    }

    // The floor a new landing sequence is minted above: the highest sequence any journal's NAME carries,
    // pending or quarantined. READ ONLY and decoding nothing, because it runs on every mint, and because an
    // unreadable journal must never stop a landing (L371): its name still says which sequence it held. A
    // folder that cannot be listed is reported and adds nothing (the start write into it then fails too, and
    // that landing is refused by name).
    var highestSequence: Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return 0 }
        let listing = Self.folderName + "/"
        do {
            let names = try fm.contentsOfDirectory(atPath: directory.path)
            readFailures.clear(file: listing)
            return names.compactMap(Self.sequence(inName:)).max() ?? 0
        } catch {
            readFailures.record(file: listing, reason: HandoffDecodeFailure.describe(error))
            return 0
        }
    }

    // One journal the folder holds, or one that could not be read.
    enum Listed: Equatable {
        case pending(LandingJournal, url: URL)
        // Renamed to `<name>.unreadable` (or already was), never treated as absent (L215) and never allowed
        // to block another landing (L371). `sequence` is read from its name.
        case quarantined(path: String, sequence: Int?, why: String)
    }

    // Every journal, in landing order. A journal that cannot be read is QUARANTINED here, renamed so its
    // sequence stays readable from the name, and reported by path. Reading this is the recovery's first step
    // (#4335); a quarantined journal is what it offers to try again or discard.
    func list() throws -> [Listed] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let names = try fm.contentsOfDirectory(atPath: directory.path)
            .filter { Self.sequence(inName: $0) != nil }
            .sorted()
        return names.map { name in
            let url = directory.appendingPathComponent(name)
            let label = Self.folderName + "/" + name
            if name.hasSuffix(Self.quarantineSuffix) {
                return .quarantined(path: url.path, sequence: Self.sequence(inName: name),
                                    why: "it was set aside as unreadable earlier")
            }
            do {
                let journal = try Self.decode(Data(contentsOf: url))
                readFailures.clear(file: label)
                return .pending(journal, url: url)
            } catch {
                let why = HandoffDecodeFailure.describe(error)
                let quarantined = url.appendingPathExtension(String(Self.quarantineSuffix.dropFirst()))
                let path = (try? fm.moveItem(at: url, to: quarantined)) != nil ? quarantined.path : url.path
                readFailures.record(file: label, reason: "could not read the landing record at \(path): \(why)")
                return .quarantined(path: path, sequence: Self.sequence(inName: name), why: why)
            }
        }
    }

    // Decodes a journal by the version it was written under. A version this build does not know is refused
    // by name rather than read as the current one.
    static func decode(_ data: Data) throws -> LandingJournal {
        struct Header: Decodable { var version: Int }
        let decoder = JSONDecoder()
        // The default strategy, seconds since the reference date as a Double: exact, so a recovered ingest
        // stamps the very `now` the landing had, which ISO 8601 would round to the second.
        decoder.dateDecodingStrategy = .deferredToDate
        let version = try decoder.decode(Header.self, from: data).version
        switch version {
        case 1:
            return try decoder.decode(LandingJournal.self, from: data)
        default:
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "landing record version \(version) is not one this build reads"])
        }
    }

    static func encoded(_ journal: LandingJournal) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(journal)
    }

    // fsync(2) on a file or a folder, so the rename above is durable rather than sitting in the cache.
    private static func fsync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { close(fd) }
        guard Darwin.fsync(fd) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
