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

    var identity: String { "\(session)#\(sequence)" }
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
        var unreadableLines: Int = 0
        var fileWasAbsent: Bool = false
    }

    static func read(_ text: String) -> Read {
        var out = Read()
        let decoder = decoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(CardDivergenceRecord.self, from: data) else {
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

    static let fileCap = 200

    // What survives compaction.
    //
    // The rule is KEEP ONE OF EACH DISTINCT FIELD SET, then the newest, and it is not `FreezeLog`'s rule
    // wearing different words. There the reading the file exists for is the MAXIMUM, so the longest stall
    // is protected. Here the reading is WHICH KINDS of divergence have happened, and a cap by count lets a
    // common one evict the rare one: a thousand records of the same field set would flush out the single
    // record naming a different one, and the count would say some were dropped but never that the only
    // example of a kind was among them (L191, L63).
    struct Compacted: Equatable, Sendable {
        var records: [CardDivergenceRecord]
        var dropped: Int
    }

    static func compacted(_ records: [CardDivergenceRecord], cap: Int = fileCap) -> Compacted {
        guard records.count > cap else { return Compacted(records: records, dropped: 0) }
        let newest = Array(records.suffix(cap))
        let keptKinds = Set(newest.map { $0.fields.joined(separator: "|") })
        // The OLDEST example of each kind the newest window has lost, which is the one that would
        // otherwise disappear entirely.
        var rescued: [CardDivergenceRecord] = []
        var seen = keptKinds
        for record in records {
            let kind = record.fields.joined(separator: "|")
            if seen.insert(kind).inserted { rescued.append(record) }
        }
        guard !rescued.isEmpty else { return Compacted(records: newest, dropped: records.count - cap) }
        // Rescuing must not grow the file past its cap, so the rescued records take the oldest slots:
        // they ARE the oldest things worth keeping.
        let kept = rescued + newest.dropFirst(rescued.count)
        return Compacted(records: kept, dropped: records.count - cap)
    }

    @discardableResult
    static func compact(at url: URL, cap: Int = fileCap) -> Int {
        let read = read(at: url)
        guard !read.fileWasAbsent else { return 0 }
        let result = compacted(read.records, cap: cap)
        guard result.dropped > 0 else { return 0 }
        let text = result.records.compactMap(line(for:)).joined(separator: "\n") + "\n"
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return 0 }
        return result.dropped
    }

    // Appended rather than rewritten, on `FreezeLog.append`'s reasoning: a read, modify, write whose read
    // fails erases the record at exactly the moment it is worth having (L105).
    @discardableResult
    static func append(_ record: CardDivergenceRecord, to url: URL) -> Bool {
        guard let line = line(for: record), let data = (line + "\n").data(using: .utf8) else { return false }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return false }
            do { try handle.write(contentsOf: data) } catch { return false }
            return true
        }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
