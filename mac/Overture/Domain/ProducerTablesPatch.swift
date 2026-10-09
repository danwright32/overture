import Foundation

// #4362 (plan v7 Phase 4b(c), discussion #4267 section 7 T4): the producer tables (`QueueModel.ProducerTables`, the
// corpus and the venue brands) as a PATCHABLE VALUE, which the queue engine keeps between passes and brings up to
// date from the shows that changed, in place of building both over the whole store on every pass. #4623 measured that
// cold build at 25.1 ms at 1x and 201.7 ms at 4x in an optimised build, a cost the switch added: before it, `QueueView`
// kept the tables in a memo that a dismissal reused.
//
// WHAT IT HOLDS (the plan's shape). Each row's (presenter key, venue key), folded once (`Facts`, from `RowKeys`); how
// many rows carry each presenter key, each venue key and each pair, so a key leaves only with its last row; the
// corpus's own two tables in its own shape (the venue keys with their word postings, and each presenter's rooms); and
// the WITNESS SETS: `witnesses[presenter]` is every venue key that names the same room as that presenter
// (`ProducerGate.namesTheSameRoom`, `isVenueBrand`'s containment arm, existential over venue keys), and
// `witnessedBy[venue]` its inverse. The published answer is `tables`, the two tables in exactly the shape
// `QueueModel.ProducerTables(rows:overrides:)` builds, so the pass reads either without knowing which.
//
// THE NEIGHBOURHOOD, from the rule in `ProducerGate.swift`. A change to one row can change: the venue count of its old
// and new presenter keys; the brand verdict of a presenter whose key IS a venue key that appeared or left; the
// containment verdict of every presenter sharing a word with a venue key that appeared (each tested ONCE, against
// that key) or left (struck from its witnesses with no test at all, which is what removes 0b.1's 108.1 ms tail, a
// venue edit that re-asked `isVenueBrand` for 172 presenters); and an override change names its own keys. So no
// change walks every presenter or every venue: a new presenter is tested against the venues sharing a word with it,
// and a new venue against the presenters sharing a word with it, both through Step W's `WordPostings`.
//
// WHAT IS SHARED WITH THE ORACLE, AND WHAT HOLDS IT HONEST (L70, L370). The word candidate function (Step W, #4353),
// the containment predicate (`namesTheSameRoom`), the order of the brand arms (`ProducerGate.isVenueBrand(_:
// isAVenueKey:overrides:namesARoom:)`) and the verdict's last two arms (`ProducerGate.qualifies(presenterKey:
// isVenueBrand:distinctVenueCount:overrides:)`) are called, never restated, because a second copy of a rule is how
// two copies come to disagree. A fault in any of them would then reach the product and the patch alike, so the
// independent side of every comparison is a brute force over the DEFINITION with no word prefilter
// (`phase0bBruteBrand`, `PatchableProducerTablesTests`); what the patch adds of its own (the counts, the witness
// sets and when each is re-asked) is held to `ProducerGate.Corpus` and `VenueBrands` by the per term harness, the
// engine's whole pass harness and the verifier (`QueueEnginePatches.mismatches(against:)`).

/// T4's patchable value, keyed by a row identity the caller chooses: the engine's `PersistentIdentifier`, never the
/// natural key (re-keys and merges reassign it) and never a contact's address.
struct PatchableProducerTables<Key: Hashable & Sendable>: Sendable {

    /// Everything the producer tables read from one row: its presenter and its venue as the gate folds them.
    struct Facts: Equatable, Sendable {
        var presenterKey: String?
        var venueKey: String?

        init(presenterKey: String?, venueKey: String?) {
            self.presenterKey = presenterKey
            self.venueKey = venueKey
        }

        /// One row's slice, from the folds `RowKeys` took once (`ProducerGate.key` over the presenter and the venue,
        /// which `RowKeysMatchTheTermsTests` holds).
        init(of row: some ProspectFacts) {
            let keys = row.foldedKeys
            self.init(presenterKey: keys.presenterKey, venueKey: keys.venueKey)
        }
    }

