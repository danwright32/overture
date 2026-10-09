import Foundation

// #4364 (plan v7 Phase 4b(e), discussion #4267 section 7 T5): the organisation answer ledger (`QueueModel.inheritedAnswers`,
// which applies the refusals and then `OrgAnswerLedger.inherited`) as a PATCHABLE VALUE, which the queue engine keeps
// between passes and brings up to date from what changed, in place of re-deciding every show on every pass. #4623
// measured the term at 26.3 ms at 4x in an optimised build.
//
// WHAT IT HOLDS (the plan's shape, with plan v7's correction of 2026-09-27). Each row's natural key, org key, producer
// key and whether it carries its own answer (`Facts`, from `RowKeys`); the rows under each org key and under each
// producer key; the answers under each org key; per org key the CANDIDATE, the answer that is usable whenever it is
// fresh (refusals applied, an address behind it, newest by `OrgAnswerLedger.supersedes`); and each row's inherited
// answer, published by natural key as `inherited`, the exact value `QueueModel.inheritedAnswers` returns. The plan's
// email to org key index is DROPPED, by the correction: an org scoped refusal names its org key and the ledger never
// passes a show key, so a refusal change names the org keys it reaches by its own `scopeId`. Decision 7(a), the memo by
// producer key, is folded in: the verdict per producer key is T4's (`PatchableProducerTables.verdict`), kept per key
// and handed over as T4's ChangedKeys.
//
// THE NEIGHBOURHOOD (the plan's six). (a) A row whose facts moved is re-judged, under its old org key and its new one
// by construction, since a row is judged from its own facts. (b) A producer key whose verdict T4 moved re-judges every
// row holding it. (c) An answer change re-derives its org key's candidate (both org keys, if it moved). (d) A refusal
// change re-derives the org keys it names. (e) A row's own answer and the held keys: the row's facts carry the first,
// and a held key entering or leaving re-judges the rows holding that natural key. (f) The clock: a candidate is
// usable only while `Reachability.probeIsStale` says it is fresh, so each bring-up to a different instant re-judges
// the rows of every org key whose candidate crossed `probedAt + probeFreshness` between the two instants, in EITHER
// direction (a clock set back makes a stale answer usable again). A candidate is time independent because staleness is
// monotonic in `probedAt` and the newest answer wins: when the newest is stale, every older one is too.
//
// WHAT IS SHARED WITH THE ORACLE, AND WHAT HOLDS IT HONEST (L70, L370). The flattening of a stored answer
// (`OrgAnswerLedger.Answer.init?(_:)`), the refusal filter (`ContactRefusal.Ledger.allowedAnswers`), which answers can
// be inherited at all (`OrgAnswerLedger.carriesAnAddress`), the tie break (`supersedes`), staleness
// (`Reachability.probeIsStale`), the inherited value (`OrgAnswerLedger.Inherited.init(_:)`) and the producer verdict
// (T4, itself held to the cold tables) are called, never restated. What this adds of its own (the indexes, the
// candidate cache and when each is re-asked) is held to `QueueModel.inheritedAnswers` through the canonical wrapper by
// the per term harness, with the clock shifted both ways and the indexes held to their definitions, to the pass with no
// patch by the engine's whole pass harness, and to the oracle over a fresh read by the verifier
// (`QueueEnginePatches.mismatches(against:)`, `ledger.inherited`).

/// T5's patchable value, keyed by a row identity the caller chooses: the engine's `PersistentIdentifier`, never the
/// natural key (re-keys and merges reassign it). Comparable so that two rows holding one natural key, which the store's
/// unique constraint forbids but a value cannot assume, publish the one the pass's own key order would (the larger
/// identifier), never whichever was judged last.
struct PatchableAnswerLedger<Key: Hashable & Comparable & Sendable>: Sendable {
    typealias Answer = OrgAnswerLedger.Answer
    typealias Inherited = OrgAnswerLedger.Inherited
    typealias RefusalRow = ContactRefusal.Ledger.Row

    /// Everything the ledger reads from one row.
    struct Facts: Equatable, Sendable {
        var naturalKey: String
        var orgKey: String?
        var presenterKey: String?
        var hasOwnAnswer: Bool

        init(naturalKey: String, orgKey: String?, presenterKey: String?, hasOwnAnswer: Bool) {
            self.naturalKey = naturalKey
            self.orgKey = orgKey
            self.presenterKey = presenterKey
            self.hasOwnAnswer = hasOwnAnswer
        }

        /// One row's slice: the key and own answer through the ledger's own projection (`OrgAnswerLedger.Show`), the
        /// two folds from `RowKeys` (`OrgKey.stored` and `ProducerGate.key` over the presenter).
        init(of row: some ProspectFacts) {
            let show = OrgAnswerLedger.Show(row)
            let keys = row.foldedKeys
            self.init(naturalKey: show.key, orgKey: keys.orgKey, presenterKey: keys.presenterKey,
                      hasOwnAnswer: show.hasOwnAnswer)
        }
    }

