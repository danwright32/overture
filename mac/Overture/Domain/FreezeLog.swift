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

    // What the reader has told Dan about already. Session-independent, on `RunBoundaryViolations`'s
    // precedent and for its reason: a freeze recorded in a session that then crashed still has to be said
    // the next time Overture opens.
    static let reportedThroughKey = "freezesReportedThroughSequence"

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

    // Appended rather than rewritten, so a write during a freeze cannot lose what is already there and
    // cannot be a read-modify-write whose read failing erases the record (L105).
    @discardableResult
    static func append(_ record: StallRecord, to url: URL) -> Bool {
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