    /// What the tables answer about one presenter key: what T5 (the ledger, #4364) reads.
    struct Verdict: Equatable, Sendable {
        var brand: Bool
        var roomName: Bool
        var venueCount: Int
        var qualifies: Bool
    }

    /// What one `apply` changed (the plan's ChangedKeys): every presenter key whose verdict moved, which is T5's
    /// hand-off once T5 is patched (#4364), and the work the change took, for the cost record.
    struct Changed: Equatable, Sendable {
        var presenterKeys: Set<String> = []
        var witnessTests = 0
        var presentersReasked = 0
    }

    /// The overrides the tables were last brought up to.
    private(set) var overrides: ProducerOverrides
    private var facts: [Key: Facts] = [:]
    private var presenterRows: [String: Int] = [:]
    private var venueRows: [String: Int] = [:]
    private var pairRows: [String: [String: Int]] = [:]
    /// The corpus's two tables in its own shape, kept in step with the counts above.
    private var venueKeys: Set<String> = []
    private var venuePostings = ProducerGate.WordPostings()
    private var venuesByPresenter: [String: Set<String>] = [:]
    /// The presenter keys' postings, so a venue key that appears finds the presenters it might name.
    private var presenterPostings = ProducerGate.WordPostings()
    /// Each key's words, for the subset test in front of `namesTheSameRoom`.
    private var venueWords: [String: Set<String>] = [:]
    private var presenterWords: [String: Set<String>] = [:]
    private var witnesses: [String: Set<String>] = [:]
    private var witnessedBy: [String: Set<String>] = [:]
    /// `VenueBrands`' two sets, kept in step.
    private var brandKeys: Set<String> = []
    private var roomNameKeys: Set<String> = []

    /// The published answer, in `QueueModel.ProducerTables(rows:overrides:)`'s shape. Assembled on each read from the
    /// sets above rather than stored beside them, so the value never holds a second reference to its own storage and
    /// every `apply` mutates in place (a stored copy would make each mutation copy the whole table).
    var tables: QueueModel.ProducerTables {
        QueueModel.ProducerTables(
            corpus: ProducerGate.Corpus(venues: ProducerGate.VenueKeyIndex(keys: venueKeys, postings: venuePostings),
                                        venuesByPresenter: venuesByPresenter),
            venueBrands: ProducerGate.VenueBrands(brandKeys: brandKeys, roomNameKeys: roomNameKeys))
    }

    /// Every row, built from nothing, with complete witness sets.
    init(rows: [(key: Key, facts: Facts)], overrides: ProducerOverrides) {
        self.overrides = overrides
        for row in rows {
            facts[row.key] = row.facts
            count(row.facts, 1)
        }
        for v in venueKeys { addVenueWords(v) }
        for p in presenterRows.keys { addPresenterWords(p) }
        var tests = 0
        for p in presenterRows.keys {
            let found = findWitnesses(p, tests: &tests)
            guard !found.isEmpty else { continue }
            witnesses[p] = found
            for v in found { witnessedBy[v, default: []].insert(p) }
        }
        for p in presenterRows.keys { settle(p) }
    }

    /// The tables' answer about one presenter key, or nil for a key no row carries.
    func verdict(_ presenterKey: String) -> Verdict? {
        guard presenterRows[presenterKey] != nil else { return nil }
        let brand = brandKeys.contains(presenterKey)
        let count = venuesByPresenter[presenterKey]?.count ?? 0
        return Verdict(brand: brand, roomName: roomNameKeys.contains(presenterKey), venueCount: count,
                       qualifies: ProducerGate.qualifies(presenterKey: presenterKey, isVenueBrand: brand,
                                                         distinctVenueCount: count, overrides: overrides))
    }