    /// What one `apply` changed: the rows whose inherited answer moved (the hand-off to T7 and T10, #4363), and the work
    /// the change took, for the cost record.
    struct Changed: Equatable, Sendable {
        var rows: Set<Key> = []
        var orgKeysRederived = 0
        var rowsRejudged = 0
    }

    /// The instant, held keys and refusals the value was last brought up to.
    private(set) var now: Date
    private(set) var heldKeys: Set<String>
    private(set) var refusals: Set<RefusalRow>
    private var refusalLedger: ContactRefusal.Ledger
    private var rows: [Key: Facts] = [:]
    /// The rows under each org key and each producer key, and the rows holding each natural key.
    private(set) var rowsByOrgKey: [String: Set<Key>] = [:]
    private(set) var rowsByProducerKey: [String: Set<Key>] = [:]
    private var rowsByName: [String: Set<Key>] = [:]
    /// Every stored answer, flattened (nil for one with no readable result), and the answers under each org key.
    private var answers: [Key: Answer] = [:]
    private(set) var answersByOrgKey: [String: Set<Key>] = [:]
    /// Per org key, the answer that is usable whenever it is fresh.
    private(set) var candidates: [String: Answer] = [:]
    /// Each row's inherited answer, which T7 and T10 read by identity (#4363).
    private(set) var inheritedByRow: [Key: Inherited] = [:]
    /// The published answer, in `QueueModel.inheritedAnswers`' shape: natural key to inherited answer.
    private(set) var inherited: [String: Inherited] = [:]

    /// Every row and answer, built from nothing. `qualifies` is the producer verdict per producer key (T4's).
    init(rows: [(key: Key, facts: Facts)], answers: [(key: Key, answer: Answer?)], refusals: Set<RefusalRow>,
         heldKeys: Set<String>, now: Date, qualifies: (String) -> Bool) {
        self.now = now
        self.heldKeys = heldKeys
        self.refusals = refusals
        refusalLedger = ContactRefusal.Ledger(rows: Array(refusals))
        for row in rows {
            self.rows[row.key] = row.facts
            index(row.key, row.facts)
        }
        for entry in answers {
            guard let answer = entry.answer else { continue }
            self.answers[entry.key] = answer
            answersByOrgKey[answer.orgKey, default: []].insert(entry.key)
        }
        for orgKey in answersByOrgKey.keys { rederive(orgKey) }
        for key in self.rows.keys {
            if let value = judge(key, qualifies) { inheritedByRow[key] = value }
        }
        for name in rowsByName.keys { publish(name) }
    }

    /// The usable answer for one org key at the instant the value was brought up to, or nil.
    func usable(_ orgKey: String) -> Answer? { usable(orgKey, at: now) }

