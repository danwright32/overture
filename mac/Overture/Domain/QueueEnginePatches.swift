import Foundation
import SwiftData

// #4361 (plan v7 Phase 4b(b), discussion #4267 section 7): T2 ContradictedCancellation and T3 feed breaks as values
// the queue engine KEEPS between passes and patches from the rows a change touched, rather than terms the pass
// recomputes over the whole corpus every time.
//
// WHY. Before this, every engine pass asked `ContradictedCancellation.contradictedKeys(among:)` and
// `FeedBreakEvent.events(among:asOf:contradicted:)` over every show it holds, whatever changed. Both answers are
// about ROOMS: a flagged row is judged only against the live rows in its own room, and a feed break is a bucket of
// flagged rows sharing a room and a count. So a change to one row can move the answer only in that row's old and new
// room (T2) or bucket (T3), plus, through T2, the bucket of any row whose contradicted state it flipped, plus the
// clock for T3 (a row leaves a break after its last night).
//
// WHAT STAYS THE RULE. Neither patch restates the rule it patches (L370). The twin test is
// `ContradictedCancellation.isTwin`, the one predicate `liveTwin` and `contradictedKeys` ask; a row's room is the fold
// `RowKeys` took through each term's own `canonicalVenue`; and an event is built, labelled and ordered by
// `FeedBreakEvent.event(of:covered:)` and `FeedBreakEvent.ordered`, which `FeedBreakEvent.events` builds through too.
// What the patches own is only WHICH rooms and buckets to ask again, which is where a fault can hide, and what the
// engine's whole-pass comparison (the verifier's (iii)), the per-term verifier kind (`QueueEngineVerifier.compare`)
// and the property harnesses (`QueueEnginePatchedCancellationsTests`) each check against the unpatched terms.
//
// KEYED BY IDENTITY (plan section 4): every index is keyed by `persistentModelID`, never by natural key, which a
// merge or a rename reassigns. Natural keys appear only in what the pass is handed, read off each row's slice at
// that moment, so a rename is one slice change and never a stale key.

/// T2: `room -> (live, flagged)`, `twins[flagged] -> live`, and contradicted = flagged with a nonempty twin set.
struct QueueEnginePatchedContradictions: Equatable, Sendable {

    /// What T2 reads of one row: the key it answers in, the room, whether the feed lists it or has flagged it, and the
    /// three facts the twin test compares. Nothing else of the row can change T2's answer.
    struct Slice: Equatable, Sendable {
        let naturalKey: String
        let room: String
        let live: Bool
        let flagged: Bool
        let start: String?
        let end: String?
        let title: String

        init(_ row: some ProspectFacts) {
            naturalKey = row.naturalKey
            // `ContradictedCancellation.canonicalVenue(row.venue)`, taken once when the row was read (`RowKeys`).
            room = row.foldedKeys.contradictionRoom
            // The two arms `contradictedKeys` asks: a candidate twin must be one the feed lists, and the row judged
            // must be flagged. One row can be neither (missed once), never both.
            live = row.missedScoutCount == 0
            flagged = row.disappearedFromFeed
            start = row.performanceDate
            end = row.runEndDate
            title = row.groupName
        }

        /// Whether `other` can stand in every twin test this slice took part in: everything but the key. A change
        /// that moves nothing else (a rename, or a flagged row's count moving inside the flagged range, which is every
        /// scout accrual) re-tests nothing (#4106 0c.2 re-probe, which measured the accrual at 96% of T2's cost).
        func judgesAlike(_ other: Slice) -> Bool {
            room == other.room && live == other.live && flagged == other.flagged && start == other.start
                && end == other.end && title == other.title
        }
    }

    private(set) var slices: [PersistentIdentifier: Slice] = [:]
    private var live: [String: Set<PersistentIdentifier>] = [:]
    private var flagged: [String: Set<PersistentIdentifier>] = [:]
    private var twins: [PersistentIdentifier: Set<PersistentIdentifier>] = [:]
    private(set) var contradicted: Set<PersistentIdentifier> = []
    /// How many twin tests every change so far has made, so a test can hold a change to its room's size (plan
    /// section 15: rows re-evaluated per change independent of N).
    private(set) var tests = 0

