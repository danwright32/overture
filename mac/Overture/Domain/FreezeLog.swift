import Foundation

// #3435 Phase 2e: the file the watchdog writes and the reader reads.
//
// Append-only NDJSON, one record per line, beside the store. It is a separate file rather than a field on
// anything, because it has to be written DURING a freeze by a thread that is not the main one, and
// because a record of the app failing to answer must survive the app being killed.
//
// A ROW IN docs/contracts.md comes with it, on the honest reason rather than the one #3435 gives: that
// document already catalogues every log this app writes but `backup.log`, so this would not be "the first
// with a blank reader column", it would be the second one missing entirely. It has a reader, named below
// and built in the same change, because a field only ever written looks alive to every is-this-used check
// while the purpose it was added for silently never happens (L46).
// #4122: what a compaction did, written into the live file so a reader can see the window's edge without
// knowing the algorithm.
//
// WHY THE FILE NEEDS ONE AT ALL. `FreezeLog.compacted` keeps the newest `fileCap` records, archives the
// rest, and promotes the single longest older stall back in. On 2026-09-21 Dan's live file went from 1,026
// records to 583 between 15:30 and 17:05 with nothing in it recording that, and it opened with a 1,047
// second stall from three days earlier followed by records from that evening. Every ad hoc reading over
// that file, "how many stalls today", "what was the worst", "what is the p90", answered about a truncated
// window with one out of band member in it, and #3660's bar is defined as a count over this very file.
//
// IT DESCRIBES THE FILE, not the event. A compaction rewrites the live file from the records it kept, so
// the previous note is not carried over and each file holds exactly one, describing its own composition.
// An older note would describe a window that no longer exists, which is the stale-evidence shape this
// whole issue is about.
//
// SEPARATE FROM `StallRecord.promotedFromOlderWindow` rather than a replacement for it, because the two
// serve readers that cannot use each other's answer: a `jq` over the lines sees the flag, and a reader of
// the whole file sees the counts and the boundary. Neither is derivable from the other, and the test pins
// them to agree so they cannot drift into two answers (L70).
struct FreezeLogNote: Codable, Equatable, Sendable {
    // The discriminator, and the ONLY key no `StallRecord` carries, which is what lets `FreezeLog.read`
    // tell a note from a stall without depending on the order it tries them in.
    static let compaction = "compaction"

    var note: String = FreezeLogNote.compaction
    let at: Date
    // How many records the file holds after this compaction, the promoted one included.
    let kept: Int
    // How many went to the archive.
    let archived: Int
    // The promoted record's own instant and length, or nothing where the rule did not fire. `nil` here is
    // a real answer: this compaction promoted nothing, so every record in the file is inside the window.
    let promotedAt: Date?
    let promotedSeconds: Double?
    // #4398: how many lines the compaction could not decode and carried through verbatim. Optional only
    // so a note written before this field existed still decodes as a note rather than becoming an
    // unreadable line itself; every compaction since writes the number, zero included.
    var keptUnreadable: Int? = nil
}

enum FreezeLog {
    // copy-inventory:ignore-start  a filename, not a sentence Overture says
    static let fileName = "freeze-log.ndjson"
    // #3763: the archive's name lives HERE, beside the live log's, inside the one exemption region. Given
    // its own region lower down it produced a second, identical exemption line in `docs/copy-inventory.md`,
    // which is a generated document saying the same thing twice.
    static let archiveFileName = "freeze-log-archive.ndjson"
    // copy-inventory:ignore-end

    static func url(in support: URL) -> URL { support.appendingPathComponent(fileName) }

    // #3763: where a compaction puts what it would otherwise have discarded.
    //
    // Derived from the LIVE url rather than taken as a parameter, so no caller can compact without
    // archiving: a behaviour every call site has to opt into is enforced by nothing (L621).
    static func archiveURL(besideLogAt url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(archiveFileName)
    }

    // What the reader has told Dan about already. Session-independent, on `RunBoundaryViolations`'s
    // precedent and for its reason: a freeze recorded in a session that then crashed still has to be said
    // the next time Overture opens.
    //
    // It holds the IDENTITIES of the records already said, and identity here is the session AND the
    // sequence, which is what `StallRecord` has said its identity was since it was written. Keying on the
    // sequence ALONE, which is what shipped first, is a durable value compared against a key that is only
    // as durable as the process (L186): the watchdog counts from 1 in every launch, so the moment this
    // held any number at all, the next session's records were all below it and NONE of them could ever be
    // reported again. The app would have gone silent about every freeze after the first session, and
    // silence is what a healthy session looks like (L98). Found 2026-09-06 in Dan's real log: one session,
    // 154 records, sequences 1 to 3412.
    //
    // #4453: NO LONGER WRITTEN. It held every identity ever considered, 29,527 of them and a 1,749,034
    // byte preferences file on 2026-10-02, rewritten on every report. `FreezeReport.said(in:)` reads it
    // once to migrate and `FreezeReport.saidKey` replaces it; the identity rule above is unchanged.
    static let reportedIdsKey = "freezesReportedIdentities"