    /// Brings the value up to `changes` (each key's new slice, or nil for a row that is gone) and to `overrides` as
    /// they now stand. Returns what changed.
    @discardableResult
    mutating func apply(_ changes: [(key: Key, facts: Facts?)], overrides new: ProducerOverrides) -> Changed {
        let overridesMoved = overrides.promoted.symmetricDifference(new.promoted)
            .union(overrides.demoted.symmetricDifference(new.demoted))
        // Only the rows whose presenter or venue moved: a dismissal, a stage change or a note is nothing to T4.
        var moved: [(key: Key, old: Facts?, new: Facts?)] = []
        var presentersTouched: Set<String> = []
        var venuesTouched: Set<String> = []
        for change in changes {
            let old = facts[change.key]
            guard old != change.facts else { continue }
            moved.append((change.key, old, change.facts))
            for side in [old, change.facts] {
                if let p = side?.presenterKey { presentersTouched.insert(p) }
                if let v = side?.venueKey { venuesTouched.insert(v) }
            }
        }
        var changed = Changed()
        guard !moved.isEmpty || !overridesMoved.isEmpty else { return changed }

        // Each verdict that can move, read BEFORE anything moves, so ChangedKeys is judged against the old answer.
        var before: [String: Verdict?] = [:]
        for p in presentersTouched.union(overridesMoved) { before.updateValue(verdict(p), forKey: p) }
        let venuesBefore = venuesTouched.filter { venueRows[$0] != nil }
        let presentersBefore = presentersTouched.filter { presenterRows[$0] != nil }

        for row in moved {
            if let old = row.old { count(old, -1) }
            facts[row.key] = row.new
            if let new = row.new { count(new, 1) }
        }
        overrides = new

        var reask = presentersTouched.union(overridesMoved)
        let goneVenues = venuesBefore.filter { venueRows[$0] == nil }
        let newVenues = venuesTouched.filter { !venuesBefore.contains($0) && venueRows[$0] != nil }
        let gonePresenters = presentersBefore.filter { presenterRows[$0] == nil }
        let newPresenters = presentersTouched.filter { !presentersBefore.contains($0) && presenterRows[$0] != nil }

        // A venue key that LEAVES is struck from every witness set holding it, with no test. A presenter spelled
        // exactly like it is re-asked too, because the equality arm read it.
        for v in goneVenues {
            removeVenueWords(v)
            for p in witnessedBy[v] ?? [] {
                witnesses[p]?.remove(v)
                if witnesses[p]?.isEmpty == true { witnesses[p] = nil }
                reask.insert(p)
            }
            witnessedBy[v] = nil
            reask.insert(v)
        }
        for p in gonePresenters {
            removePresenterWords(p)
            for v in witnesses[p] ?? [] {
                witnessedBy[v]?.remove(p)
                if witnessedBy[v]?.isEmpty == true { witnessedBy[v] = nil }
            }
            witnesses[p] = nil
            brandKeys.remove(p)
            roomNameKeys.remove(p)
        }
        for v in newVenues {
            addVenueWords(v)
            reask.insert(v)
        }
        // A presenter key that APPEARS is tested against every venue sharing a word with it, new venues included.
        for p in newPresenters {
            addPresenterWords(p)
            let found = findWitnesses(p, tests: &changed.witnessTests)
            guard !found.isEmpty else { continue }
            witnesses[p] = found
            for v in found { witnessedBy[v, default: []].insert(p) }
        }
        // A venue key that APPEARS is tested ONCE against each presenter sharing a word with it (a new presenter was
        // tested against it just above).
        for v in newVenues {
            guard let vw = venueWords[v] else { continue }
            for p in presenterPostings.keys(sharingAWordWith: v) where !newPresenters.contains(p) {
                changed.witnessTests += 1
                guard let pw = presenterWords[p], Self.sameRoom(p, pw, v, vw) else { continue }
                witnesses[p, default: []].insert(v)
                witnessedBy[v, default: []].insert(p)
                reask.insert(p)
            }
        }

        for p in reask {
            // A key read for the first time here (a presenter re-asked only because a venue moved) had no verdict
            // moved by anything else in this change, so its answer now, before it settles, is its answer before.
            let old: Verdict? = before.keys.contains(p) ? before[p] ?? nil : verdict(p)
            if presenterRows[p] != nil {
                settle(p)
                changed.presentersReasked += 1
            }
            if verdict(p) != old { changed.presenterKeys.insert(p) }
        }
        return changed
    }

