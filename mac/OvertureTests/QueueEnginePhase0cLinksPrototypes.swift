import Foundation
import SwiftData

// #4106 plan v7, Phase 0c probes 0c.1 (T1 ShowLink) and 0c.2 (T2 ContradictedCancellation, T3 feed breaks):
// the TEST ONLY prototypes of each term's patchable value (plan section 7), kept apart from the harness
// that proves them (`QueueEnginePhase0cLinksProbeTests`) so a mutation aimed at a prototype line cannot land
// in the harness.
//
// NOT PRODUCT CODE, and never a patch path. Nothing under `mac/Overture/` calls any of this; Phase 3 and
// Phase 4b build the product types. Each prototype is proved against its canonical oracle
// (`CanonicalOracle`, Step T0) after every operation and every undo, never against itself (L70).
//
// Where a prototype needs a rule the production type keeps `private`, it RESTATES it from the production
// type's public pieces, exactly as 0b.1 did: ShowLink's night set and poisoned token name, and the two
// venue folds ContradictedCancellation and FeedBreakEvent each keep privately. A drift between a restated
// rule and the private one is precisely what the oracle comparison exists to catch.

/// The key every prototype indexes by: a row's `persistentModelID`, never `naturalKey` (which re-keys and
/// merges reassign) and never `Recipient.id` (a shared email). `probe` is a row the cost arm plants for one
/// operation and removes again, which has no persistent identity because it is never saved.
enum Phase0cKey: Hashable {
    case row(PersistentIdentifier)
    case probe(Int)
}

// MARK: - T1: ShowLink.group and ShowLink.collapse, patched

/// Plan section 7 T1: `bucket -> [PID]`, per bucket the clusters with fronts and hidden sets,
/// `(token, venue) -> [folded title: count]`, `token -> Set<PID>`, and the poisoned set. `apply` returns
/// ChangedKeys, which includes every key whose `hidden` state flipped (T7's membership hand-off).
struct Phase0cShowLinkPatch<Key: Hashable> {

    /// Everything the rule reads from one row, folded ONCE (the RowFacts slice for this term).
    struct Facts: Equatable {
        var id: String
        var title: String
        var venue: String
        var nights: Set<String>
        var tokens: Set<String>
        var stillInFeed: Bool
        var opening: String
        var drawn: Bool

        var bucket: String { title + "|" + venue }

        init(_ row: ShowLink.Row, drawn: Bool) {
            id = row.id
            title = ShowLink.foldedTitle(row.groupName)
            venue = ShowLink.foldedVenue(row.venue)
            nights = Self.nights(of: row)
            tokens = Set(row.sourceURLs.compactMap(ProductionToken.inURL))
            stillInFeed = row.isStillInFeed
            opening = row.performanceDate ?? ""
            self.drawn = drawn
        }

        // ShowLink's private `nights(of:)`, restated: listed nights united with dropped ones, else the span.
        static func nights(of row: ShowLink.Row) -> Set<String> {
            let listed = Set(row.runNights).union(row.droppedNights)
            if !listed.isEmpty { return listed }
            guard let opening = row.performanceDate else { return [] }
            guard let closing = row.runEndDate else { return [opening] }
            return Set(EasternDate.days(from: opening, through: closing))
        }
    }

    /// What one key contributes to the published outputs. Absent means a row standing alone.
    struct Entry: Equatable {
        var id: String
        var group: [String]?
        var front: [String]?
        var hidden: Bool
    }

    struct Result {
        var changed: Set<Key> = []
        var hiddenFlips: Set<Key> = []
        var bucketsRebuilt = 0
        var rowsReevaluated = 0
    }

    private(set) var facts: [Key: Facts] = [:]
    private var members: [String: Set<Key>] = [:]
    private var titlesAtPair: [String: [String: Int]] = [:]
    private var poisonedPairs: Set<String> = []
    private var poisonRefs: [String: Int] = [:]
    private var holders: [String: Set<Key>] = [:]
    private var builtKeys: [String: [Key]] = [:]
    private var entryOf: [Key: Entry] = [:]

    // The published outputs, in the oracle's own shape.
    private(set) var group: [String: [String]] = [:]
    private(set) var fronts: [String: [String]] = [:]
    private(set) var hidden: Set<String> = []

    init() {}

    var bucketKeys: [String: Set<Key>] { members }

    func isPoisoned(_ token: String) -> Bool { (poisonRefs[token] ?? 0) > 0 }

    var allTokens: Set<String> { Set(holders.keys) }

    func holdersOf(_ token: String) -> Set<Key> { holders[token] ?? [] }

    // The oracle names a poisoned token by cutting its `token|venue` pair at the LAST bar, so this does too.
    static func poisonName(_ pair: String) -> String {
        String(pair.prefix(upTo: pair.range(of: "|", options: .backwards)?.lowerBound ?? pair.endIndex))
    }

