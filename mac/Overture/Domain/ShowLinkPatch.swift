import Foundation

// #4360 (plan v7 Phase 4b(a), discussion #4267 section 7 T1): ShowLink's grouping and collapse as a PATCHABLE VALUE,
// which the queue engine keeps between passes and brings up to date from the shows that changed, in place of
// recomputing both over the whole store on every pass.
//
// WHAT IT HOLDS (the plan's shape). Each row's slice of facts, folded once (`Facts`, from `RowKeys`); `bucket -> keys`;
// per bucket, what it last built (each member's group list, front list and hidden state); `(token, venue) -> folded
// title -> count`; `token -> keys`; and the poisoned pairs. The published answer is `tables`, in exactly the shape
// `ShowLink.tables(among:drawn:)` gives, so the pass reads either without knowing which.
//
// THE NEIGHBOURHOOD, from the rule in `ShowLink.swift`. A change to one row can change: its old bucket and its new one
// (the folded scout title and venue); every bucket holding a token whose poisoned state the change flipped (a pair of
// token and folded venue gaining or losing its second folded title); its cluster's front (`missedScoutCount == 0`,
// the opening night, the natural key); and the hidden set (whether the queue draws it). So `apply` rebuilds the
// touched buckets from their pre-folded rows, each at most its size squared pair tests, independent of the store's
// size. A poison flip rebuilds every bucket holding the token, which is the plan's measured worst case (0c.1).
//
// WHY THE RULE IS RESTATED HERE (L70). The join (a shared night, or a shared token nothing poisoned), the transitive
// closure and the front's order are written again below rather than called, because ShowLink's own functions are
// this value's ORACLE: `PatchableShowLinkTests`, the engine's whole pass harness and the verifier's comparison
// (`QueueEnginePatches.mismatches(against:)`) each hold this to `ShowLink.group` and `ShowLink.collapse` over the same
// rows, and a patch built on the oracle's own code could only ever agree with it. The keys it buckets and poisons by
// ARE shared (`ShowLink.bucketKey`, `poisonKey`, `unscoped`), since a key spelled twice is a second place to drift
// with nothing to gain (L370).

/// T1's patchable value, keyed by a row identity the caller chooses: the engine's `PersistentIdentifier`, never the
/// natural key (re-keys and merges reassign it) and never a contact's address.
struct PatchableShowLink<Key: Hashable & Sendable>: Sendable {

    /// Everything the rule reads from one row, folded once.
    struct Facts: Equatable, Sendable {
        /// The id the tables are keyed by: the row's natural key, as `ShowLink.Row.id` is.
        var id: String
        var title: String
        var venue: String
        var nights: Set<String>
        var tokens: Set<String>
        /// The front's order: a row the feed still lists, then the earliest opening night, then the id.
        var stillInFeed: Bool
        var opening: String
        /// Whether the queue draws the row, which is what a front may be chosen from (`ShowLink.collapse`'s `drawn`).
        var drawn: Bool

        var bucket: String { ShowLink.bucketKey(title: title, venue: venue) }

        init(id: String, title: String, venue: String, nights: Set<String>, tokens: Set<String>, stillInFeed: Bool,
             opening: String, drawn: Bool) {
            self.id = id
            self.title = title
            self.venue = venue
            self.nights = nights
            self.tokens = tokens
            self.stillInFeed = stillInFeed
            self.opening = opening
            self.drawn = drawn
        }

        /// One row's slice, from the folds `RowKeys` took once (`ShowLink.Row`'s own fields, folded as the rule
        /// folds them, which `RowKeysMatchTheTermsTests` holds), and drawn as the queue's own scope draws it.
        init(of row: some ProspectFacts) {
            let keys = row.foldedKeys
            self.init(id: row.naturalKey, title: keys.showLinkTitle, venue: keys.showLinkVenue,
                      nights: keys.showLinkNights, tokens: keys.productionTokens,
                      stillInFeed: row.missedScoutCount == 0, opening: row.performanceDate ?? "",
                      drawn: QueueModel.isInQueueScope(row))
        }
    }