    // One line. Encoded with a pinned date strategy, because a file read by a later version of the app
    // has to decode what an earlier one wrote (L26).
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func line(for record: StallRecord) -> String? {
        guard let data = try? encoder().encode(record),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    // #4122: the same, for the note a compaction writes about the window it just made.
    static func line(for note: FreezeLogNote) -> String? {
        guard let data = try? encoder().encode(note),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    // Every record the file holds, and the lines it could NOT read, kept apart.
    //
    // A line this cannot decode is COUNTED rather than dropped silently: a file half-written by a process
    // that was killed mid-freeze is exactly the file this exists to hold, so an unreadable tail is an
    // ordinary state and reporting nothing about it would be the emptiest possible failure reading as the
    // cleanest possible result (L98).
    struct Read: Equatable, Sendable {
        var records: [StallRecord] = []
        // #4122: what a compaction said about the window this file holds. Its own field rather than a
        // record, because it is not a stall and counting it as one would inflate every figure taken from
        // the file, which is the defect it exists to prevent arriving through the fix (L387).
        //
        // At most one in a live file, because a compaction rewrites the file from the records it kept and
        // therefore does not carry the previous note over. An ARRAY anyway, so a file holding two says so
        // rather than having one silently chosen for it (L521).
        var notes: [FreezeLogNote] = []
        // #4398: the lines this build could not decode, VERBATIM, rather than only how many, because
        // `compact` rewrites this file and a line it holds no copy of is a line the rewrite destroys. The
        // count is derived from these, so the two can never disagree (L53).
        var unreadable: [String] = []
        var unreadableLines: Int { unreadable.count }
        // The file was not there at all, which is what a session with no freeze looks like AND what a
        // watchdog that never ran looks like. Kept as its own fact so the reader can say which (L11).
        var fileWasAbsent: Bool = false
        // #4453: the file IS there and could not be opened. Until this it read as `fileWasAbsent`, so a
        // file nobody could read and a file that was never written were one silence, and the reader
        // treated every record in it as never having existed (L11, L98). Every caller that only asks
        // "is there anything to work on" is unchanged by it: the records are empty either way.
        var couldNotBeRead: Bool = false
    }

    // #4453: one line of the file, decoded ONCE, so the whole file reader and the archive's tail reader
    // cannot come to disagree about what a line is (L263).
    enum Line: Equatable, Sendable {
        case record(StallRecord)
        case note(FreezeLogNote)
        case unreadable(String)
    }

    static func decodeLine(_ data: Data, with decoder: JSONDecoder) -> Line {
        // #4122: the NOTE first, and the order is decided rather than incidental. A note carries a
        // `note` key that no `StallRecord` has, and a `StallRecord` requires `session`, `sequence`,
        // `at` and `seconds`, none of which a note carries, so neither can decode as the other and the
        // order cannot change any verdict. Trying the note first is simply the cheaper miss.
        if let note = try? decoder.decode(FreezeLogNote.self, from: data) { return .note(note) }
        if let record = try? decoder.decode(StallRecord.self, from: data) { return .record(record) }
        return .unreadable(String(decoding: data, as: UTF8.self))
    }

    static func read(_ text: String) -> Read {
        var out = Read()
        let decoder = decoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8) else {
                out.unreadable.append(String(line))
                continue
            }
            switch decodeLine(data, with: decoder) {
            case .note(let note): out.notes.append(note)
            case .record(let record): out.records.append(record)
            // The line as the FILE held it, because `compact` writes it back verbatim (#4398).
            case .unreadable: out.unreadable.append(String(line))
            }
        }
        return out
    }

