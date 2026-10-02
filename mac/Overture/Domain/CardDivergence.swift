import Foundation

// #3654 step 4c: the app checks its own narrowing, on every pass, and says so when it is wrong.
//
// WHY THE SUITE IS NOT ENOUGH. #3654's hard constraint is that the result is verified continuously in the
// suite AND cheaply re-checked in the running app, so a divergence reports itself loudly rather than Dan
// noticing a wrong row. This repository has already paid for the other shape: `QueueRenderCounter` counts
// whole-store derivations and draws a number on screen, and it sat there for months while the app froze,
// because nothing read it and nothing alerted on it (L357).
//
// WHAT IS COMPARED. One sampled card the pass built, against the same card rebuilt through the shipping
// `QueueModel.card` with its contacts read again. That catches a stale contacts array, a card left over
// from an earlier pass, and a key resolved to the wrong show. It does NOT catch a wrong whole-corpus
// table, because both sides would read the same one: that is `NarrowedCardsAgreeWithFullOnesTests`'s
// question and it is asked against a full build, which is too expensive to do per render.
//
// ==========================================================================================
// WHAT A RECORD CARRIES, which is CORRECTION C7's question and is answered here rather than left
// to be discovered. Dan's call, 2026-09-08, choosing this over a record that names the show.
//
// It carries NO show identity and NO contact value. Only the NAMES of the fields that differed, how many
// cards the pass had built, and which stage was on screen.
//
// The names are constants of this app. Everything else that could go in a record is somebody's: a
// contact's name, address, greeting or draft body obviously, and the show's own key nearly as much,
// because a natural key is built from the group name and Dan's queue is full of shows billed as one
// performer's own name. That is precisely the identity class #2839, #3110 and #3140 have each already
// paid to scrub out of this repository.
//
// This file is NOT in the repository, which is what makes it the harder case rather than the easier one:
// a privacy guard that scans the tree cannot see what the running app writes beside the store, so the
// only defence is not putting it there (L222). `StallRecord.surface` is the same decision one file over,
// where a closed enum with no associated values makes a show's name impossible to write rather than
// forbidden.
//
// WHAT IS GIVEN UP, stated so nobody has to rediscover it: a divergence cannot be traced to one show from
// this file. That is the right trade, because the finding this exists to make is a CLASS defect. The
// narrowing is either sound for every card or unsound for a kind of card, and the field names say which
// kind. Nothing here is a per-show fault Dan would go and fix.
// ==========================================================================================
struct CardDivergenceRecord: Codable, Equatable, Sendable {
    // The process this was recorded in, so a record is identified by its session AND its sequence.
    // `FreezeLog` records why the sequence alone is not an identity: it restarts at 1 in every launch,
    // so a reader remembering a bare number goes silent on every later session (L186).
    let session: String
    let sequence: Int
    let at: Date
    // The fields that differed, sorted, so two records of the same defect are the same text.
    let fields: [String]
    // How many cards the pass had built when this was found. A divergence on a pass of twenty is the
    // ordinary narrowed case; one on a pass that built everything says something different.
    let cardsBuilt: Int
    let stage: String?
    // #4354 (plan v7 D8): WHICH check wrote this, and on behalf of which change source. Both are CLOSED
    // enums with no associated values, on `StallRecord.surface`'s precedent, so a show's name has nowhere
    // to go rather than being forbidden (C7, L222). Absent on every record written before this shipped,
    // all of which the card check wrote, so an absent kind reads as `.cardDivergence` and an absent source
    // as nil (L133).
    let kind: Kind
    let source: Source?
    // How many repeats of this record's (kind, source) its cooldown held back since the previous record of
    // that pair was written. Zero for a card divergence, which has no cooldown.
    let suppressedRepeats: Int

    var identity: String { "\(session)#\(sequence)" }

