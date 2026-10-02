import Foundation
import SwiftData

// #4331 (A2 of #4275's plan, discussion #4326 revision 5): `ingestedAt` is stamped only when a scout
// landing actually CHANGED the row, except where a merge reader still needs it to mean LAST SEEN.
//
// WHY. A re-land of an unchanged feed used to restamp every row it listed (`existing.ingestedAt = Date()`),
// so every such row was dirtied, carried by the next save and announced to every observer of it, for no
// change at all. Measured under #4106 (plan v7 0b.6): 124.3 ms for 229 rows at 1,344 shows and 499.5 ms for
// 907 rows at 5,376, the whole of the residue `ScoutReLandWritesNothingTests` allowed.
//
// THE STAMP is the landing's own `now` plus the row's apply ordinal within the landing, in microseconds
// (`at(_:ordinal:)`), never `Date()` and never the day the run scores against (`scoutNow`, which is Eastern
// midnight and would date every row earlier than one stamped by hand the same day). So two rows one landing
// stamps still read in the order the landing applied them, which is the order `Date()` used to give them
// (L419), and a test that pins `now` pins the stamp.
//
// THE MERGE READERS, and the exception they force (decided 2026-09-29 on #4331). Four readers pick a
// survivor among rows the scout lists twice by the freshest or oldest `ingestedAt`, and three of them say in
// as many words that the value means LAST SEEN: `ScoutService.theOnlyRowThisMayReKey`, `DriftedRunMerge`,
// `NaturalKeyVenueMigration` and `SameNightTitleVariantMerge`. Under "stamped only when changed" a duplicate
// that is still listed and unchanged keeps an old stamp, while a stale twin that last changed later reads as
// fresher, and the merge keeps the hidden card and deletes the visible one. No answer derived from a
// source's landings can order two rows of ONE source, and that is every pair these readers resolve. So a row
// that shares a candidate key of any of those readers with another stored row is restamped on every touch,
// exactly as before, and only every OTHER row is stamped when it changed. `MergeCandidateIndex` answers which
// rows those are, from the readers' own grouping keys, taken wider than any reader takes them, so it can
// restamp a row no merge would compare but never leave one unstamped that a merge would.
//
// The question is asked twice for a row the landing touched and did not change: when it is touched (so a
// reader running inside the landing, `theOnlyRowThisMayReKey`, sees the stamp it always saw), and again at
// the end of every later source's apply for the rows a later write may have given a twin, with the stamp the
// row would have taken when it was touched. What it cannot see is a twin made by something other than the
// scout (Dan renaming a show onto another one's billing, say): two rows that were unique at every landing and
// then became one show's two cards order by when each last CHANGED. Stated in #4331's PR as the remaining gap.
enum IngestedAtStamp {
    // `whenChanged` is the rule. `everyTouch` is the rule this replaced (every row a landing touches is
    // restamped), kept as the REFERENCE the merge survivor probe compares against, so "the merges pick the
    // same survivor as before" is measured rather than asserted. No shipping caller uses it.
    enum Rule: Sendable { case whenChanged, everyTouch }

    // One microsecond per ordinal. A landing of 357 events applies a few hundred rows, so the whole spread is
    // well under a millisecond, and `Date` (a Double of seconds since 2001) resolves a microsecond at today's
    // magnitude with room to spare.
    static func at(_ now: Date, ordinal: Int) -> Date {
        now.addingTimeInterval(Double(ordinal) / 1_000_000)
    }
}

// #4331: which stored rows share a candidate key of a merge reader with ANOTHER stored row. See the header
// of this file for why that is the question.
//
// THE KEYS are derived from each reader's own grouping, and each is taken WIDER than the reader takes it,
// because the cost of a key too wide is a restamp and the cost of one too narrow is a merge that keeps the
// wrong card (L93, L648):
//   - `seriesId`: `theOnlyRowThisMayReKey`'s candidates, and `DriftedRunMerge`'s id groups without the venue.
//   - every production token in the listing and run URLs: `DriftedRunMerge`'s token groups, without the
//     venue and without the poison discard.
//   - the scout anchored key and the display key: `NaturalKeyVenueMigration.groupsOfOneShow`, which groups
//     by the first and combines groups sharing the second.
//   - the night, with `GroupNameMatch.isSameNightVariant` against any other row that night:
//     `SameNightTitleVariantMerge`'s clusters, compared pairwise rather than against a cluster's first row,
//     because which row is first is decided by `ingestedAt` itself.
// `MergeCandidateIndexTests` holds a pair of each kind, so a kind dropped from here goes red.
//
// The night test is the only one that is not a lookup, so it is narrowed first by a necessary condition of
// `isSameNightVariant`: two titles it accepts share a word, unless one of them is a single word (an acronym,
// or one word a typo apart).
@MainActor
final class MergeCandidateIndex {
    struct Keys: Equatable {
        let exact: [String]
        let night: String?
        let words: Set<String>
        let wordCount: Int
        let title: String
    }