    mutating func apply(_ changes: [(key: Key, facts: Facts?)]) -> Result {
        var touchedBuckets: Set<String> = []
        var touchedPairs: Set<String> = []
        for change in changes {
            if let old = facts[change.key] {
                touchedBuckets.insert(old.bucket) // phase0c-t1: rebuild the OLD bucket on a move
                members[old.bucket]?.remove(change.key)
                if members[old.bucket]?.isEmpty == true { members[old.bucket] = nil }
                for token in old.tokens {
                    holders[token]?.remove(change.key)
                    if holders[token]?.isEmpty == true { holders[token] = nil }
                    let pair = token + "|" + old.venue
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
                    let pair = token + "|" + new.venue
                    titlesAtPair[pair, default: [:]][new.title, default: 0] += 1
                    touchedPairs.insert(pair)
                }
            }
        }
        // A pair gaining or losing its second title can flip its token's poisoned state, which changes the
        // joins of every bucket holding that token, at any venue.
        var flipped: Set<String> = []
        for pair in touchedPairs {
            let nowPoisoned = (titlesAtPair[pair]?.count ?? 0) > 1
            guard nowPoisoned != poisonedPairs.contains(pair) else { continue }
            let name = Self.poisonName(pair)
            let before = isPoisoned(name)
            if nowPoisoned {
                poisonedPairs.insert(pair)
                poisonRefs[name, default: 0] += 1
            } else {
                poisonedPairs.remove(pair)
                let left = (poisonRefs[name] ?? 0) - 1
                poisonRefs[name] = left > 0 ? left : nil
            }
            if before != isPoisoned(name) { flipped.insert(name) }
        }
        for token in flipped {
            for key in holders[token] ?? [] {
                if let one = facts[key] { touchedBuckets.insert(one.bucket) }
            }
        }

        // Every removal before any build, so a key re-keyed onto another key's old id cannot be erased by
        // the other bucket's removal.
        var before: [Key: Entry] = [:]
        for bucket in touchedBuckets {
            for key in builtKeys[bucket] ?? [] {
                guard let entry = entryOf[key] else { continue }
                if group[entry.id] == entry.group { group[entry.id] = nil }
                if entry.front != nil, fronts[entry.id] == entry.front { fronts[entry.id] = nil }
                if entry.hidden { hidden.remove(entry.id) }
                if before[key] == nil { before[key] = entry }
                entryOf[key] = nil
            }
            builtKeys[bucket] = nil
        }
        var result = Result()
        for bucket in touchedBuckets {
            let built = build(bucket)
            result.bucketsRebuilt += 1
            result.rowsReevaluated += members[bucket]?.count ?? 0
            builtKeys[bucket] = built.map { $0.key }
            for (key, entry) in built {
                entryOf[key] = entry
                if let g = entry.group { group[entry.id] = g }
                if let f = entry.front { fronts[entry.id] = f }
                if entry.hidden { hidden.insert(entry.id) }
            }
        }
        var candidates = Set(before.keys)
        for bucket in touchedBuckets { candidates.formUnion(members[bucket] ?? []) }
        for key in candidates {
            let was = before[key]
            let now = entryOf[key]
            if (was?.hidden ?? false) != (now?.hidden ?? false) { result.hiddenFlips.insert(key) }
            if was?.group != now?.group || was?.front != now?.front || was?.hidden != now?.hidden
                || (was != nil && now != nil && was?.id != now?.id) {
                result.changed.insert(key)
            }
        }
        result.changed.formUnion(changes.map { $0.key })
        result.changed.formUnion(result.hiddenFlips)
        return result
    }

    // One bucket, clustered from scratch over its pre-folded rows: at most the bucket's size squared pair
    // tests, independent of N.
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
            let ids = indices.map { rows[$0].facts.id }
            let ordered = indices.sorted { l, r in
                let left = rows[l].facts, right = rows[r].facts
                if left.stillInFeed != right.stillInFeed { return left.stillInFeed }
                if left.opening != right.opening { return left.opening < right.opening }
                return left.id < right.id
            }
            let present = ordered.filter { rows[$0].facts.drawn }
            let front = present.first
            let hiddenSet = Set(present.dropFirst())
            for i in indices {
                let id = rows[i].facts.id
                out.append((key: rows[i].key,
                            entry: Entry(id: id,
                                         group: ids.filter { $0 != id },
                                         front: i == front ? ids : nil,
                                         hidden: hiddenSet.contains(i))))
            }
        }
        return out
    }
}

// MARK: - T2: ContradictedCancellation, patched

/// Plan section 7 T2: `room -> (live, flagged)`, `twins[flagged] -> Set<live>`, contradicted = flagged with
/// a nonempty twin set. `apply` returns the keys whose contradicted state flipped, which T3 consumes.
struct Phase0cContradictionPatch<Key: Hashable> {