    // MARK: - The counts and the indexes

    /// One row's pair counted in (`by` 1) or out (`by` -1), keeping the corpus's two tables in step: a key enters on
    /// its first row and leaves with its last, and a presenter with no readable room is present with no rooms.
    private mutating func count(_ row: Facts, _ by: Int) {
        if let v = row.venueKey {
            let n = (venueRows[v] ?? 0) + by
            venueRows[v] = n > 0 ? n : nil
            if n > 0 { venueKeys.insert(v) } else { venueKeys.remove(v) }
        }
        guard let p = row.presenterKey else { return }
        let n = (presenterRows[p] ?? 0) + by
        guard n > 0 else {
            presenterRows[p] = nil
            pairRows[p] = nil
            venuesByPresenter[p] = nil
            return
        }
        presenterRows[p] = n
        if venuesByPresenter[p] == nil { venuesByPresenter[p] = [] }
        guard let v = row.venueKey else { return }
        let m = (pairRows[p]?[v] ?? 0) + by
        pairRows[p, default: [:]][v] = m > 0 ? m : nil
        if m > 0 { venuesByPresenter[p]?.insert(v) } else { venuesByPresenter[p]?.remove(v) }
    }

    private mutating func addVenueWords(_ v: String) {
        venueWords[v] = Self.words(v)
        venuePostings.insert(v)
    }

    private mutating func removeVenueWords(_ v: String) {
        venuePostings.remove(v)
        venueWords[v] = nil
    }

    private mutating func addPresenterWords(_ p: String) {
        presenterWords[p] = Self.words(p)
        presenterPostings.insert(p)
    }

    private mutating func removePresenterWords(_ p: String) {
        presenterPostings.remove(p)
        presenterWords[p] = nil
    }

    private static func words(_ key: String) -> Set<String> {
        Set(ProducerGate.WordPostings.words(of: key).map(String.init))
    }

    /// `namesTheSameRoom`, behind a necessary condition: an occurrence of one name inside another, bounded by spaces,
    /// holds every word of the shorter, so one side's words are a subset of the other's.
    private static func sameRoom(_ p: String, _ pw: Set<String>, _ v: String, _ vw: Set<String>) -> Bool {
        (vw.isSubset(of: pw) || pw.isSubset(of: vw)) && ProducerGate.namesTheSameRoom(p, v)
    }

    private func findWitnesses(_ p: String, tests: inout Int) -> Set<String> {
        guard let pw = presenterWords[p] else { return [] }
        var found: Set<String> = []
        for v in venuePostings.keys(sharingAWordWith: p) {
            tests += 1
            if let vw = venueWords[v], Self.sameRoom(p, pw, v, vw) { found.insert(v) }
        }
        return found
    }

    /// One presenter's brand verdict, by the gate's own arms in their order, over the witness set in place of a search.
    private mutating func settle(_ p: String) {
        let isAVenueKey = venueRows[p] != nil
        let brand = ProducerGate.isVenueBrand(p, isAVenueKey: isAVenueKey, overrides: overrides) {
            !(witnesses[p]?.isEmpty ?? true)
        }
        if brand { brandKeys.insert(p) } else { brandKeys.remove(p) }
        if brand && isAVenueKey { roomNameKeys.insert(p) } else { roomNameKeys.remove(p) }
    }
}