    init() {}

    /// The flagged rows the corpus contradicts, by natural key: what `contradictedKeys(among:)` answers.
    var contradictedKeys: Set<String> { Set(contradicted.compactMap { slices[$0]?.naturalKey }) }

    /// Applies each change in turn (a row's new slice, or nil for a row gone) and returns the identities whose
    /// contradicted state flipped, which T3's covered counts read.
    @discardableResult
    mutating func apply(_ changes: [(id: PersistentIdentifier, slice: Slice?)]) -> Set<PersistentIdentifier> {
        var before: [PersistentIdentifier: Bool] = [:]
        func note(_ id: PersistentIdentifier) { if before[id] == nil { before[id] = contradicted.contains(id) } }
        for (id, new) in changes {
            let old = slices[id]
            if let old, let new, old.judgesAlike(new) {
                slices[id] = new
                continue
            }
            note(id)
            if let old {
                if old.live {
                    // The OLD room's flagged rows, each of which may have counted this row as its twin.
                    for f in flagged[old.room] ?? [] where twins[f]?.contains(id) == true { // patch-t2-old-room
                        note(f)
                        twins[f]?.remove(id)
                        if twins[f]?.isEmpty == true { twins[f] = nil }
                        refresh(f)
                    }
                }
                if old.flagged { twins[id] = nil }
                Self.remove(id, from: &live, at: old.room)
                Self.remove(id, from: &flagged, at: old.room)
            }
            slices[id] = new
            if let new {
                if new.live {
                    live[new.room, default: []].insert(id)
                    for f in flagged[new.room] ?? [] where f != id {
                        tests += 1
                        guard let judged = slices[f], Self.isTwin(new, of: judged) else { continue }
                        note(f)
                        twins[f, default: []].insert(id)
                        refresh(f)
                    }
                }
                if new.flagged {
                    flagged[new.room, default: []].insert(id)
                    var found: Set<PersistentIdentifier> = []
                    for l in live[new.room] ?? [] where l != id {
                        tests += 1
                        if let candidate = slices[l], Self.isTwin(candidate, of: new) { found.insert(l) }
                    }
                    twins[id] = found.isEmpty ? nil : found
                }
            }
            refresh(id)
        }
        return Set(before.filter { $0.value != contradicted.contains($0.key) }.keys)
    }

    private mutating func refresh(_ id: PersistentIdentifier) {
        if slices[id]?.flagged == true, twins[id]?.isEmpty == false {
            contradicted.insert(id)
        } else {
            contradicted.remove(id)
        }
    }

    /// The rule's own test, in `contradictedKeys`' argument order: `candidate` is the live row, `flagged` the judged.
    private static func isTwin(_ candidate: Slice, of flagged: Slice) -> Bool {
        ContradictedCancellation.isTwin(candidateStart: candidate.start, candidateEnd: candidate.end,
                                        candidateTitle: candidate.title, flaggedStart: flagged.start,
                                        flaggedEnd: flagged.end, flaggedTitle: flagged.title)
    }

    private static func remove(_ id: PersistentIdentifier, from index: inout [String: Set<PersistentIdentifier>],
                               at room: String) {
        guard index[room]?.remove(id) != nil, index[room]?.isEmpty == true else { return }
        index[room] = nil
    }
}

/// T3: `bucket -> flagged rows` (every date; the clock filters at build), the events of each bucket, and a
/// `lastNight -> rows` index so the clock moving rebuilds only the buckets holding a row it crossed.
struct QueueEnginePatchedFeedBreaks: Equatable, Sendable {

    /// What T3 reads of one FLAGGED row; an unflagged row has no slice and is in no bucket.
    struct Slice: Equatable, Sendable {
        let member: FeedBreakEvent.Member
        let bucket: String
        let lastNight: String