    init(session: String, sequence: Int, at: Date, fields: [String], cardsBuilt: Int, stage: String?,
         kind: Kind = .cardDivergence, source: Source? = nil, suppressedRepeats: Int = 0) {
        self.session = session
        self.sequence = sequence
        self.at = at
        self.fields = fields
        self.cardsBuilt = cardsBuilt
        self.stage = stage
        self.kind = kind
        self.source = source
        self.suppressedRepeats = suppressedRepeats
    }

    // #4354: the kinds this log holds. Only `.cardDivergence` has a writer today (`QueueView.recordCardCheck`).
    // `.noOpDirty` and `.factMismatch` are the queue engine's, activated by #4358 (plan v7 Phase 4 plus 5),
    // named here because the compaction and cooldown rules below have to hold for them before the first
    // one is written, which is the order the plan requires (L191). Each later verifier kind joins this
    // list in the PR that writes it.
    enum Kind: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
        case cardDivergence
        case noOpDirty
        case factMismatch
        // Written by nobody: what a spelling this build does not know DECODES to, because a later build
        // wrote it. Kept as a record rather than failing the whole line (L255, `StallRecord`'s rule).
        case unrecognised

        // Every kind but the card check waits ten minutes per (kind, source) before writing again. The card
        // check keeps today's none: its reader counts records as wrong CARDS, so a suppressed repeat would
        // read as a card nobody built wrongly. An exhaustive switch, so a new kind has to choose.
        var cooldown: TimeInterval {
            switch self {
            case .cardDivergence: return 0
            case .noOpDirty, .factMismatch, .unrecognised: return 600
            }
        }
    }

    // #4354: the change source a record is about. Written by nobody today; the engine's intake (#4358)
    // names the source of each change it judges. Closed for the same privacy reason as `Kind`.
    enum Source: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
        case reconcile
        case scoutLanding
        case unrecognised
    }

    private enum CodingKeys: String, CodingKey {
        case session, sequence, at, fields, cardsBuilt, stage, kind, source, suppressedRepeats
    }

    // Decoded by hand so an ABSENT kind is a card divergence and an UNKNOWN one is `.unrecognised`:
    // decoding the enum directly throws on a spelling it does not know, which fails the whole line.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decode(String.self, forKey: .session)
        sequence = try c.decode(Int.self, forKey: .sequence)
        at = try c.decode(Date.self, forKey: .at)
        fields = try c.decode([String].self, forKey: .fields)
        cardsBuilt = try c.decode(Int.self, forKey: .cardsBuilt)
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
            .map { Kind(rawValue: $0) ?? .unrecognised } ?? .cardDivergence
        source = try c.decodeIfPresent(String.self, forKey: .source).map { Source(rawValue: $0) ?? .unrecognised }
        suppressedRepeats = try c.decodeIfPresent(Int.self, forKey: .suppressedRepeats) ?? 0
    }

    // #4354: what compaction and the archive prune count as "the same kind of record". The FIELDS alone
    // used to be the key, so every record naming no field shared one key and a card divergence and a fact
    // mismatch naming the same field were one (plan v7 D8, L191).
    struct CompactionKey: Hashable, Sendable {
        let kind: Kind
        let source: Source?
        let fields: [String]
    }

    var compactionKey: CompactionKey { CompactionKey(kind: kind, source: source, fields: fields) }

    // A kind or source this build could not name, which only a later build writes.
    var isFromALaterBuild: Bool { kind == .unrecognised || source == .unrecognised }
}

// The file, and the rules for reading, capping and appending it. Modelled on `FreezeLog` deliberately:
// same shape, same pinned date strategy, same three-way read, and a row in `docs/contracts.md` with it.
//
// It is its OWN file and does not join `freeze-log.ndjson`, which #3654 spells out and which is worth
// keeping written down. That file is bounded and compacted by STALL LENGTH, so a record carrying no
// duration cannot be protected by its rule while still consuming its cap, which is exactly the cheap
// writer L191 describes evicting the expensive observation. Its single reader also says each entry to Dan
// as the app having stopped responding, and a divergence announced in the vocabulary of a freeze is one
// word naming two units (L118) and a message claiming what its check never measured (L11).
enum CardDivergenceLog {
    // copy-inventory:ignore-start  a filename, not a sentence Overture says
    static let fileName = "card-divergence.ndjson"
    // copy-inventory:ignore-end

