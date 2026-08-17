import Foundation

// #1606: what a show's natural key USED to be, so work in flight when a launch rewrites keys can still
// find the row it was about.
//
// A reachability check is paid for in Opus tokens and takes about two and a half minutes a show. Its
// marker holds natural keys, and so does the results file the detached runner writes. A launch-time rekey
// (`NaturalKeyVenueMigration`) rewrote `Prospect.naturalKey` with no record of the old value, so after it
// BOTH sides were stale in the same way and the settle's intersection matched nothing: the answer was
// lost, the show went back to looking unchecked, and Dan paid for it again. Silent by construction,
// because nothing reports a settle that matched zero rows.
//
// #1594's part 1.4 proposed carrying a second identifier on the marker. That could not have worked: the
// results file is stale in exactly the same way, so both ends needed translating, not one. Recording the
// rename instead is the durable version and the standing rule: when a key must change, record the
// old-to-new mapping for everything still holding the old one (L15).
struct NaturalKeyRemap: Codable, Equatable, Sendable {

    struct Entry: Codable, Equatable, Sendable {
        var from: String
        var to: String
        var at: Date
    }

    var entries: [Entry]

    // How long a rename can still matter. A run in flight is minutes, not days; this is generous because
    // what it protects is a paid run, and because a Mac asleep mid-run can stretch the gap a long way.
    static let keepFor: TimeInterval = 7 * 24 * 60 * 60

    /// Where a key has ended up, following a chain of renames. A key nothing renamed answers with itself,
    /// which is what lets every caller translate unconditionally instead of branching.
    func current(_ key: String) -> String {
        var seen: Set<String> = [key]
        var here = key
        // Bounded by the number of entries, and by `seen`, so a cycle terminates instead of hanging a
        // settle. A migration that only ever folds toward a canonical key cannot produce one, which is
        // exactly why the guard is worth having: it is invisible until something upstream changes, and it
        // is the difference between a wrong answer and a frozen app.
        while let next = entries.last(where: { $0.from == here })?.to, !seen.contains(next) {
            seen.insert(next)
            here = next
        }
        return here
    }

    func pruned(now: Date) -> NaturalKeyRemap {
        NaturalKeyRemap(entries: entries.filter { now.timeIntervalSince($0.at) <= Self.keepFor })
    }

    // MARK: - On disk

    static var defaultURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("natural-key-remap.json")
    }

    func write(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    // Nothing on disk is not an error, and neither is an unreadable file. Every caller translates through
    // this, so a first launch, or a file a future version wrote differently, has to read as "no renames"
    // rather than as a failure that stops a settle from happening at all.
    static func read(from url: URL = defaultURL) throws -> NaturalKeyRemap {
        // #2879: the ANSWER is unchanged, deliberately (no renames, so a settle still happens), but the
        // read no longer passes silently: an unreadable rename map means shows keyed under an old name
        // will not be found, which is worth knowing about.
        return HandoffFile.read(at: url) {
            try JSONDecoder().decode(NaturalKeyRemap.self, from: $0)
        }.value ?? NaturalKeyRemap(entries: [])
    }

    /// Adds renames to whatever is already recorded, dropping any that can no longer matter.
    static func record(_ renames: [(from: String, to: String)], at when: Date,
                       url: URL = defaultURL) throws {
        guard !renames.isEmpty else { return }
        let existing = (try? read(from: url)) ?? NaturalKeyRemap(entries: [])
        let added = renames.map { Entry(from: $0.from, to: $0.to, at: when) }
        try NaturalKeyRemap(entries: existing.entries + added).pruned(now: when).write(to: url)
    }
}