        init?(_ row: some ProspectFacts) {
            guard row.disappearedFromFeed else { return nil }
            member = FeedBreakEvent.Member(row)
            // `FeedBreakEvent.canonicalVenue(row.venue)`, taken once when the row was read (`RowKeys`).
            bucket = FeedBreakEvent.bucket(room: row.foldedKeys.feedBreakRoom, missed: row.missedScoutCount)
            lastNight = FeedBreakEvent.lastNight(of: row)
        }
    }

    /// The Eastern day the events are judged at: a row is a member only while its last night is on or after it.
    private(set) var asOf: String
    private var slices: [PersistentIdentifier: Slice] = [:]
    private var buckets: [String: Set<PersistentIdentifier>] = [:]
    private var byLastNight: [String: Set<PersistentIdentifier>] = [:]
    private var events: [String: FeedBreakEvent.Event] = [:]
    /// How many buckets every change so far rebuilt.
    private(set) var rebuilds = 0

    init(asOf: String) { self.asOf = asOf }

    /// Every break, in the product's own order.
    var output: [FeedBreakEvent.Event] { FeedBreakEvent.ordered(Array(events.values)) }

    /// Applies each change (a row's new slice, nil for a row unflagged or gone), then rebuilds every bucket a change
    /// touched and every bucket holding a row whose contradicted state flipped (its covered count, read from
    /// `covered`, T2's answer after the same changes).
    mutating func apply(_ changes: [(id: PersistentIdentifier, slice: Slice?)], flips: Set<PersistentIdentifier>,
                        covered: @autoclosure () -> Set<String>) {
        var touched: Set<String> = []
        for (id, new) in changes {
            let old = slices[id]
            guard old != new else { continue }
            if let old {
                touched.insert(old.bucket)
                Self.remove(id, from: &buckets, at: old.bucket)
                Self.remove(id, from: &byLastNight, at: old.lastNight)
            }
            slices[id] = new
            if let new {
                touched.insert(new.bucket)
                buckets[new.bucket, default: []].insert(id)
                byLastNight[new.lastNight, default: []].insert(id)
            }
        }
        for id in flips {
            if let one = slices[id] { touched.insert(one.bucket) } // patch-t3-covered-flip
        }
        guard !touched.isEmpty else { return }
        let coveredKeys = covered()
        for bucket in touched { rebuild(bucket, covered: coveredKeys) }
    }

    /// The day turning, in either direction: only the buckets holding a row whose last night lies between the two days
    /// are rebuilt, because no other row's membership changed.
    mutating func advance(to day: String, covered: @autoclosure () -> Set<String>) {
        guard day != asOf else { return }
        let low = min(asOf, day), high = max(asOf, day)
        asOf = day
        var touched: Set<String> = []
        for (night, ids) in byLastNight where night >= low && night < high {
            for id in ids { if let one = slices[id] { touched.insert(one.bucket) } }
        }
        guard !touched.isEmpty else { return }
        let coveredKeys = covered()
        for bucket in touched { rebuild(bucket, covered: coveredKeys) }
    }

    private mutating func rebuild(_ bucket: String, covered: Set<String>) {
        rebuilds += 1
        let members = (buckets[bucket] ?? []).compactMap { slices[$0] }.filter { $0.lastNight >= asOf }.map(\.member)
        events[bucket] = FeedBreakEvent.event(of: members, covered: covered)
    }

    private static func remove(_ id: PersistentIdentifier, from index: inout [String: Set<PersistentIdentifier>],
                               at key: String) {
        guard index[key]?.remove(id) != nil, index[key]?.isEmpty == true else { return }
        index[key] = nil
    }
}

/// What the engine hands its pass for T2 and T3, and the day it was judged at, so the pass can refuse a value
/// judged at a day that is not its own (`QueueEngineQueue.passInputs`).
struct QueueEnginePatchedValues: Equatable, Sendable {
    let contradicted: Set<String>
    let feedBreaks: [FeedBreakEvent.Event]
    let asOf: String