    /// What one row contributes to the tables. Absent for a row standing alone.
    private struct Entry: Equatable, Sendable {
        var id: String
        var group: [String]
        var front: [String]?
        var hidden: Bool
    }

    /// What one `apply` changed (the plan's ChangedKeys): every key whose answer moved, and among them every key whose
    /// HIDDEN state flipped, which is T7's membership hand-off once T7 is patched (#4363). Today the pass rebuilds the
    /// rows from `tables` on every pass, so the engine reads only the counts, for its cost record.
    struct Changed: Equatable, Sendable {
        var keys: Set<Key> = []
        var hiddenFlips: Set<Key> = []
        var bucketsRebuilt = 0
        var rowsReevaluated = 0
    }

    private var facts: [Key: Facts] = [:]
    private var members: [String: Set<Key>] = [:]
    private var titlesAtPair: [String: [String: Int]] = [:]
    private var poisonedPairs: Set<String> = []
    /// How many poisoned pairs name each token: a token is poisoned while any pair naming it is.
    private var poisonRefs: [String: Int] = [:]
    private var holders: [String: Set<Key>] = [:]
    private var builtKeys: [String: [Key]] = [:]
    private var entryOf: [Key: Entry] = [:]

    /// The published answer, in `ShowLink.tables(among:drawn:)`'s shape.
    private(set) var tables = ShowLink.Tables()

    /// Every row, built from nothing: one `apply` of every row, so each bucket is built once.
    init(rows: [(key: Key, facts: Facts)]) {
        apply(rows.map { (key: $0.key, facts: Optional($0.facts)) })
    }

    /// Brings the value up to `changes`: each key's new slice, or nil for a row that is gone. Returns what changed.
    @discardableResult
    mutating func apply(_ changes: [(key: Key, facts: Facts?)]) -> Changed {
        var touchedBuckets: Set<String> = []
        var touchedPairs: Set<String> = []
        for change in changes {
            if let old = facts[change.key] {
                // The bucket a row LEAVES is rebuilt too: its remaining rows may have been joined only through it.
                touchedBuckets.insert(old.bucket)
                members[old.bucket]?.remove(change.key)
                if members[old.bucket]?.isEmpty == true { members[old.bucket] = nil }
                for token in old.tokens {
                    holders[token]?.remove(change.key)
                    if holders[token]?.isEmpty == true { holders[token] = nil }
                    let pair = ShowLink.poisonKey(token: token, venue: old.venue)
                    let left = (titlesAtPair[pair]?[old.title] ?? 0) - 1
                    titlesAtPair[pair]?[old.title] = left > 0 ? left : nil
                    if titlesAtPair[pair]?.isEmpty == true { titlesAtPair[pair] = nil }
                    touchedPairs.insert(pair)
                }
            }
            facts[change.key] = change.facts
            if let new = change.facts {
                touchedBuckets.insert(new.bucket)
                members[new.bucket, default: []].insert(change.key)
                for token in new.tokens {
                    holders[token, default: []].insert(change.key)
                    let pair = ShowLink.poisonKey(token: token, venue: new.venue)
                    titlesAtPair[pair, default: [:]][new.title, default: 0] += 1
                    touchedPairs.insert(pair)
                }
            }
        }
        // A pair gaining or losing its second folded title flips its token's poisoned state, which changes the joins
        // of every bucket holding that token, at any venue.
        var flipped: Set<String> = []
        for pair in touchedPairs {
            let nowPoisoned = (titlesAtPair[pair]?.count ?? 0) > 1
            guard nowPoisoned != poisonedPairs.contains(pair) else { continue }
            let token = ShowLink.unscoped(pair)
            let before = isPoisoned(token)
            if nowPoisoned {
                poisonedPairs.insert(pair)
                poisonRefs[token, default: 0] += 1
            } else {
                poisonedPairs.remove(pair)
                let left = (poisonRefs[token] ?? 0) - 1
                poisonRefs[token] = left > 0 ? left : nil
            }
            if before != isPoisoned(token) { flipped.insert(token) }
        }
        for token in flipped {
            for key in holders[token] ?? [] {
                if let one = facts[key] { touchedBuckets.insert(one.bucket) }
            }
        }

        // Every removal before any build, so a row re-keyed onto an id another bucket held a moment ago cannot be
        // erased by that other bucket's removal.
        var before: [Key: Entry] = [:]
        for bucket in touchedBuckets {
            for key in builtKeys[bucket] ?? [] {
                guard let entry = entryOf[key] else { continue }
                if tables.group[entry.id] == entry.group { tables.group[entry.id] = nil }
                if let front = entry.front, tables.fronts[entry.id] == front { tables.fronts[entry.id] = nil }
                if entry.hidden { tables.hidden.remove(entry.id) }
                if before[key] == nil { before[key] = entry }
                entryOf[key] = nil
            }
            builtKeys[bucket] = nil
        }
        var changed = Changed()
        for bucket in touchedBuckets {
            let built = build(bucket)
            changed.bucketsRebuilt += 1
            changed.rowsReevaluated += members[bucket]?.count ?? 0
            builtKeys[bucket] = built.isEmpty ? nil : built.map { $0.key }
            for (key, entry) in built {
                entryOf[key] = entry
                tables.group[entry.id] = entry.group
                if let front = entry.front { tables.fronts[entry.id] = front }
                if entry.hidden { tables.hidden.insert(entry.id) }
            }
        }
        var candidates = Set(before.keys)
        for bucket in touchedBuckets { candidates.formUnion(members[bucket] ?? []) }
        for key in candidates {
            let was = before[key]
            let now = entryOf[key]
            if (was?.hidden ?? false) != (now?.hidden ?? false) { changed.hiddenFlips.insert(key) }
            if was != now { changed.keys.insert(key) }
        }
        changed.keys.formUnion(changes.map { $0.key })
        return changed
    }