    /// Brings the value up to `rows` and `answers` (each key's new slice, or nil for one that is gone or, for an answer,
    /// has no readable result), to `refusals`, `heldKeys` and `now` as they now stand, and to the producer keys whose
    /// verdict T4 moved (`verdictsMoved`), with `qualifies` the verdict as it now stands. Returns what changed.
    @discardableResult
    mutating func apply(rows changes: [(key: Key, facts: Facts?)], answers answerChanges: [(key: Key, answer: Answer?)],
                        refusals newRefusals: Set<RefusalRow>, heldKeys newHeld: Set<String>, now newNow: Date,
                        verdictsMoved: Set<String>, qualifies: (String) -> Bool) -> Changed {
        var changed = Changed()
        var rejudge: Set<Key> = []
        var names: Set<String> = []
        var orgKeys: Set<String> = []

        // (a) and (e): a row whose facts moved, under the name it had and the name it has.
        for change in changes {
            let old = rows[change.key]
            guard old != change.facts else { continue }
            if let old {
                unindex(change.key, old)
                names.insert(old.naturalKey)
            }
            rows[change.key] = change.facts
            if let new = change.facts {
                index(change.key, new)
                names.insert(new.naturalKey)
            }
            rejudge.insert(change.key)
        }
        // (c): an answer that moved, under the org key it had and the one it has.
        for change in answerChanges {
            let old = answers[change.key]
            guard old != change.answer else { continue }
            if let old {
                answersByOrgKey[old.orgKey]?.remove(change.key)
                if answersByOrgKey[old.orgKey]?.isEmpty == true { answersByOrgKey[old.orgKey] = nil }
                orgKeys.insert(old.orgKey)
            }
            answers[change.key] = change.answer
            if let new = change.answer {
                answersByOrgKey[new.orgKey, default: []].insert(change.key)
                orgKeys.insert(new.orgKey)
            }
        }
        // (d): a refusal reaches the ledger only through its organisation (the ledger never passes a show key), so each
        // organisation scoped row that came or went names the one org key it can strike.
        if newRefusals != refusals {
            for row in newRefusals.symmetricDifference(refusals) where row.scopeRaw == ContactRefusal.Scope.organisationRaw {
                orgKeys.insert(row.scopeId)
            }
            refusals = newRefusals
            refusalLedger = ContactRefusal.Ledger(rows: Array(newRefusals))
        }
        // (e): a held key that came or went re-judges the rows holding it.
        if newHeld != heldKeys {
            for name in newHeld.symmetricDifference(heldKeys) { rejudge.formUnion(rowsByName[name] ?? []) }
            heldKeys = newHeld
        }
        // (c), (d) and (f): every org key whose usable answer can have moved, judged before and after. The clock can move
        // any candidate across its expiry, in either direction, so a new instant asks every candidate (a date comparison
        // each, no fold and no row walk); only an org key whose answer actually flipped re-judges its rows.
        let oldNow = now
        now = newNow
        var asked = orgKeys
        if oldNow != newNow { asked.formUnion(candidates.keys) }
        for orgKey in asked {
            let before = usable(orgKey, at: oldNow)
            if orgKeys.contains(orgKey) {
                rederive(orgKey)
                changed.orgKeysRederived += 1
            }
            if usable(orgKey, at: newNow) != before { rejudge.formUnion(rowsByOrgKey[orgKey] ?? []) }
        }
        // (b): a producer key whose verdict T4 moved.
        for producerKey in verdictsMoved { rejudge.formUnion(rowsByProducerKey[producerKey] ?? []) }

        for key in rejudge {
            changed.rowsRejudged += 1
            let value = judge(key, qualifies)
            guard inheritedByRow[key] != value else { continue }
            inheritedByRow[key] = value
            changed.rows.insert(key)
            if let name = rows[key]?.naturalKey { names.insert(name) }
        }
        for name in names { publish(name) }
        return changed
    }

    // MARK: - The rule, through the oracle's own pieces

    private func usable(_ orgKey: String, at instant: Date) -> Answer? {
        guard let answer = candidates[orgKey],
              !Reachability.probeIsStale(probedAt: answer.probedAt, now: instant) else { return nil }
        return answer
    }

    /// One org key's candidate: its answers with the struck addresses taken out (`allowedAnswers`, the oracle's own
    /// filter), those an answer can be inherited from, and the newest by the oracle's tie break.
    private mutating func rederive(_ orgKey: String) {
        let held = (answersByOrgKey[orgKey] ?? []).compactMap { answers[$0] }
        var best: Answer?
        for answer in refusalLedger.allowedAnswers(held) where OrgAnswerLedger.carriesAnAddress(answer) {
            if let existing = best, !OrgAnswerLedger.supersedes(answer, existing) { continue }
            best = answer
        }
        candidates[orgKey] = best
    }

    /// One row, by the oracle's conditions in its order: no answer of its own, not held, an organisation with a usable
    /// answer, and a producer key whose verdict qualifies.
    private func judge(_ key: Key, _ qualifies: (String) -> Bool) -> Inherited? {
        guard let row = rows[key], !row.hasOwnAnswer, !heldKeys.contains(row.naturalKey),
              let orgKey = row.orgKey, let answer = usable(orgKey),
              let producerKey = row.presenterKey, qualifies(producerKey) else { return nil }
        return Inherited(answer)
    }

    /// One natural key's published answer: the inheriting row with the largest identifier, as the pass's key order
    /// (natural key, then identifier) leaves the oracle's last write.
    private mutating func publish(_ name: String) {
        let winner = (rowsByName[name] ?? []).filter { inheritedByRow[$0] != nil }.max()
        inherited[name] = winner.flatMap { inheritedByRow[$0] }
    }

    // MARK: - The indexes

    private mutating func index(_ key: Key, _ facts: Facts) {
        rowsByName[facts.naturalKey, default: []].insert(key)
        if let orgKey = facts.orgKey { rowsByOrgKey[orgKey, default: []].insert(key) }
        if let producerKey = facts.presenterKey { rowsByProducerKey[producerKey, default: []].insert(key) }
    }

    private mutating func unindex(_ key: Key, _ facts: Facts) {
        Self.remove(key, from: facts.naturalKey, in: &rowsByName)
        if let orgKey = facts.orgKey { Self.remove(key, from: orgKey, in: &rowsByOrgKey) }
        if let producerKey = facts.presenterKey { Self.remove(key, from: producerKey, in: &rowsByProducerKey) }
    }

    private static func remove(_ key: Key, from bucket: String, in index: inout [String: Set<Key>]) {
        index[bucket]?.remove(key)
        if index[bucket]?.isEmpty == true { index[bucket] = nil }
    }
}