    /// The same two answers from the unpatched terms over every show, which is what each patched value must equal.
    /// The verifier's per-term comparison and every harness ask this, never the patches (L70).
    static func unpatched(_ shows: [some ProspectFacts], asOf: String) -> QueueEnginePatchedValues {
        let contradicted = ContradictedCancellation.contradictedKeys(among: shows)
        return QueueEnginePatchedValues(contradicted: contradicted,
                                        feedBreaks: FeedBreakEvent.events(among: shows, asOf: asOf, contradicted: nil),
                                        asOf: asOf)
    }

    /// The terms whose value differs from `other`'s, by name (C7: names, never values).
    func differingTerms(from other: QueueEnginePatchedValues) -> [QueueEnginePatchedTerm] {
        var out: [QueueEnginePatchedTerm] = []
        if contradicted != other.contradicted { out.append(.contradictions) }
        if feedBreaks != other.feedBreaks || asOf != other.asOf { out.append(.feedBreaks) }
        return out
    }
}

/// The terms the engine keeps patched, each with the verifier's record kind for it (plan section 4: one kind per term).
enum QueueEnginePatchedTerm: String, CaseIterable, Sendable {
    case contradictions
    case feedBreaks

    var mismatchKind: CardDivergenceRecord.Kind {
        switch self {
        case .contradictions: return .contradictionMismatch
        case .feedBreaks: return .feedBreakMismatch
        }
    }
}

/// T2 and T3 together, in the plan's dependency order (section 5: T3 reads T2): what the engine keeps beside its facts.
struct QueueEnginePatches: Equatable, Sendable {
    private(set) var contradictions = QueueEnginePatchedContradictions()
    private(set) var feedBreaks = QueueEnginePatchedFeedBreaks(asOf: "")

    init() {}

    /// Built cold from every show, judged at `asOf`.
    init(shows: [PersistentIdentifier: RowFacts], asOf: String) {
        feedBreaks = QueueEnginePatchedFeedBreaks(asOf: asOf)
        take(shows.map { ($0.key, $0.value) })
    }

    /// Each row's new value, or nil for a row gone, taken into T2 and then into T3 with T2's flips.
    mutating func take(_ rows: [(id: PersistentIdentifier, row: RowFacts?)]) {
        guard !rows.isEmpty else { return }
        let flips = contradictions.apply(rows.map { ($0.id, $0.row.map(QueueEnginePatchedContradictions.Slice.init)) })
        feedBreaks.apply(rows.map { ($0.id, $0.row.flatMap(QueueEnginePatchedFeedBreaks.Slice.init)) }, flips: flips,
                         covered: contradictions.contradictedKeys)
    }

    /// The resolve step (`QueueEngine.identityKeyedState`): a deleted row taken out, and a row whose temporary
    /// identifier a first save replaced moved to its permanent one, read from `shows` as it stands after the facts
    /// resolved.
    mutating func resolve(_ resolution: QueueEngineResolution, shows: [PersistentIdentifier: RowFacts]) {
        var rows: [(id: PersistentIdentifier, row: RowFacts?)] = []
        for id in resolution.deletedIDs where contradictions.slices[id] != nil { rows.append((id, nil)) }
        for (old, new) in resolution.rekeyedIDs where contradictions.slices[old] != nil {
            rows.append((old, nil))
            rows.append((new, shows[new]))
        }
        take(rows)
    }

    /// The day T3 is judged at, moved to `asOf`.
    mutating func advance(to asOf: String) {
        feedBreaks.advance(to: asOf, covered: contradictions.contradictedKeys)
    }

    /// What the pass is handed.
    var values: QueueEnginePatchedValues {
        QueueEnginePatchedValues(contradicted: contradictions.contradictedKeys, feedBreaks: feedBreaks.output,
                                 asOf: feedBreaks.asOf)
    }
}