    struct Facts: Equatable {
        var id: String
        var room: String
        var missed: Int
        var start: String?
        var end: String?
        var title: String

        var live: Bool { missed == 0 }
        var flagged: Bool { missed >= FeedReconcile.goneThreshold }

        init(_ p: Prospect) {
            id = p.naturalKey
            room = Self.room(p.venue)
            missed = p.missedScoutCount
            start = p.performanceDate
            end = p.runEndDate
            title = p.groupName
        }

        // ContradictedCancellation's private `canonicalVenue`, restated: blank is the venueless room "".
        static func room(_ raw: String?) -> String {
            guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
            return VenueNormalization.normalizeForKey(raw)
        }
    }

    struct Result {
        var flips: Set<Key> = []
        var changed: Set<Key> = []
        var tests = 0
    }

    private(set) var facts: [Key: Facts] = [:]
    private(set) var live: [String: Set<Key>] = [:]
    private(set) var flagged: [String: Set<Key>] = [:]
    private var twins: [Key: Set<Key>] = [:]
    private(set) var contradicted: Set<Key> = []

    init() {}

    var contradictedIDs: Set<String> { Set(contradicted.compactMap { facts[$0]?.id }) }

    var rooms: Set<String> { Set(live.keys).union(flagged.keys) }

    func twinCount(_ key: Key) -> Int { twins[key]?.count ?? 0 }

    // The two arms `contradictedKeys` asks inside a room, in its argument order.
    static func isTwin(_ candidate: Facts, of flagged: Facts) -> Bool {
        ScoutService.runsOverlap(storedStart: candidate.start, storedEnd: candidate.end,
                                 incomingStart: flagged.start, incomingEnd: flagged.end)
            && GroupNameMatch.isSameShowTitle(candidate.title, flagged.title)
    }

    mutating func apply(_ changes: [(key: Key, facts: Facts?)]) -> Result {
        var was: [Key: Bool] = [:]
        func note(_ key: Key) { if was[key] == nil { was[key] = contradicted.contains(key) } }
        func refresh(_ key: Key) {
            if facts[key]?.flagged == true, !(twins[key] ?? []).isEmpty {
                contradicted.insert(key)
            } else {
                contradicted.remove(key)
            }
        }
        var result = Result()
        for change in changes {
            let key = change.key
            note(key)
            if let old = facts[key] {
                if old.live {
                    let oldRoomFlagged = flagged[old.room] ?? [] // phase0c-t2: the OLD room's flagged rows
                    for f in oldRoomFlagged where twins[f]?.contains(key) == true {
                        note(f)
                        twins[f]?.remove(key)
                        refresh(f)
                    }
                }
                if old.flagged { twins[key] = nil }
                live[old.room]?.remove(key)
                if live[old.room]?.isEmpty == true { live[old.room] = nil }
                flagged[old.room]?.remove(key)
                if flagged[old.room]?.isEmpty == true { flagged[old.room] = nil }
            }
            facts[key] = change.facts
            if let new = change.facts {
                if new.live {
                    live[new.room, default: []].insert(key)
                    for f in flagged[new.room] ?? [] where f != key {
                        result.tests += 1
                        guard let other = facts[f], Self.isTwin(new, of: other) else { continue }
                        note(f)
                        twins[f, default: []].insert(key)
                        refresh(f)
                    }
                }
                if new.flagged {
                    flagged[new.room, default: []].insert(key)
                    var found: Set<Key> = []
                    for l in live[new.room] ?? [] where l != key {
                        result.tests += 1
                        if let candidate = facts[l], Self.isTwin(candidate, of: new) { found.insert(l) }
                    }
                    twins[key] = found.isEmpty ? nil : found
                }
            }
            refresh(key)
        }
        for (key, before) in was where before != contradicted.contains(key) { result.flips.insert(key) }
        result.changed = result.flips.union(changes.map { $0.key })
        return result
    }
}

// MARK: - T3: FeedBreakEvent.events, patched

/// Plan section 7 T3: `bucket -> Set<PID>` of flagged rows (every date; the clock filters at build), events
/// rebuilt for touched buckets only, and each row's validUntil is the Eastern midnight after its last night,
/// held as a `lastNight -> Set<PID>` index so a clock move rebuilds only the buckets it crosses.
struct Phase0cFeedBreakPatch<Key: Hashable> {

    struct Facts: Equatable {
        var id: String
        var venueKey: String
        var label: String
        var missed: Int
        var lastNight: String
        var flagged: Bool

        var bucket: String { venueKey + "|" + String(missed) }

