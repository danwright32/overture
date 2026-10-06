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
    // #4440 / #4335: version 2 adds where the ingest's results were copied (`resultsCopy`) and, per source, the
    // two values its feed report is judged against as they stood when the landing STARTED (`checksBefore`,
    // `baselineBefore`), so a landing offered again can rebuild the report of a source it already landed.
    static let currentVersion = 2

    struct Source: Codable, Equatable, Sendable {
        var sourceId: String
        // The page's hash as it stood when the landing started: for the ingest the `pendingContentHash`
        // the results were read from, for runScout the hash a natively read page will be marked read as.
        // nil for a source whose landing promotes no hash (a native feed, a failed or unchanged check).
        var pageHash: String?
        // Version 2. The source's `successfulCheckCount` and feed baseline when the landing started, the two
        // values its reconcile report carries. A landing offered again after it landed this source (whose
        // own save already moved both) rebuilds the report from these rather than from the moved values.
        // nil in a version 1 journal, and for a source that lands no shows (a settled slot).
        var checksBefore: Int?
        var baselineBefore: Int?

        init(sourceId: String, pageHash: String?, checksBefore: Int? = nil, baselineBefore: Int? = nil) {
            self.sourceId = sourceId
            self.pageHash = pageHash
            self.checksBefore = checksBefore
            self.baselineBefore = baselineBefore
        }
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
    // Version 2 (#4440): the content hash under which the ingest's results were copied into
    // `PendingScoutIngests` before anything was applied, so the results this journal describes can be landed
    // again from their own copy, never from the reader's file. nil for runScout (it has no results file), in a
    // version 1 journal, and for decoded results with no file behind them (a test's).
    var resultsCopy: String?

    init(runIdentity: String, sequence: Int, entryPoint: LandingSingleFlight.EntryPoint,
         sources: [Source], now: Date, resultsCopy: String? = nil) {
        self.version = Self.currentVersion
        self.runIdentity = runIdentity
        self.sequence = sequence
        self.entryPoint = entryPoint.rawValue
        self.sources = sources
        self.now = now
        self.resultsCopy = resultsCopy
    }

    // The shape version 1 was written in, decoded as itself and carried forward with nothing invented: the
    // fields it never had stay nil.
    fileprivate struct Version1: Decodable {
        struct Source: Decodable {
            var sourceId: String
            var pageHash: String?
        }
        var version: Int
        var runIdentity: String
        var sequence: Int
        var entryPoint: String
        var sources: [Source]
        var now: Date
    }

    fileprivate init(_ v1: Version1) {
        self.version = v1.version
        self.runIdentity = v1.runIdentity
        self.sequence = v1.sequence
        self.entryPoint = v1.entryPoint
        self.sources = v1.sources.map { Source(sourceId: $0.sourceId, pageHash: $0.pageHash) }
        self.now = v1.now
        self.resultsCopy = nil
    }

    // The source this journal recorded under an id, nil when it recorded none.
    func source(_ sourceId: String) -> Source? { sources.first { $0.sourceId == sourceId } }
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
        return String(format: "%010ld", sequence) + "-" + safe + journalSuffix
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

    // #4440: the pending journal an earlier attempt of the run with this sequence wrote, read before a landing
    // offered again replaces it, because it is the only record of what that run's sources stood at when it
    // first started (L37). Found by the sequence in its NAME, which is unique to a run. nil when there is none,
    // or when it cannot be read or decoded: the caller then knows less and lands less (it rebuilds no report
    // it cannot rebuild exactly), never more. A quarantined journal is not read here.
    func pending(sequence: Int) -> LandingJournal? {
        let prefix = String(format: "%010ld", sequence) + "-"
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            readFailures.record(file: Self.folderName + "/", reason: HandoffDecodeFailure.describe(error))
            return nil
        }
        for name in names.sorted() where name.hasPrefix(prefix) && name.hasSuffix(Self.journalSuffix) {
            // Through the shared reader, so a journal that is there and cannot be read is reported by path (to
            // the same failures `list()` reports to) rather than read as absent (L215, #2879).
            let url = directory.appendingPathComponent(name)
            switch HandoffFile.read(at: url, recorder: .reportedByItsOwnSurface, decode: { try Self.decode($0) }) {
            case .read(let journal) where journal.sequence == sequence:
                return journal
            case .unreadable(let reason):
                readFailures.record(file: Self.folderName + "/" + name,
                                    reason: "could not read the landing record at \(url.path): \(reason)")
            default:
                continue
            }
        }
        return nil
    }

    // One journal the folder holds, or one that could not be read.
    enum Listed: Equatable {
        case pending(LandingJournal, url: URL)
        // Renamed to `<name>.unreadable` (or already was), never treated as absent (L215) and never allowed
        // to block another landing (L371). `sequence` is read from its name.
        case quarantined(path: String, sequence: Int?, why: String)
        // A journal this build cannot read but which is not corrupt: written by a NEWER build (a version this
        // one does not know), or not readable right now (an I/O error such as permissions). Reported by path
        // and LEFT IN PLACE, so the build that can read it, or the next listing, still finds it (L255).
        case leftInPlace(path: String, sequence: Int?, why: String)
    }

    // A version this build does not read: a newer build's journal, not a damaged one.
    struct UnknownVersion: Error, CustomStringConvertible {
        let version: Int
        var description: String { "landing record version \(version) is not one this build reads" }
    }

    // Every journal, in landing order. A journal whose CONTENT is corrupt is QUARANTINED here, renamed so its
    // sequence stays readable from the name, and reported by path; one from a newer build, or one that could
    // not be read from disk, is reported and left where it is. Reading this is the recovery's first step
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
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                let why = HandoffDecodeFailure.describe(error)
                readFailures.record(file: label, reason: "could not read the landing record at \(url.path): \(why)")
                return .leftInPlace(path: url.path, sequence: Self.sequence(inName: name), why: why)
            }
            do {
                let journal = try Self.decode(data)
                readFailures.clear(file: label)
                return .pending(journal, url: url)
            } catch let newer as UnknownVersion {
                readFailures.record(file: label, reason: "could not read the landing record at \(url.path): \(newer)")
                return .leftInPlace(path: url.path, sequence: Self.sequence(inName: name), why: newer.description)
            } catch {
                let why = HandoffDecodeFailure.describe(error)
                let quarantined = url.appendingPathExtension(String(Self.quarantineSuffix.dropFirst()))
                let path = (try? fm.moveItem(at: url, to: quarantined)) != nil ? quarantined.path : url.path
                // #4338 (A10): reported by its own surface now, the landing line, which names it at every survey with
                // "Try again" and "Discard" (`LandingRecovery.surveyAll`). Recorded here too, it would also stand in
                // the generic file notice, whose sentence says nothing in the app can repair it, beside a line
                // offering exactly that (#843, the rule `HandoffReadFailures.reportedByItsOwnSurface` states).
                readFailures.clear(file: label)
                return .quarantined(path: path, sequence: Self.sequence(inName: name), why: why)
            }
        }
    }

    // MARK: - Dan's two actions on a journal that could not be read (#4338, A10)

    // The run identity a journal's file NAME carries, quarantined or not, as `fileName` wrote it. nil for a name
    // that is not a journal's.
    static func runIdentity(inName name: String) -> String? {
        guard sequence(inName: name) != nil, let dash = name.firstIndex(of: "-") else { return nil }
        var rest = String(name[name.index(after: dash)...])
        if rest.hasSuffix(quarantineSuffix) { rest.removeLast(quarantineSuffix.count) }
        guard rest.hasSuffix(journalSuffix) else { return nil }
        rest.removeLast(journalSuffix.count)
        return rest.isEmpty ? nil : rest
    }

    enum Reread: Equatable {
        // It reads now, and is back in place as a pending journal, for the recovery to judge.
        case readable
        case stillUnreadable(why: String)
    }

    // "Try again": the quarantined file read once more. One that now decodes goes back under its own name, where
    // the next survey judges it like any other; one that still does not stays where it is, set aside.
    func tryReadingAgain(path: String) -> Reread {
        let url = URL(fileURLWithPath: path)
        let journal: LandingJournal
        do {
            journal = try Self.decode(Data(contentsOf: url))
        } catch {
            return .stillUnreadable(why: HandoffDecodeFailure.describe(error))
        }
        let destination = self.url(for: journal)
        guard destination.path != url.path else { return .readable }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return .stillUnreadable(why: "a landing record is already in its place at \(destination.path)")
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return .readable
        } catch {
            return .stillUnreadable(why: HandoffDecodeFailure.describe(error))
        }
    }

    // "Discard": the quarantined file removed. Only a file in this folder, named as a journal, is ever removed.
    func discardUnreadable(path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              Self.sequence(inName: url.lastPathComponent) != nil else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        try FileManager.default.removeItem(at: url)
    }

    // What discarding it changes, from what its NAME and the store can still say (L180, the plan's wording): the
    // landing finished (its record says so), its results are still kept and will be offered again, or neither, in
    // which case which calendars it named cannot be known, and any it had not saved stay unread until a scout
    // reads them, because their pages were never marked read.
    static func discardConsequence(landedAt: Date?, keptCopy: Bool) -> String {
        if let landedAt {
            return "That landing finished at \(LandingWaitCopy.landedTime(landedAt)), so discarding its record changes nothing else."
        }
        if keptCopy {
            return "Its calendar results are still kept and Overture will offer them again, so discarding its record changes nothing else."
        }
        return "Overture can't tell which calendars that landing named, so any it had not saved stay unread until your next scout reads them again."
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
            return LandingJournal(try decoder.decode(LandingJournal.Version1.self, from: data))
        case 2:
            return try decoder.decode(LandingJournal.self, from: data)
        default:
            throw UnknownVersion(version: version)
        }
    }

    static func encoded(_ journal: LandingJournal) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        // Always the shape this build writes, under the version that names it: a journal read from an older
        // version is carried forward in memory, and writing it back under its old number would label v2
        // fields as version 1 (L1010).
        var current = journal
        current.version = LandingJournal.currentVersion
        return try encoder.encode(current)
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