    static func read(at url: URL) -> Read {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            var out = Read()
            if FileManager.default.fileExists(atPath: url.path) {
                out.couldNotBeRead = true
            } else {
                out.fileWasAbsent = true
            }
            return out
        }
        return read(text)
    }

    // MARK: - #4453: the archive, read from its END

    // WHY THE ARCHIVE IS NOT READ WHOLE. On 2026-10-02 the archive beside Dan's live log was 9,245,974
    // bytes and 29,527 records, and the launch notice decoded every one of them on the main thread each
    // time the window appeared, to learn that almost none were new: 69% of 4,270 main thread samples were
    // in that read, and the window stopped responding. The archive keeps a month, so the cost grew with
    // every freeze it exists to report (#4453).
    //
    // WHAT MAKES A TAIL READ CORRECT. Records only ever ARRIVE in the live file, from the watchdog. The
    // archive receives them in exactly one way, `compact` APPENDING what it dropped, and loses them in
    // exactly one way, `pruneArchive` removing the old ones while keeping the order of the rest. So
    // everything the archive gained since it was last read sits AFTER the last record it held then, and
    // nothing before that point can be new to it. The reader remembers the archive's last few records
    // and reads backwards only until it meets one of them.
    //
    // Position, NEVER time. A rule saying "everything older than the newest record already said has been
    // said" would be cheaper still and is wrong here: `compact` promotes an old stall to the head of the
    // live file and later displaces it into the archive, so the archive is not in time order, and a clock
    // that steps backwards would make new records look old and lose them for good (L74, L98).
    //
    // An identity paired with its instant, because the files can hold one record twice: a compaction
    // whose live rewrite failed leaves the same record in both, and it is archived a second time (#3763).
    struct ArchiveAnchor: Codable, Equatable, Hashable, Sendable {
        let identity: String
        let at: Date

        init(identity: String, at: Date) {
            self.identity = identity
            self.at = at
        }

        init(_ record: StallRecord) {
            self.init(identity: record.identity, at: record.at)
        }
    }

    // How many of the archive's last records are remembered, rather than only the last one.
    //
    // ONE IS NOT ENOUGH, and the case is specific. When a compaction drops nothing but the stall it had
    // promoted, that OLD record becomes the archive's last line, and the month's prune can then remove it
    // while keeping every newer record appended before it. With one anchor the reader finds nothing it
    // remembers, reads the whole month as new, and announces all of it again (L36). With several, the
    // next one back is still there. Eight is a constant cost, decoded on every read.
    static let archiveAnchorDepth = 8

    struct ArchiveTail: Equatable, Sendable {
        // Every record appended after the remembered position, OLDEST FIRST, the order the file holds them.
        // With no remembered position found, every record the file holds.
        var records: [StallRecord] = []
        // The lines in that same stretch that could not be decoded. Only that stretch: the rest of the
        // archive was counted when it was new.
        var unreadableLines: Int = 0
        // The archive's last records NOW, newest first, which is where the next read starts from.
        var anchors: [ArchiveAnchor] = []
        var fileWasAbsent: Bool = false
        var couldNotBeRead: Bool = false
    }

    // The lines of `data`, LAST FIRST, without splitting or decoding anything it is not asked for. A
    // mapped file is paged in only where this walks, so a read that stops after the last few lines costs
    // the last few lines.
    struct LinesFromEnd: Sequence, IteratorProtocol {
        private let data: Data
        private var end: Data.Index

        init(_ data: Data) {
            self.data = data
            self.end = data.endIndex
        }

        mutating func next() -> Data? {
            while end > data.startIndex {
                let newline = data[data.startIndex..<end].lastIndex(of: 0x0A)
                let start = newline.map { data.index(after: $0) } ?? data.startIndex
                let line = data[start..<end]
                end = newline ?? data.startIndex
                if !line.isEmpty { return Data(line) }
            }
            return nil
        }
    }

    // The rule, over lines handed to it newest first, so a test can drive it with lines in memory and the
    // file reader below is only the part that opens the file.
    //
    // `decode` is a PARAMETER so a test can count what this decodes, which is the quantity #4453 is about,
    // rather than timing it on a machine whose load is not under its control (L224, L290).
    static func archiveTail<Lines: Sequence>(newestFirst lines: Lines, after remembered: [ArchiveAnchor],
                                            decode: (Data) -> Line) -> ArchiveTail
        where Lines.Element == Data {
        var out = ArchiveTail()
        let wanted = Set(remembered)
        var newestFirst: [StallRecord] = []
        var met = false
        for data in lines {
            switch decode(data) {
            case .note:
                continue
            case .unreadable:
                if !met { out.unreadableLines += 1 }
            case .record(let record):
                let anchor = ArchiveAnchor(record)
                if out.anchors.count < archiveAnchorDepth { out.anchors.append(anchor) }
                if !met, wanted.contains(anchor) { met = true }
                if !met { newestFirst.append(record) }
            }
            // Past the remembered position AND holding enough of the newest records to start from next
            // time, so nothing further back can change the answer.
            if met, out.anchors.count >= archiveAnchorDepth { break }
        }
        out.records = newestFirst.reversed()
        return out
    }

    static func readArchiveTail(at url: URL, after remembered: [ArchiveAnchor],
                                decode: ((Data) -> Line)? = nil) -> ArchiveTail {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ArchiveTail(fileWasAbsent: true)
        }
        // A file that exists and cannot be opened is its own outcome, never an empty archive
        // (HandoffFileReadTests.noAppSourceSwallowsAFileRead, #2879).
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return ArchiveTail(couldNotBeRead: true)
        }
        let decoder = decoder()
        return archiveTail(newestFirst: LinesFromEnd(data), after: remembered,
                           decode: decode ?? { decodeLine($0, with: decoder) })
    }

    // How many records the FILE keeps.
    //
    // The in-memory `StallLog.cap` bounds what one session holds; this bounds what accumulates across
    // every session for the life of the install. They are different numbers for different reasons and
    // this one is larger, because the file is the only thing that survives a relaunch and #3439 reads its
    // floor from a working session rather than the current one.
    static let fileCap = 500

    // What survives compaction, and how many were dropped. PURE, so the rule can be exercised rather
    // than watched not to happen.
    //
    // THE LONGEST STALL IS KEPT HOWEVER OLD IT IS, which is the same rule #3435 wrote for the in-memory
    // store one layer down and for the same reason: a cap by count over a file where a 250 ms blip and a
    // 58 second freeze are one line each lets cheap writers evict expensive observations, and the single
    // reading this file exists to support is the MAXIMUM (L191, L63).
    struct Compacted: Equatable, Sendable {
        var records: [StallRecord]
        // #3763: the records themselves, not only how many. A count is enough to REPORT a loss and not
        // enough to PREVENT one, and preventing it is what this milestone's own before-and-after reading
        // depends on. `dropped` is derived from this rather than stored beside it, so the number and the
        // records it describes cannot drift apart (L53, L83).
        var droppedRecords: [StallRecord]
        var dropped: Int { droppedRecords.count }
    }

    static func compacted(_ records: [StallRecord], cap: Int = fileCap) -> Compacted {
        guard records.count > cap else { return Compacted(records: records, droppedRecords: []) }
        // Split once, and work in POSITIONS from here on. #3763's first version asked which records were
        // dropped by taking the identities it kept and filtering the rest out, and a log can hold the same
        // record twice: a file half written by a process killed mid-freeze is the ordinary case here, which
        // is why `read` counts unreadable lines rather than discarding them. An identity surviving in the
        // kept window then answered for its own older copy, so that copy was neither kept nor archived and
        // went nowhere. Measured in the test beside this: wrote 10 lines, kept 4, archived 5.
        let splitAt = records.count - cap
        let prefix = Array(records[..<splitAt])
        let newest = Array(records[splitAt...])

        // ONLY a stall STRICTLY longer than everything already kept earns the slot. Written as "keep the
        // maximum" it shuffled ties: with every record the same length the oldest one is a maximum, so it
        // was promoted over a newer one for no reason. What this exists to save is a genuinely
        // exceptional freeze, not an arbitrary member of a tie.
        //
        // Searched in the PREFIX and held as an INDEX. The prefix is where a promotable record has to be:
        // anything in `newest` is at most `longestKept`, so the strict test below could never admit it.
        // An index rather than the value, because two records of the same length are indistinguishable by
        // value and removing "the worst" from the dropped list could then remove its twin instead.
        let longestKept = newest.map(\.seconds).max() ?? 0
        guard let worstIndex = prefix.indices.max(by: { prefix[$0].seconds < prefix[$1].seconds }),
              prefix[worstIndex].seconds > longestKept else {
            return Compacted(records: newest, droppedRecords: prefix)
        }

        // Keeping the worst must not grow the file past its cap, so it takes the oldest slot rather than
        // being added to the end: it IS the oldest thing worth keeping. The record it displaces is dropped
        // and therefore archived, and it is appended last because it is chronologically last.
        var kept = Array(newest.dropFirst())
        // #4122: MARKED as it is promoted, so a reader going line by line can drop it from a window it is
        // not part of without knowing this rule exists. Marked by copying and setting the one field, never
        // by rebuilding through `init`, which would re-derive `surfaceVocabulary` from the running build
        // and quietly restamp a record an older build wrote (L443).
        var promoted = prefix[worstIndex]
        promoted.promotedFromOlderWindow = true
        kept.insert(promoted, at: 0)
        var dropped = prefix
        dropped.remove(at: worstIndex)
        if let displaced = newest.first { dropped.append(displaced) }
        return Compacted(records: kept, droppedRecords: dropped)
    }

    // MARK: - the archive's retention (#3763)

    // How long an archived record is kept. Dan's call, 2026-09-11: a month, not forever.
    //
    // DAYS rather than calendar months, because a month is not a fixed length and nothing here needs it to
    // be: this bounds a diagnostic archive, and one expressed in days has no timezone or month-length edge
    // for a reader to get wrong (L39).
    static let archiveRetentionDays = 31

    // What a prune keeps and what it removed. The count and both ends of the range are DERIVED from the
    // dropped records rather than stored beside them, so a report cannot describe a different set from the
    // one actually removed (L53, L83).
    //
    // #4454: what it keeps is LINES, as the file held them, rather than records decoded and encoded again.
    // Re-encoding cost a full encode of every survivor every hour, and it also rewrote each one through this
    // build's `StallRecord`, which drops any field a later build added (L425).
    struct Pruned: Equatable, Sendable {
        var keptLines: [Data]
        var droppedRecords: [StallRecord]
        var dropped: Int { droppedRecords.count }
        // nil when nothing was dropped, never a sentinel date: a prune that removed nothing and one that
        // removed a record stamped at the epoch must not read the same (L98, L11).
        var earliestDropped: Date? { droppedRecords.map(\.at).min() }
        var latestDropped: Date? { droppedRecords.map(\.at).max() }
    }

    // The instant before which an archived record is past its month. One definition, read by the rule below
    // and by the tests that pin its edge, so the two cannot come to disagree about where the month ends.
    static func archiveCutoff(now: Date, retentionDays: Int) -> Date {
        now.addingTimeInterval(-Double(retentionDays) * 60 * 60 * 24)
    }

    // #4454: the cutoff as the file would WRITE it, rounded UP to the whole second, so a line's stamp can be
    // compared as bytes. The file stores whole seconds, and for a whole second `at < cutoff` holds exactly
    // when `at < ceil(cutoff)`, so a stamp at or after this is inside the window and no stamp before it is.
    // Formatted by the encoder's own formatter rather than a second definition of the format (L263).
    static func cutoffStamp(_ cutoff: Date) -> [UInt8]? {
        let whole = Date(timeIntervalSinceReferenceDate: cutoff.timeIntervalSinceReferenceDate.rounded(.up))
        guard let data = try? encoder().encode(whole), data.count == stampLength + 2 else { return nil }
        return Array(data.dropFirst().dropLast())
    }

    // `2026-09-24T15:52:41Z`, which is what `.iso8601` writes and the only shape the stamp reader accepts.
    static let stampLength = 20

    // The record's own `at`, read from the line's BYTES without decoding it, or nil whenever that cannot be
    // done with certainty, in which case the caller decodes the line.
    //
    // WHY THIS IS SAFE, since it decides which lines are never decoded. Inside a JSON string a quote is
    // escaped, so the bytes `"at":"` can only be a key named `at` with a string value. A `StallRecord` has
    // exactly one at its top level and nothing nested that carries one, so a line holding that sequence
    // EXACTLY once, followed by a stamp of exactly the encoder's shape, has that stamp as its `at`. Two
    // occurrences, or none, or any other shape, is not guessed at. Searched for anywhere in the line rather
    // than expected first, because keys are sorted and `asleepSeconds` (#4153) already sorts ahead of `at`.
    // And it only ever decides that a line is KEPT: a line it says is old is decoded before anything removes
    // it, so the worst a wrong answer here can do is keep a record, never lose one.
    static func stamp(of line: Data) -> ArraySlice<UInt8>? {
        let key: [UInt8] = Array("\"at\":\"".utf8)
        return line.withUnsafeBytes { raw -> ArraySlice<UInt8>? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var found: Int?
            var index = 0
            while index + key.count <= bytes.count {
                if bytes[index] == key[0], bytes[index + 1] == key[1], bytes[index + 2] == key[2],
                   bytes[index + 3] == key[3], bytes[index + 4] == key[4], bytes[index + 5] == key[5] {
                    guard found == nil else { return nil }
                    found = index + key.count
                    index += key.count
                } else {
                    index += 1
                }
            }
            guard let start = found, start + stampLength < bytes.count,
                  bytes[start + stampLength] == UInt8(ascii: "\"") else { return nil }
            let stamp = Array(bytes[start..<(start + stampLength)])
            for (offset, byte) in stamp.enumerated() {
                let expected: UInt8?
                switch offset {
                case 4, 7: expected = UInt8(ascii: "-")
                case 10: expected = UInt8(ascii: "T")
                case 13, 16: expected = UInt8(ascii: ":")
                case 19: expected = UInt8(ascii: "Z")
                default: expected = nil
                }
                if let expected {
                    guard byte == expected else { return nil }
                } else {
                    guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                }
            }
            return stamp[...]
        }
    }

    // A month means a month, with NO exception for the longest stall, and that is worth stating because the
    // two layers above this one both have such an exception. `compacted` promotes the single longest stall
    // into the live file and keeps it there however old it is, and `StallLog` does the same in memory, both
    // because the MAXIMUM is the reading those exist to support. Repeating the rule here would protect
    // nothing: a record only reaches the archive by being dropped from the live file, and the all-time worst
    // stall is precisely the one the live file refuses to drop. So the archive's oldest month can go without
    // putting the maximum at risk, and an exception here would be a second copy of a rule whose single copy
    // already works (L274).
    //
    // #4454: WHAT IT DECODES. Until this it decoded every record in the archive, 29,527 of them on
    // 2026-10-02, every hour, to remove the few that had aged past the month since the last pass. Now a line
    // whose stamp is inside the window is kept without being decoded, and only a line whose stamp says old,
    // or that has no stamp it can read, is decoded and judged by the rule on the decoded record. It still
    // looks at EVERY line rather than stopping at the first one inside the window, because the archive is
    // not in time order: `compact` appends a promoted old stall after newer records, measured three times
    // in a copy of Dan's archive on 2026-10-03, the oldest a week behind its neighbours (#3763).
    //
    // WHAT IT KEEPS. Every line it cannot show is a record past the month, verbatim: a line nobody can read,
    // a note, a record inside the window. Until #4454 the prune refused to touch an archive holding a line it
    // could not read, which kept that line but stopped the archive ever being bounded again; keeping the
    // line and removing only what it positively knows is old is #4398's answer for the live file (L211).
    //
    // `decode` is a PARAMETER so a test can count what this decodes, on `archiveTail`'s precedent (L224).
    static func pruned<Lines: Sequence>(lines: Lines, now: Date, retentionDays: Int = archiveRetentionDays,
                                        decode: (Data) -> Line) -> Pruned where Lines.Element == Data {
        let cutoff = archiveCutoff(now: now, retentionDays: retentionDays)
        let window = cutoffStamp(cutoff)
        // Order preserved, so the archive stays roughly chronological after a prune, the reported range
        // reads in the direction the records were written, and #4453's tail reader, which relies on a
        // prune only ever REMOVING lines, stays right.
        var kept: [Data] = []
        var dropped: [StallRecord] = []
        for line in lines {
            if let window, let stamp = stamp(of: line), !stamp.lexicographicallyPrecedes(window) {
                kept.append(line)
                continue
            }
            switch decode(line) {
            case .record(let record) where record.at < cutoff:
                dropped.append(record)
            case .record, .note, .unreadable:
                kept.append(line)
            }
        }
        return Pruned(keptLines: kept, droppedRecords: dropped)
    }

    // The lines of `data`, FIRST FIRST, the twin of `LinesFromEnd`. Each is a slice sharing the file's
    // storage rather than a copy, so a line the prune keeps without reading costs no allocation.
    struct LinesFromStart: Sequence, IteratorProtocol {
        private let data: Data
        private var start: Data.Index

        init(_ data: Data) {
            self.data = data
            self.start = data.startIndex
        }

        mutating func next() -> Data? {
            while start < data.endIndex {
                let newline = data[start..<data.endIndex].firstIndex(of: 0x0A)
                let end = newline ?? data.endIndex
                let line = data[start..<end]
                start = newline.map { data.index(after: $0) } ?? data.endIndex
                if !line.isEmpty { return line }
            }
            return nil
        }
    }

    // The file half of the retention, stubbed so the tests beside it fail on behaviour rather than on a
    // missing symbol. `refusedUnreadableLines` is its own field rather than a flag, because how many lines
    // could not be read is what a person would need to act on it.
    // ONE discriminated value rather than four fields beside each other, because the fields could express
    // states this function cannot produce (L544). Written as a struct first, and a test composing the
    // notice constructed "refused to read the archive" AND "deleted 412 records from it" at once, which read
    // as a flat contradiction. It was not a copy defect: a refusal returns before anything is removed, so
    // the two are mutually exclusive by construction and the TYPE was the thing admitting otherwise.
    enum ArchivePrune: Equatable, Sendable {
        // Nothing old enough to remove, or no archive at all. The ordinary state on most launches.
        case nothingToRemove
        // #4454: records were past their month and the archive could not be rewritten without them, so it
        // was left exactly as it was and is no longer being bounded until a later pass succeeds. In place of
        // `refused(unreadableLines:)`, which stopped every prune over a line nobody could read; such a line
        // is now kept and the prune carries on, so a write is the one thing left that can stop it.
        case couldNotRewrite
        // Records permanently removed, with the span they covered. Both ends are non-optional here: a
        // removal always has a first and last record, and making them optional would recreate the
        // unrepresentable state this enum exists to close.
        case removed(count: Int, earliest: Date, latest: Date)
    }

    // `decode` and `write` are parameters so a test can count what a pass decodes and fail its write on
    // demand; production passes neither.
    static func pruneArchive(besideLogAt url: URL, now: Date,
                            retentionDays: Int = archiveRetentionDays,
                            decode: ((Data) -> Line)? = nil,
                            write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) })
        -> ArchivePrune {
        let archive = archiveURL(besideLogAt: url)
        // No archive is the ordinary state: most installs have never compacted. Nothing to report.
        guard FileManager.default.fileExists(atPath: archive.path) else { return .nothingToRemove }
        // A file that is there and cannot be opened removes nothing, as it did before #4454, and nothing is
        // claimed about it here: the compaction beside this is the step that writes this file, and its own
        // failure is what says the folder is unusable (HandoffFileReadTests.noAppSourceSwallowsAFileRead).
        let data: Data
        do {
            data = try Data(contentsOf: archive, options: .mappedIfSafe)
        } catch {
            return .nothingToRemove
        }

        // #4454: as BYTES, line by line, rather than through `read(at:)`, which decoded every record and
        // whose whole file String read hides the file entirely over one invalid byte (#4411).
        let decoder = decoder()
        let result = pruned(lines: LinesFromStart(data), now: now, retentionDays: retentionDays,
                            decode: decode ?? { decodeLine($0, with: decoder) })
        guard result.dropped > 0 else { return .nothingToRemove }

        // Atomically, so a failed write leaves the archive as it was rather than half of it. And the result
        // is only reported as a drop once the write has actually happened: saying records were removed when
        // the write failed would be a report of a deletion nobody performed, which is the mirror of the
        // silence this whole issue is about (L12). A failure is its own outcome rather than a quiet
        // `nothingToRemove`, because the archive has stopped being bounded and that is not a quiet hour.
        var payload = Data()
        payload.reserveCapacity(data.count)
        for line in result.keptLines {
            payload.append(line)
            payload.append(0x0A)
        }
        do {
            try write(payload, archive)
        } catch {
            return .couldNotRewrite
        }
        // Both ends are present whenever anything was dropped, so the fallback can never be reached; it is
        // here because the enum refuses to carry a removal without its span, which is the point of it.
        guard let earliest = result.earliestDropped, let latest = result.latestDropped else {
            return .nothingToRemove
        }
        return .removed(count: result.dropped, earliest: earliest, latest: latest)
    }

    // Everything one launch's bookkeeping did, in one value, so the caller reports all of it or none.
    //
    // ONE entry point (`housekeeping(at:now:)`) rather than a compact call and a prune call, because a
    // caller that can do one and forget the other will eventually do exactly that, and a behaviour every
    // call site has to opt into is enforced by nothing (L621).
    // What the compaction did, as ONE value. The twin of `ArchivePrune`'s own defect, fixed in the same
    // change rather than filed: `archived: Int` beside `archiveFailed: Bool` could express "archived 200
    // records and also could not write the archive", which `compact` cannot produce, because a failed
    // archive returns before anything is trimmed (L30, L544).
    enum CompactionOutcome: Equatable, Sendable {
        // Under the cap, so nothing moved. The ordinary state.
        case nothingToArchive
        // #4398: `keptUnreadable` is how many undecodable lines were carried through verbatim.
        case archived(count: Int, keptUnreadable: Int = 0)
        // The archive could not be written, so the live file was deliberately left OVER its cap rather than
        // trimmed. Distinct from `nothingToArchive` because one is healthy and one needs attention (L11).
        case archiveFailed
    }

    struct Housekeeping: Equatable, Sendable {
        var compaction: CompactionOutcome = .nothingToArchive
        var prune: ArchivePrune = .nothingToRemove

        // Nothing happened that Dan needs telling about. The overwhelmingly common outcome, because the
        // cap is rarely reached and the month rarely elapses between two runs.
        var isQuiet: Bool { self == Housekeeping() }
    }

    // Which report the app should still be HOLDING, given what it was holding and what a run just
    // reported. Pure, and here rather than inside `RootView`, so the rule can be exercised rather than
    // reasoned about from a view nothing can drive (L196).
    //
    // WHY IT IS NOT JUST AN ASSIGNMENT. Housekeeping runs at launch and then hourly (#3796), and a quiet
    // run draws no notice at all. A plain assignment therefore lets the next hourly tick REPLACE a launch
    // report that permanently deleted records, taking the only account of that deletion off the screen
    // an hour later, before Dan had any particular reason to have read it. That is #3830's defect exactly,
    // and it would have arrived here as a side effect of fixing a different issue (L387).
    static func kept(_ current: Housekeeping?, after done: Housekeeping) -> Housekeeping? {
        done.isQuiet ? current : done
    }

    // COMPACT THEN PRUNE, in that order, and the order is load bearing rather than incidental: compacting
    // can CREATE the archive this prune then bounds, so pruning first would leave whatever the compaction
    // just wrote unbounded until the next launch.
    static func housekeeping(at url: URL, now: Date, cap: Int = fileCap,
                            retentionDays: Int = archiveRetentionDays) -> Housekeeping {
        let compaction = compact(at: url, cap: cap, now: now)
        let prune = pruneArchive(besideLogAt: url, now: now, retentionDays: retentionDays)
        return Housekeeping(compaction: compaction, prune: prune)
    }

    // Run at LAUNCH and never on the freeze path. An append is safe to do while the main thread is
    // wedged; a read, modify, write is not, and one whose read fails erases the record at exactly the
    // moment it is worth having (L105).
    // Reports an OUTCOME rather than a count. The count alone could not distinguish "nothing was over the
    // cap" from "the archive write failed so nothing was trimmed", and those are a healthy launch and one
    // needing attention (L11).
    @discardableResult
    static func compact(at url: URL, cap: Int = fileCap, now: Date = Date()) -> CompactionOutcome {
        let read = read(at: url)
        guard !read.fileWasAbsent else { return .nothingToArchive }
        let result = compacted(read.records, cap: cap)
        guard result.dropped > 0 else { return .nothingToArchive }
        // #3763: archived BEFORE the live file is rewritten, and the truncation is ABANDONED if that
        // failed. These two writes have no transaction around them, so the order is the whole safeguard:
        // doing the destructive half first leaves a failed archive indistinguishable from a clean
        // compaction, with the records already gone (L5).
        //
        // ONE write rather than one per record. This runs at launch on the same thread the rest of this
        // milestone is trying to get off, and the real case is the 186 records measured on 2026-09-10, so a
        // file opened and closed per record would be 186 opens added to exactly the path under repair.
        guard archive(result.droppedRecords, besideLogAt: url) else { return .archiveFailed }
        // #4122: the note FIRST, so it sits beside the promoted record the rewrite inserts at index 0,
        // which is exactly where a reader of the file's head meets the thing that needs explaining.
        //
        // A note that will not ENCODE is left out rather than failing the compaction, and that is the
        // right way round: the records are already safely in the archive, and refusing to truncate over a
        // missing annotation would leave the file over its cap for ever. What is lost is the explanation,
        // and the per record mark still carries it.
        let promoted = result.records.first { $0.promotedFromOlderWindow == true }
        let note = FreezeLogNote(at: now, kept: result.records.count, archived: result.dropped,
                                 promotedAt: promoted?.at, promotedSeconds: promoted?.seconds,
                                 keptUnreadable: read.unreadable.count)
        // #4398: every line the read could NOT decode is carried through VERBATIM, after the note and before
        // the records. Rewriting from the decoded records alone destroyed them: a line torn by a process
        // killed mid-freeze, which is the ordinary case this file exists for, was in neither the live file
        // nor the archive afterwards and nothing counted it, while `pruneArchive` refuses on the same
        // condition (L211, L5). Kept in the LIVE file rather than the archive, because the archive's prune
        // refused on an unreadable line and one moved there would have stopped the archive ever being
        // bounded. Since #4454 the prune keeps such a line and carries on, so that reason is gone; the live
        // file is still where the line stays, because it is where the reader counts it.
        let lines = [line(for: note)].compactMap { $0 } + read.unreadable + result.records.compactMap(line(for:))
        let text = lines.joined(separator: "\n") + "\n"
        // The archive already holds these records, so a failed rewrite here leaves them in BOTH files rather
        // than in neither: nothing is lost, and the live file is simply still over its cap until the next
        // launch tries again. So the write's result is deliberately not branched on. Written as a guard
        // first, with both arms returning the same value, which is a decision that decides nothing and is
        // worse than no guard because it reads as one (L260).
        _ = try? text.write(to: url, atomically: true, encoding: .utf8)
        return .archived(count: result.dropped, keptUnreadable: read.unreadable.count)
    }

    // Appended rather than rewritten, so a write during a freeze cannot lose what is already there and
    // cannot be a read-modify-write whose read failing erases the record (L105).
    @discardableResult
    static func append(_ record: StallRecord, to url: URL) -> Bool {
        guard let line = line(for: record) else { return false }
        return appending(line + "\n", to: url)
    }

    // #3763: every dropped record into the archive, in one write, answering whether ALL of them landed.
    //
    // A record that will not ENCODE counts as a failure rather than being quietly skipped, because a
    // compactMap here would drop it from the archive and then let the truncation proceed, which is the
    // exact loss this whole guard exists to prevent, arriving through the guard itself (L387).
    static func archive(_ records: [StallRecord], besideLogAt url: URL) -> Bool {
        guard !records.isEmpty else { return true }
        let lines = records.compactMap(line(for:))
        guard lines.count == records.count else { return false }
        return appending(lines.joined(separator: "\n") + "\n", to: archiveURL(besideLogAt: url))
    }

    // The one place either caller touches the filesystem, so the archive cannot acquire a different
    // durability story from the live log by being written somewhere else (L263).
    private static func appending(_ text: String, to url: URL) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return false }
            do { try handle.write(contentsOf: data) } catch { return false }
            return true
        }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
