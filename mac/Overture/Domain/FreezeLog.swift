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
enum FreezeLog {
    // copy-inventory:ignore-start  a filename, not a sentence Overture says
    static let fileName = "freeze-log.ndjson"
    // copy-inventory:ignore-end

    static func url(in support: URL) -> URL { support.appendingPathComponent(fileName) }

    // #3763: where a compaction puts what it would otherwise have discarded.
    //
    // Derived from the LIVE url rather than taken as a parameter, so no caller can compact without
    // archiving: a behaviour every call site has to opt into is enforced by nothing (L621).
    // copy-inventory:ignore-start  a filename, not a sentence Overture says
    static let archiveFileName = "freeze-log-archive.ndjson"
    // copy-inventory:ignore-end

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

    // Every record the file holds, and the lines it could NOT read, kept apart.
    //
    // A line this cannot decode is COUNTED rather than dropped silently: a file half-written by a process
    // that was killed mid-freeze is exactly the file this exists to hold, so an unreadable tail is an
    // ordinary state and reporting nothing about it would be the emptiest possible failure reading as the
    // cleanest possible result (L98).
    struct Read: Equatable, Sendable {
        var records: [StallRecord] = []
        var unreadableLines: Int = 0
        // The file was not there at all, which is what a session with no freeze looks like AND what a
        // watchdog that never ran looks like. Kept as its own fact so the reader can say which (L11).
        var fileWasAbsent: Bool = false
    }

    static func read(_ text: String) -> Read {
        var out = Read()
        let decoder = decoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(StallRecord.self, from: data) else {
                out.unreadableLines += 1
                continue
            }
            out.records.append(record)
        }
        return out
    }

    static func read(at url: URL) -> Read {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            var out = Read()
            out.fileWasAbsent = true
            return out
        }
        return read(text)
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
        let newest = Array(records.suffix(cap))
        guard let worst = records.max(by: { $0.seconds < $1.seconds }) else {
            return Compacted(records: newest, droppedRecords: dropping(records, keeping: newest))
        }
        // ONLY a stall STRICTLY longer than everything already kept earns the slot. Written as "keep the
        // maximum" it shuffled ties: with every record the same length the oldest one is a maximum, so it
        // was promoted over a newer one for no reason. What this exists to save is a genuinely
        // exceptional freeze, not an arbitrary member of a tie.
        let longestKept = newest.map(\.seconds).max() ?? 0
        guard worst.seconds > longestKept else {
            return Compacted(records: newest, droppedRecords: dropping(records, keeping: newest))
        }
        // Keeping the worst must not grow the file past its cap, so it takes the oldest slot rather than
        // being added to the end: it IS the oldest thing worth keeping.
        var kept = Array(newest.dropFirst())
        kept.insert(worst, at: 0)
        return Compacted(records: kept, droppedRecords: dropping(records, keeping: kept))
    }

    // What a compaction did NOT keep. By IDENTITY, because the keep-the-longest rule means the kept set is
    // not a suffix: one survivor is pulled out of the middle, so a positional difference would name the
    // wrong records. Identity is session plus sequence, which is what `StallRecord` has always said its
    // identity is.
    private static func dropping(_ all: [StallRecord], keeping kept: [StallRecord]) -> [StallRecord] {
        let keptIds = Set(kept.map(\.identity))
        return all.filter { !keptIds.contains($0.identity) }
    }

    // Run at LAUNCH and never on the freeze path. An append is safe to do while the main thread is
    // wedged; a read, modify, write is not, and one whose read fails erases the record at exactly the
    // moment it is worth having (L105).
    @discardableResult
    static func compact(at url: URL, cap: Int = fileCap) -> Int {
        let read = read(at: url)
        guard !read.fileWasAbsent else { return 0 }
        let result = compacted(read.records, cap: cap)
        guard result.dropped > 0 else { return 0 }
        // #3763: archived BEFORE the live file is rewritten, and the truncation is ABANDONED if that
        // failed. These two writes have no transaction around them, so the order is the whole safeguard:
        // doing the destructive half first leaves a failed archive indistinguishable from a clean
        // compaction, with the records already gone (L5).
        //
        // ONE write rather than one per record. This runs at launch on the same thread the rest of this
        // milestone is trying to get off, and the real case is the 186 records measured on 2026-09-10, so a
        // file opened and closed per record would be 186 opens added to exactly the path under repair.
        guard archive(result.droppedRecords, besideLogAt: url) else { return 0 }
        let text = result.records.compactMap(line(for:)).joined(separator: "\n") + "\n"
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return 0 }
        return result.dropped
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