        init(_ p: Prospect) {
            id = p.naturalKey
            // FeedBreakEvent's private `canonicalVenue`, restated (it lowercases; T2's does not).
            venueKey = VenueNormalization.normalizeForKey(p.venue ?? "").lowercased()
            label = p.venue ?? ""
            missed = p.missedScoutCount
            lastNight = max(p.performanceDate ?? "", p.runEndDate ?? "")
            flagged = p.disappearedFromFeed
        }
    }

    private(set) var asOf: String
    private var facts: [Key: Facts] = [:]
    private(set) var buckets: [String: Set<Key>] = [:]
    private var byLastNight: [String: Set<Key>] = [:]
    private var covered: Set<Key> = []
    private var events: [String: FeedBreakEvent.Event] = [:]

    init(asOf: String) { self.asOf = asOf }

    /// The deterministic order this probe compares in, stated in the PR because FeedBreakEvent's own full
    /// ties fall back to Dictionary iteration (Step T0): member count descending, then venue label, then
    /// miss count, then first member key.
    static func ordered(_ events: [FeedBreakEvent.Event]) -> [FeedBreakEvent.Event] {
        events.sorted { l, r in
            if l.memberKeys.count != r.memberKeys.count { return l.memberKeys.count > r.memberKeys.count }
            if l.venue != r.venue { return l.venue < r.venue }
            if l.missedScoutCount != r.missedScoutCount { return l.missedScoutCount < r.missedScoutCount }
            return (l.memberKeys.first ?? "") < (r.memberKeys.first ?? "")
        }
    }

    var output: [FeedBreakEvent.Event] { Self.ordered(Array(events.values)) }

    /// Flagged rows whose last night is on or after `asOf`, by bucket: the population every real bucket key
    /// of this term is drawn from.
    var futureBuckets: [String: [Key]] {
        var out: [String: [Key]] = [:]
        for (bucket, keys) in buckets {
            let future = keys.filter { (facts[$0]?.lastNight ?? "") >= asOf }
            if !future.isEmpty { out[bucket] = Array(future) }
        }
        return out
    }

    func factsOf(_ key: Key) -> Facts? { facts[key] }

    /// `coveredFlips` is T2's hand-off: each key whose contradicted state flipped, with its new state.
    @discardableResult
    mutating func apply(_ changes: [(key: Key, facts: Facts?)], coveredFlips: [Key: Bool]) -> Int {
        var touchedBuckets: Set<String> = []
        for change in changes {
            if let old = facts[change.key] {
                touchedBuckets.insert(old.bucket)
                buckets[old.bucket]?.remove(change.key)
                if buckets[old.bucket]?.isEmpty == true { buckets[old.bucket] = nil }
                byLastNight[old.lastNight]?.remove(change.key)
                if byLastNight[old.lastNight]?.isEmpty == true { byLastNight[old.lastNight] = nil }
            }
            let new = change.facts.flatMap { $0.flagged ? $0 : nil }
            facts[change.key] = new
            if let new {
                touchedBuckets.insert(new.bucket)
                buckets[new.bucket, default: []].insert(change.key)
                byLastNight[new.lastNight, default: []].insert(change.key)
            }
        }
        for (key, isCovered) in coveredFlips {
            if isCovered { covered.insert(key) } else { covered.remove(key) }
            if let one = facts[key] { touchedBuckets.insert(one.bucket) } // phase0c-t3: covered count on a twin flip
        }
        for bucket in touchedBuckets { rebuild(bucket) }
        return touchedBuckets.count
    }

    /// The clock moving, in either direction: only buckets holding a row whose last night lies between the
    /// two instants are rebuilt.
    @discardableResult
    mutating func advance(to newAsOf: String) -> Int {
        guard newAsOf != asOf else { return 0 }
        let low = min(asOf, newAsOf), high = max(asOf, newAsOf)
        asOf = newAsOf
        var touchedBuckets: Set<String> = []
        for (night, keys) in byLastNight where night >= low && night < high {
            for key in keys { if let one = facts[key] { touchedBuckets.insert(one.bucket) } }
        }
        for bucket in touchedBuckets { rebuild(bucket) }
        return touchedBuckets.count
    }

    private mutating func rebuild(_ bucket: String) {
        let members = (buckets[bucket] ?? []).compactMap { key in facts[key].map { (key: key, facts: $0) } }
            .filter { $0.facts.lastNight >= asOf }
            .sorted { $0.facts.id < $1.facts.id }
        guard members.count >= FeedBreakEvent.minimumMembers, let first = members.first else {
            events[bucket] = nil
            return
        }
        events[bucket] = FeedBreakEvent.Event(venue: first.facts.label,
                                              missedScoutCount: first.facts.missed,
                                              memberKeys: members.map { $0.facts.id },
                                              coveredByAnotherCard: members.filter { covered.contains($0.key) }.count)
    }
}
