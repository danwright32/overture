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
        kept.insert(prefix[worstIndex], at: 0)
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
    struct Pruned: Equatable, Sendable {
        var records: [StallRecord]
        var droppedRecords: [StallRecord]
        var dropped: Int { droppedRecords.count }
        // nil when nothing was dropped, never a sentinel date: a prune that removed nothing and one that
        // removed a record stamped at the epoch must not read the same (L98, L11).
        var earliestDropped: Date? { droppedRecords.map(\.at).min() }
        var latestDropped: Date? { droppedRecords.map(\.at).max() }
    }

    // A month means a month, with NO exception for the longest stall, and that is worth stating because the
    // two layers above this one both have such an exception. `compacted` promotes the single longest stall
    // into the live file and keeps it there however old it is, and `StallLog` does the same in memory, both
    // because the MAXIMUM is the reading those exist to support. Repeating the rule here would protect
    // nothing: a record only reaches the archive by being dropped from the live file, and the all-time worst
    // stall is precisely the one the live file refuses to drop. So the archive's oldest month can go without
    // putting the maximum at risk, and an exception here would be a second copy of a rule whose single copy
    // already works (L274).
    static func pruned(_ records: [StallRecord], now: Date,
                       retentionDays: Int = archiveRetentionDays) -> Pruned {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 60 * 60 * 24)
        // Order preserved on both sides, so the archive stays roughly chronological after a prune and the
        // reported range reads in the direction the records were written.
        var kept: [StallRecord] = []
        var dropped: [StallRecord] = []
        for record in records {
            if record.at < cutoff { dropped.append(record) } else { kept.append(record) }
        }
        return Pruned(records: kept, droppedRecords: dropped)
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
        // The archive holds lines that could not be decoded, so nothing was touched. Carries the count
        // because how many is what somebody would act on.
        case refused(unreadableLines: Int)
        // Records permanently removed, with the span they covered. Both ends are non-optional here: a
        // removal always has a first and last record, and making them optional would recreate the
        // unrepresentable state this enum exists to close.
        case removed(count: Int, earliest: Date, latest: Date)
    }

    static func pruneArchive(besideLogAt url: URL, now: Date,
                            retentionDays: Int = archiveRetentionDays) -> ArchivePrune {
        let archive = archiveURL(besideLogAt: url)
        let read = read(at: archive)
        // No archive is the ordinary state: most installs have never compacted. Nothing to report.
        guard !read.fileWasAbsent else { return .nothingToRemove }

        // REFUSE on a short read, not only on a failed one. This function rewrites the file from what the
        // read returned, so every line the read could not decode would be destroyed by the rewrite without
        // ever being counted, and a file half written by a process killed mid-freeze is the ORDINARY case
        // here rather than a rare one (L211, L105). The count is reported rather than a bare flag, because
        // how many lines are unreadable is what somebody would act on.
        guard read.unreadableLines == 0 else {
            return .refused(unreadableLines: read.unreadableLines)
        }

        let result = pruned(read.records, now: now, retentionDays: retentionDays)
        guard result.dropped > 0 else { return .nothingToRemove }

        // Atomically, so a failed write leaves the archive as it was rather than half of it. And the result
        // is only reported as a drop once the write has actually happened: saying records were removed when
        // the write failed would be a report of a deletion nobody performed, which is the mirror of the
        // silence this whole issue is about (L12).
        let text = result.records.compactMap(line(for:)).joined(separator: "\n")
        let payload = result.records.isEmpty ? "" : text + "\n"
        guard (try? payload.write(to: archive, atomically: true, encoding: .utf8)) != nil else {
            return .nothingToRemove
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
        case archived(count: Int)
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
        let compaction = compact(at: url, cap: cap)
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
    static func compact(at url: URL, cap: Int = fileCap) -> CompactionOutcome {
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
        let text = result.records.compactMap(line(for:)).joined(separator: "\n") + "\n"
        // The archive already holds these records, so a failed rewrite here leaves them in BOTH files rather
        // than in neither: nothing is lost, and the live file is simply still over its cap until the next
        // launch tries again. So the write's result is deliberately not branched on. Written as a guard
        // first, with both arms returning the same value, which is a decision that decides nothing and is
        // worse than no guard because it reads as one (L260).
        _ = try? text.write(to: url, atomically: true, encoding: .utf8)
        return .archived(count: result.dropped)
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