    static func url(in support: URL) -> URL { support.appendingPathComponent(fileName) }

    static let reportedIdsKey = "cardDivergencesReportedIdentities"

    // #3654 CORRECTION C2: that the check RAN, which an empty file cannot say.
    //
    // Without this, an empty file means all three of "every sample agreed", "nothing was ever sampled"
    // and "the check never executed", and the emptiest possible failure would read as the cleanest
    // possible result (L98, L557). A monitor that has never once passed is not measuring anything.
    //
    // A STAMP rather than a count, and throttled to once a minute by `CardDivergenceReport.shouldStamp`.
    // The check runs on every render pass, and a defaults write per render is a cost on the exact path
    // this milestone exists to make cheap. What has to be answerable is only whether anything has ever
    // looked, which a stamp answers as well as a count and more usefully: a date says WHEN.
    static let lastRanKey = "cardCheckLastRanAt"
    // Said once per install and not once per launch. A notice carrying no action, delivered every time,
    // teaches a person to skip the whole surface.
    static let neverRanSaidKey = "cardCheckNeverRanSaid"

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

    static func line(for record: CardDivergenceRecord) -> String? {
        guard let data = try? encoder().encode(record),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    struct Read: Equatable, Sendable {
        var records: [CardDivergenceRecord] = []
        // #4398: the lines this build could not decode, VERBATIM, rather than only how many. A count is
        // enough to report a loss and not enough to prevent one: `compact` rewrites this file, and a line
        // it holds no copy of is a line the rewrite destroys. The count is derived from these, so the two
        // can never disagree (L53).
        var unreadable: [String] = []
        var fileWasAbsent: Bool = false
        var unreadableLines: Int { unreadable.count }
    }

    static func read(_ text: String) -> Read {
        var out = Read()
        let decoder = decoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(CardDivergenceRecord.self, from: data) else {
                out.unreadable.append(String(line))
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

    static let fileCap = 200

    // What survives compaction.
    //
    // The rule is KEEP ONE OF EACH DISTINCT KEY, then the newest, and it is not `FreezeLog`'s rule
    // wearing different words. There the reading the file exists for is the MAXIMUM, so the longest stall
    // is protected. Here the reading is WHICH KINDS of divergence have happened, and a cap by count lets a
    // common one evict the rare one: a thousand records of the same field set would flush out the single
    // record naming a different one, and the count would say some were dropped but never that the only
    // example of a kind was among them (L191, L63). #4354: the key is (kind, source, fields), never the
    // fields alone, which let every record naming no field share one key.
    // #3811: what a compaction KEEPS and what it took out, on `FreezeLog.Compacted`'s shape exactly.
    //
    // `droppedRecords` is what this type did not carry before, and its absence is why `compact` could only
    // ever delete: it counted what it was throwing away without holding it, so there was nothing to
    // archive even if somebody had wanted to. The count is DERIVED from the records rather than stored
    // beside them, so a report cannot describe a different set from the one actually removed (L53).
    struct Compacted: Equatable, Sendable {
        var records: [CardDivergenceRecord]
        var droppedRecords: [CardDivergenceRecord] = []
        var dropped: Int { droppedRecords.count }
    }

    // #3811: where a compaction puts what it would otherwise have discarded.
    //
    // Derived from the LIVE url rather than taken as a parameter, on `FreezeLog.archiveURL`'s precedent
    // and for its reason: no caller can compact without archiving, because a behaviour every call site has
    // to opt into is enforced by nothing (L621).
    static let archiveFileName = "card-divergence-archive.ndjson"

    static func archiveURL(besideLogAt url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(archiveFileName)
    }

    // What a compaction did, as ONE value rather than a count.
    //
    // A bare `Int` could not tell "nothing was over the cap" from "the archive write failed so nothing was
    // trimmed", and those are a healthy hour and one needing attention (L11). That is what `compact`
    // returned before this issue, and it is the reason the caller had nothing to report even once it had
    // one.
    enum CompactionOutcome: Equatable, Sendable {
        case nothingToArchive
        // #4398: `keptUnreadable` is how many lines the compaction could not decode and therefore carried
        // through to the rewritten live file verbatim. Its own number, because a compaction that met only
        // records and one that met a torn append are different facts about the file (L11).
        case archived(count: Int, keptUnreadable: Int = 0)
        // The archive could not be written, so the live file was deliberately left OVER its cap rather
        // than trimmed.
        case archiveFailed
        // #4354: the file holds records a LATER build wrote, whose kind or source this build reads as
        // `.unrecognised`. Rewriting it would re-encode each as "unrecognised", losing the spelling for
        // good, and would key every such record as one. So it is left untouched, over its cap if need be,
        // until a build that knows those spellings runs (L650, L1013).
        case refusedUnrecognised(records: Int)
    }

    static func compacted(_ records: [CardDivergenceRecord], cap: Int = fileCap) -> Compacted {
        guard records.count > cap else { return Compacted(records: records) }
        let keptKinds = Set(records.suffix(cap).map(\.compactionKey))
        // The OLDEST example of each kind the newest window has lost, which is the one that would
        // otherwise disappear entirely. Held as POSITIONS (see below).
        var rescued: Set<Int> = []
        var seen = keptKinds
        for index in records.indices {
            if seen.insert(records[index].compactionKey).inserted { rescued.insert(index) }
        }
        // #3811: the dropped set is WORKED OUT rather than counted, because the archive needs the records
        // themselves.
        //
        // #4398: and worked out in POSITIONS rather than identities, on `FreezeLog.compacted`'s precedent
        // (#3763). The identity form left out of the dropped list EVERY copy of an identity the kept list
        // held once, so a record written twice whose older copy fell outside the newest window was in
        // neither file after a compaction. Each position is now kept or dropped, exactly once. The rescued
        // records take the oldest slots of the newest window, so the file stays at its cap.
        let newestStart = min(records.count, records.count - cap + rescued.count)
        var kept: [CardDivergenceRecord] = []
        var dropped: [CardDivergenceRecord] = []
        for index in records.indices {
            if rescued.contains(index) || index >= newestStart {
                kept.append(records[index])
            } else {
                dropped.append(records[index])
            }
        }
        return Compacted(records: kept, droppedRecords: dropped)
    }

    // #3811: ARCHIVE, then truncate, and NEVER delete.
    //
    // WHAT THIS USED TO DO AND WHY THAT WAS NOT A SMALL THING. It rewrote the live file with the kept
    // records and returned a count, so the dropped ones were gone. `docs/contracts.md` said the file was
    // "COMPACTED AT LAUNCH", and the rule it describes is not a plain cap: it keeps one example of each
    // distinct FIELD SET (since #4354, of each distinct kind, source and field set) so a common divergence
    // cannot evict the only record of a rare one, which is the
    // reading the file exists for. That rule had never run once, because `compact` had no caller anywhere
    // in the app. Wiring it up as it stood would have started permanently deleting divergence records for
    // the first time, which is a decision rather than a side effect of fixing a missing call (L5).
    //
    // The freeze log settled the same question in #3763 and this follows it: a compaction was the last
    // anyone ever saw of those records, so what it drops is archived beside the live file rather than
    // discarded.
    //
    // ORDER IS THE WHOLE SAFEGUARD, as it is there. These two writes have no transaction around them, so
    // the archive is written FIRST and the truncation is abandoned if it failed. Doing the destructive
    // half first would leave a failed archive indistinguishable from a clean compaction, with the records
    // already gone.
    @discardableResult
    static func compact(at url: URL, cap: Int = fileCap) -> CompactionOutcome {
        let read = read(at: url)
        guard !read.fileWasAbsent else { return .nothingToArchive }
        // Nothing to rewrite is quiet whatever the file holds: the refusal below is for a REWRITE (L11).
        guard read.records.count > cap else { return .nothingToArchive }
        let unrecognised = read.records.filter(\.isFromALaterBuild).count
        guard unrecognised == 0 else { return .refusedUnrecognised(records: unrecognised) }
        let result = compacted(read.records, cap: cap)
        guard result.dropped > 0 else { return .nothingToArchive }
        guard archive(result.droppedRecords, besideLogAt: url) else { return .archiveFailed }
        // #4398: every line the read could NOT decode is carried through VERBATIM, at the head of the
        // rewritten file. Rewriting from the decoded records alone destroyed them: a torn append, or a
        // record a later build wrote in a shape this one cannot parse, was in neither the live file nor
        // the archive afterwards and nothing counted it, while `pruneArchive` refuses outright on the same
        // condition (L211, L5). Kept in the LIVE file rather than moved to the archive, because the
        // archive's prune refuses on an unreadable line, so one moved there would stop the archive ever
        // being bounded again. At the head, because each is older than anything appended after this.
        let text = (read.unreadable + result.records.compactMap(line(for:))).joined(separator: "\n") + "\n"
        // The archive already holds these records, so a failed rewrite leaves them in BOTH files rather
        // than in neither: nothing is lost, and the live file is simply still over its cap until the next
        // tick tries again. The write's result is deliberately not branched on, for `FreezeLog.compact`'s
        // stated reason: a guard whose arms return the same value decides nothing and reads as if it does
        // (L260).
        _ = try? text.write(to: url, atomically: true, encoding: .utf8)
        return .archived(count: result.dropped, keptUnreadable: read.unreadable.count)
    }

    // MARK: - #3811: what bounds the archive

    // What a prune of the archive keeps, and what it took out.
    struct ArchivePruned: Equatable, Sendable {
        var records: [CardDivergenceRecord]
        var droppedRecords: [CardDivergenceRecord] = []
        var dropped: Int { droppedRecords.count }
    }

    enum ArchivePrune: Equatable, Sendable {
        case nothingToRemove
        case removed(count: Int)
        // The archive held lines this version cannot decode, so it was left alone rather than rewritten
        // from a partial read. A rewrite would destroy every line the read could not parse without ever
        // counting it, and a file half written by a process killed mid-append is the ordinary case here
        // rather than a rare one (L211, L105).
        case refused(unreadableLines: Int)
        // #4354: the same refusal as the live file's, for the same reason.
        case refusedUnrecognised(records: Int)
    }

    // ONE EXAMPLE OF EACH DISTINCT KEY (#4354: kind, source and field set), and NOT a retention window,
    // which is where this deliberately
    // parts from `FreezeLog`'s archive.
    //
    // The freeze archive keeps a month, and its own comment explains that this is safe because the reading
    // it supports is the MAXIMUM, which the live file protects separately and never drops. The reading
    // THIS file supports is WHICH KINDS of divergence have ever happened, so an age-based prune would
    // delete exactly the rare kind the compaction rescued, a month after it was rescued, which is the
    // defect this log's compaction rule exists to prevent arriving through its own retention (L387, L191).
    //
    // Bounded by kind rather than by time or count, so the archive can never exceed the number of distinct
    // keys the app can produce, which is closed enums times a combination of card fields and therefore
    // small. The
    // OLDEST example of each kind is the one kept, because the first time a kind appeared is the fact
    // worth having.
    static func prunedArchive(_ records: [CardDivergenceRecord]) -> ArchivePruned {
        var seen: Set<CardDivergenceRecord.CompactionKey> = []
        var kept: [CardDivergenceRecord] = []
        var dropped: [CardDivergenceRecord] = []
        for record in records {
            if seen.insert(record.compactionKey).inserted {
                kept.append(record)
            } else {
                dropped.append(record)
            }
        }
        return ArchivePruned(records: kept, droppedRecords: dropped)
    }

    static func pruneArchive(besideLogAt url: URL) -> ArchivePrune {
        let archive = archiveURL(besideLogAt: url)
        let read = read(at: archive)
        // No archive is the ordinary state: most installs have never compacted. Nothing to report.
        guard !read.fileWasAbsent else { return .nothingToRemove }
        guard read.unreadableLines == 0 else { return .refused(unreadableLines: read.unreadableLines) }
        // Worked out first, so an archive with nothing to remove is quiet whatever it holds: the refusal
        // below is for a REWRITE (L11). A later build's records all share the unrecognised key, so they
        // can make a drop appear here, which is exactly when the refusal must win.
        let result = prunedArchive(read.records)
        guard result.dropped > 0 else { return .nothingToRemove }
        let unrecognised = read.records.filter(\.isFromALaterBuild).count
        guard unrecognised == 0 else { return ArchivePrune.refusedUnrecognised(records: unrecognised) }

        // Atomically, and reported as a removal only once the write has actually happened: saying records
        // were removed when the write failed is a report of a deletion nobody performed (L12).
        let text = result.records.compactMap(line(for:)).joined(separator: "\n")
        let payload = result.records.isEmpty ? "" : text + "\n"
        guard (try? payload.write(to: archive, atomically: true, encoding: .utf8)) != nil else {
            return .nothingToRemove
        }
        return .removed(count: result.dropped)
    }

    // Everything one tick's bookkeeping did, in one value, so the caller reports all of it or none.
    struct Housekeeping: Equatable, Sendable {
        var compaction: CompactionOutcome = .nothingToArchive
        var prune: ArchivePrune = .nothingToRemove
        var isQuiet: Bool { compaction == .nothingToArchive && prune == .nothingToRemove }
    }

    // COMPACT THEN PRUNE, in that order, on `FreezeLog.housekeeping`'s precedent and for its reason:
    // compacting can CREATE the archive this prune then bounds, so pruning first would leave whatever the
    // compaction just wrote unbounded until the next tick.
    //
    // ONE entry point rather than a compact call and a prune call, because a caller that can do one and
    // forget the other will eventually do exactly that (L621). That is not hypothetical here: the reason
    // this issue exists is that `compact` had no caller at all.
    static func housekeeping(at url: URL, cap: Int = fileCap) -> Housekeeping {
        let compaction = compact(at: url, cap: cap)
        let prune = pruneArchive(besideLogAt: url)
        return Housekeeping(compaction: compaction, prune: prune)
    }

    // #3811: every dropped record into the archive, in ONE write, answering whether ALL of them landed.
    //
    // A record that will not ENCODE counts as a failure rather than being quietly skipped: a `compactMap`
    // here would drop it from the archive and then let the truncation proceed, which is the exact loss
    // this guard exists to prevent, arriving through the guard itself (L387).
    static func archive(_ records: [CardDivergenceRecord], besideLogAt url: URL) -> Bool {
        guard !records.isEmpty else { return true }
        let lines = records.compactMap(line(for:))
        guard lines.count == records.count else { return false }
        return appending(lines.joined(separator: "\n") + "\n", to: archiveURL(besideLogAt: url))
    }

    // Appended rather than rewritten, on `FreezeLog.append`'s reasoning: a read, modify, write whose read
    // fails erases the record at exactly the moment it is worth having (L105).
    //
    // #4354: REFUSES a kind that has a cooldown, so a writer of one cannot skip it by calling the plain
    // form (L621). Those go through `append(_:to:through:)`.
    @discardableResult
    static func append(_ record: CardDivergenceRecord, to url: URL) -> Bool {
        guard record.kind.cooldown == 0 else { return false }
        return write(record, to: url)
    }

    // #4354: the cooled form. Writes the record, carrying the repeats its window held back, or counts it as
    // a repeat and writes nothing. Returns whether a line was written.
    @discardableResult
    static func append(_ record: CardDivergenceRecord, to url: URL, through cooldown: inout Cooldown) -> Bool {
        // Admitted on a copy and committed only once the line is written: a failed write that still opened
        // the window would suppress every repeat for its length and lose the count it carried (L368).
        var proposed = cooldown
        switch proposed.admit(kind: record.kind, source: record.source, at: record.at) {
        case .suppressed:
            cooldown = proposed
            return false
        case .write(let suppressedRepeats):
            let carried = CardDivergenceRecord(session: record.session, sequence: record.sequence, at: record.at,
                                               fields: record.fields, cardsBuilt: record.cardsBuilt,
                                               stage: record.stage, kind: record.kind, source: record.source,
                                               suppressedRepeats: suppressedRepeats)
            guard write(carried, to: url) else { return false }
            cooldown = proposed
            return true
        }
    }

    private static func write(_ record: CardDivergenceRecord, to url: URL) -> Bool {
        guard let line = line(for: record) else { return false }
        return appending(line + "\n", to: url)
    }

    // #4354 (plan v7 D8): a per (kind, source) window during which repeats are COUNTED rather than written,
    // so a cheap check firing on every pass cannot flood the file and evict the rare record (L191, L36).
    //
    // The first record of a pair is written at once, so a crash inside the window loses a count and never
    // the record. Repeats inside the window only increment a count. The next record written after the
    // window ends carries that count as `suppressedRepeats`, and a window that ends with nothing after it
    // is handed back by `drainEnded` so its count is written rather than lost to a quiet period (L710).
    //
    // In memory, owned by whichever writer holds it; the engine's verifier is that owner (#4358), and its
    // hourly tick is where `drainEnded` is called. Pure, so every outcome is produced by a test rather
    // than watched not to happen (L151).
    struct Cooldown: Equatable, Sendable {
        struct Key: Hashable, Sendable {
            let kind: CardDivergenceRecord.Kind
            let source: CardDivergenceRecord.Source?
        }

        struct Held: Equatable, Sendable {
            let kind: CardDivergenceRecord.Kind
            let source: CardDivergenceRecord.Source?
            let suppressedRepeats: Int
        }

        enum Admission: Equatable, Sendable {
            case write(suppressedRepeats: Int)
            case suppressed
        }

        private struct Window: Equatable, Sendable {
            let openedAt: Date
            var suppressed: Int
        }

        private var windows: [Key: Window] = [:]

        init() {}

        mutating func admit(kind: CardDivergenceRecord.Kind, source: CardDivergenceRecord.Source?,
                            at now: Date) -> Admission {
            let interval = kind.cooldown
            guard interval > 0 else { return .write(suppressedRepeats: 0) }
            let key = Key(kind: kind, source: source)
            // Inside the window only while `now` is at or after it opened: a clock set backwards must not
            // hold a window open for ever (L74).
            if let open = windows[key], now >= open.openedAt, now.timeIntervalSince(open.openedAt) < interval {
                windows[key]?.suppressed += 1
                return .suppressed
            }
            let carried = windows[key]?.suppressed ?? 0
            windows[key] = Window(openedAt: now, suppressed: 0)
            return .write(suppressedRepeats: carried)
        }

        // Every window that has ENDED still holding repeats, handed back once and cleared, sorted so two
        // runs over the same state say the same thing.
        mutating func drainEnded(at now: Date) -> [Held] {
            var out: [Held] = []
            for (key, open) in windows where open.suppressed > 0 {
                guard now < open.openedAt || now.timeIntervalSince(open.openedAt) >= key.kind.cooldown else { continue }
                out.append(Held(kind: key.kind, source: key.source, suppressedRepeats: open.suppressed))
                windows[key] = nil
            }
            return out.sorted { ($0.kind.rawValue, $0.source?.rawValue ?? "") < ($1.kind.rawValue, $1.source?.rawValue ?? "") }
        }
    }

    // #3811: the one place either the live file or the archive is written to, so the archive cannot
    // acquire a different durability story from the log by being written somewhere else (L263). Lifted
    // out of `append` rather than copied into `archive`, which is what made this an extraction rather
    // than a second implementation.
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