    // The keys of one row. `tokens` is the row's production tokens as the landing has already folded them.
    static func keys(of p: Prospect, tokens: [String]) -> Keys {
        var exact: [String] = []
        if let id = p.seriesId, !id.isEmpty { exact.append("series " + id) }
        for token in Set(tokens) { exact.append("token " + token) }
        exact.append("anchor " + p.scoutAnchoredNaturalKey)
        exact.append("display " + Prospect.makeNaturalKey(groupName: p.groupName, performanceDate: p.performanceDate,
                                                          venue: p.venue))
        let night = p.performanceDate.flatMap { $0.isEmpty ? nil : $0 }
        let words = GroupNameMatch.tokens(p.groupName)
        return Keys(exact: exact, night: night, words: Set(words), wordCount: words.count, title: p.groupName)
    }

    private struct Entry {
        let row: Prospect
        var keys: Keys
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var exact: [String: Set<ObjectIdentifier>] = [:]
    private var nights: [String: Set<ObjectIdentifier>] = [:]
    // The buckets a row joined since the last time the deferred rows were looked at, with the rows that
    // joined them, so a deferred row is asked again only about a row that is new beside it.
    private(set) var joined: [String: Set<ObjectIdentifier>] = [:]

    init(rows: [Prospect], tokens: (Prospect) -> [String]) {
        for p in rows { add(p, keys: Self.keys(of: p, tokens: tokens(p)), noting: false) }
    }

    // A row that joined the working set, or whose fields may have changed. Re-keyed only where its keys moved.
    func update(_ p: Prospect, tokens: [String]) {
        let id = ObjectIdentifier(p)
        let fresh = Self.keys(of: p, tokens: tokens)
        if let old = entries[id] {
            guard old.keys != fresh else { return }
            remove(p)
        }
        add(p, keys: fresh, noting: true)
    }

    func remove(_ p: Prospect) {
        let id = ObjectIdentifier(p)
        guard let old = entries.removeValue(forKey: id) else { return }
        for key in old.keys.exact {
            exact[key]?.remove(id)
            if exact[key]?.isEmpty == true { exact[key] = nil }
        }
        if let night = old.keys.night {
            nights[night]?.remove(id)
            if nights[night]?.isEmpty == true { nights[night] = nil }
        }
    }

    private func add(_ p: Prospect, keys: Keys, noting: Bool) {
        let id = ObjectIdentifier(p)
        entries[id] = Entry(row: p, keys: keys)
        for key in keys.exact {
            exact[key, default: []].insert(id)
            if noting { joined[key, default: []].insert(id) }
        }
        if let night = keys.night {
            nights[night, default: []].insert(id)
            if noting { joined["night " + night, default: []].insert(id) }
        }
    }

    // Whether this row shares a candidate key with any other live row of the working set.
    func isContested(_ p: Prospect) -> Bool {
        guard let entry = entries[ObjectIdentifier(p)] else { return false }
        return isContested(entry, against: nil)
    }

    // The same question about the rows that joined beside it since `joined` was last emptied.
    func isContestedByARowThatJoined(_ p: Prospect) -> Bool {
        guard let entry = entries[ObjectIdentifier(p)] else { return false }
        var newcomers: Set<ObjectIdentifier> = []
        for key in entry.keys.exact { newcomers.formUnion(joined[key] ?? []) }
        if let night = entry.keys.night { newcomers.formUnion(joined["night " + night] ?? []) }
        // A row whose OWN keys moved has joined buckets whose older members are not newcomers to anybody else,
        // so it is asked the whole question.
        if newcomers.remove(ObjectIdentifier(p)) != nil { return isContested(entry, against: nil) }
        guard !newcomers.isEmpty else { return false }
        return isContested(entry, against: newcomers)
    }

    func forgetJoined() { joined = [:] }

    private func isContested(_ entry: Entry, against only: Set<ObjectIdentifier>?) -> Bool {
        let me = ObjectIdentifier(entry.row)
        func live(_ id: ObjectIdentifier) -> Bool {
            id != me && (only?.contains(id) ?? true) && entries[id].map { !$0.row.isDeleted } ?? false
        }
        for key in entry.keys.exact where (exact[key] ?? []).contains(where: live) { return true }
        guard let night = entry.keys.night else { return false }
        for id in nights[night] ?? [] where live(id) {
            guard let other = entries[id]?.keys else { continue }
            let mayMatch = entry.keys.wordCount == 1 || other.wordCount == 1
                || !entry.keys.words.isDisjoint(with: other.words)
            if mayMatch, GroupNameMatch.isSameNightVariant(entry.keys.title, other.title) { return true }
        }
        return false
    }
}