    private func isPoisoned(_ token: String) -> Bool { (poisonRefs[token] ?? 0) > 0 }

    /// One bucket, clustered from nothing over its pre-folded rows: at most the bucket's size squared pair tests.
    private func build(_ bucket: String) -> [(key: Key, entry: Entry)] {
        guard let keys = members[bucket], keys.count > 1 else { return [] }
        let rows = keys.compactMap { key in facts[key].map { (key: key, facts: $0) } }
            .sorted { $0.facts.id < $1.facts.id }
        let usable = rows.map { $0.facts.tokens.filter { !isPoisoned($0) } }
        var parent = Array(rows.indices)
        func root(_ i: Int) -> Int {
            var current = i
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }
        for i in rows.indices {
            for j in rows.indices where j > i {
                let joined = !rows[i].facts.nights.isDisjoint(with: rows[j].facts.nights)
                    || !usable[i].isDisjoint(with: usable[j])
                if joined {
                    let a = root(i), b = root(j)
                    if a != b { parent[max(a, b)] = min(a, b) }
                }
            }
        }
        var clusters: [Int: [Int]] = [:]
        for i in rows.indices { clusters[root(i), default: []].append(i) }
        var out: [(key: Key, entry: Entry)] = []
        for indices in clusters.values where indices.count > 1 {
            // Members in id order, as `ShowLink`'s clusters are (#4344); the front by the collapse's own order.
            let ids = indices.map { rows[$0].facts.id }
            let ordered = indices.sorted { l, r in
                let left = rows[l].facts, right = rows[r].facts
                if left.stillInFeed != right.stillInFeed { return left.stillInFeed }
                if left.opening != right.opening { return left.opening < right.opening }
                return left.id < right.id
            }
            let present = ordered.filter { rows[$0].facts.drawn }
            let front = present.first
            let hidden = Set(present.dropFirst())
            for i in indices {
                let id = rows[i].facts.id
                out.append((key: rows[i].key,
                            entry: Entry(id: id, group: ids.filter { $0 != id }, front: i == front ? ids : nil,
                                         hidden: hidden.contains(i))))
            }
        }
        return out
    }
}
