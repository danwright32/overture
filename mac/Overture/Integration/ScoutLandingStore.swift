import Foundation
import SwiftData

// #4275: the stored shows a scout LANDING judges against, read ONCE per landing and kept current as each
// source lands.
//
// WHY IT EXISTS. `ScoutService.apply` runs once per landed source, and before this every run fetched the
// whole `Prospect` table for itself, twice (the production token discard and the ambiguous URL tables),
// folded every stored row again for each, and the run URL arm fetched the whole table once more for every
// event that reached it. Measured on a store clone at 1x (1,344 shows, 39 sources, Debug, queue hosted,
// #4275's attribution comment): 17.2 s of fetches, 47% of all main thread time, plus 7.2 s of folding and
// 2.0 s in that arm, together 26.5 s of a 36.6 s landing, all in one synchronous block since #4262. The
// fetch is linear in the store (0.149 ms a row), so the cost was store size times sources landed times two.
//
// WHY IT CANNOT BE A SNAPSHOT. A later source's judgements must see what earlier sources in the SAME
// landing wrote: a row source A just inserted is what source B's run URL arm has to re-key onto, and a
// title A just rewrote is what B's token discard has to count. A copy taken at the start and never updated
// would let two sources mint the same show twice or join what must not be joined, silently. So:
//
//   - MEMBERSHIP is the fetch plus every row the landing inserts (`inserted`), in that order: the fetch in
//     natural key order, then the inserts as they came (#4397). Never the fetch's own order, which on a
//     context holding unsaved changes differs from one read to the next. `.everyRead` orders each fresh
//     fetch the same way, by the rank this landing gave each row. Rows deleted from the context drop out
//     on every read. Nothing in the landing deletes a show today; the filter is there so the day something
//     does, the working set cannot hand back a row a fresh fetch would not.
//   - EVERY FOLD is re-derived when the raw fields it came from change. A cached fold is compared against
//     the four raw fields it was built from (title, venue, listing URL, run URLs), and folded again on any
//     difference. So an in place write by an earlier source, or by an earlier event of the same source, is
//     seen without any call site having to remember to announce it.
//   - EVERY KEYED LOOKUP (`stored(key:)`, what `Prospect.stored(key:in:)` answers from the database) is
//     answered from a natural key index over the same membership, so it takes the landing's inserts, drops
//     deleted rows, and follows a key moved in place, exactly as the fetch it replaces would.
//
// WHICH ROWS ARE RE-CHECKED, and why it is not every row (#4275, second pass). Comparing every cached row
// on every read was itself about 13% of what was left of a landing (optimised, on a store clone), because
// `runSourceURLs` is an archived blob that decodes on each comparison, and there is a read per arm per
// event. Nothing but SwiftData knows which rows were written, so SwiftData is asked: at every read, the
// context's changed and inserted models (`changedModelsArray`, `insertedModelsArray`) are marked to be
// re-checked, and so are the ones a save is about to carry off, captured from `ModelContext.willSave` as
// the save begins, because a save empties both lists and `apply` saves once per source. A row neither list
// has named since its fold was taken has not been written, so its fold and its key entry still describe it.
// Per row observation was the other candidate and was rejected: an observation that never fires is never
// removed, and the main context's rows live as long as the app, so every landing would leave one behind on
// every row it did not write.
//
// It is sound only for a landing, meaning a stretch of main actor work with no `await` in it: nothing else
// can write the store while it runs, so the landing's own inserts are the only change a fresh fetch could
// see that the working set does not already hold. Both callers build it immediately before their landing
// loop (`runScout`, `ScoutExtractIngest.ingest`), never before the reads that await.
//
// A READ THAT FAILS is not cached. The first call that needs the rows fetches them; if that throws, the
// error goes to that caller exactly as the fetch it replaces would have thrown, and the next caller tries
// again. So a transient failure costs what it touched and no more, which is what separate per read
// fetches gave, and a working set never stands in for rows it could not read (L215).
@MainActor
final class ScoutLandingStore {
    // How the rows are read. The default is the store; a test injects one that counts, or that fails.
    typealias Read = (ModelContext) throws -> [Prospect]
    typealias ReadKey = (String, ModelContext) throws -> Prospect?

    // `.everyRead` answers each question with a fresh fetch and a fresh fold, which is exactly what the
    // code did before #4275. It exists as the REFERENCE the equality tests compare the working set against,
    // so "the landing writes what it always wrote" is measured rather than asserted (#4275 test a). No
    // shipping caller uses it.
    enum Policy { case once, everyRead }

    // One row's folded fields, with the raw values they were folded from so a change can be detected.
    struct Fold {
        let groupName: String
        let venue: String?
        let sourceListingURL: String?
        let runSourceURLs: [String]

        // `ShowLink`'s folds, which the token discard and the key's own title test use.
        let foldedTitle: String
        let foldedVenue: String
        // `ScoutService.venueKey`, which every arm compares for the room, so a matcher does not normalise
        // every row per event.
        let venueKey: String
        // `ListingURL`'s folds of the listing URL alone, of the run URLs alone, and of both together.
        let listingFold: String?
        let runFolds: Set<String>
        let allURLFolds: Set<String>
        // The venue's production tokens in listing then run order, as `ProductionToken.inURL` reads them.
        let tokens: [String]

        init(_ p: Prospect) {
            groupName = p.groupName
            venue = p.venue
            sourceListingURL = p.sourceListingURL
            runSourceURLs = p.runSourceURLs
            foldedTitle = ShowLink.foldedTitle(p.groupName)
            foldedVenue = ShowLink.foldedVenue(p.venue)
            venueKey = ScoutService.venueKey(p.venue)
            listingFold = p.sourceListingURL.map(ListingURL.fold)
            runFolds = ListingURL.foldedSet(p.runSourceURLs)
            let urls = (p.sourceListingURL.map { [$0] } ?? []) + p.runSourceURLs
            allURLFolds = ListingURL.foldedSet(urls)
            tokens = urls.compactMap(ProductionToken.inURL)
        }

        func describes(_ p: Prospect) -> Bool {
            groupName == p.groupName && venue == p.venue && sourceListingURL == p.sourceListingURL
                && runSourceURLs == p.runSourceURLs
        }
    }

    private let context: ModelContext
    private let read: Read
    private let readKey: ReadKey
    let policy: Policy
    private var loaded: [Prospect]?
    // `loaded` without deleted rows, as the last read found it. Dropped whenever it could have changed: a
    // row joins, a save begins, or a deletion is pending.
    private var members: [Prospect]?
    private var folds: [ObjectIdentifier: Fold] = [:]
    // Rows SwiftData has named as written since their fold, or their key entry, was taken. Two sets because
    // the two are consumed separately: a fold is re-checked when it is asked for, a key when a key is.
    private var foldsToCheck: Set<ObjectIdentifier> = []
    private var keysToCheck: [ObjectIdentifier: Prospect] = [:]
    // The natural key index, built on the first keyed lookup from the membership and kept in its order, so
    // two rows holding one key (possible only between an insert and the save that refuses it) answer in the
    // membership's order.
    private var keyIndex: [String: [Prospect]]?
    private var indexedKey: [ObjectIdentifier: String] = [:]
    private var position: [ObjectIdentifier: Int] = [:]
    // #4397: the order this landing holds its rows in, one rank per row, kept with the row so the identifier
    // cannot be reused by another object. The first read ranks what it found in key order; every row the
    // landing inserts is ranked after all of those, in the order inserted. Both policies order by it, so the
    // working set and the fresh read it is proved equivalent to agree, and a re-key does not move a row.
    private var rank: [ObjectIdentifier: (row: Prospect, rank: Int)] = [:]
    private let saveWatch = SaveWatch()
    // How many cached folds were compared against their row. Counted so a test can pin that it does not
    // grow with the store (#4275).
    private(set) var foldValidations = 0
    // Moves whenever any row's folds are (re)computed or a row joins, so a value derived from every row's
    // folds knows when it has to be derived again.
    private var generation = 0
    private var shows: (generation: Int, count: Int, value: StoredShows)?

    // The stored rows' URLs folded into SHOWS (`ShowLink.addShows`), in both scopes the ambiguity rule asks.
    struct StoredShows {
        var atAVenue: [String: [String]] = [:]
        var anywhere: [String: [String]] = [:]
    }

    // #4325: the reconcile writes of this landing that no save has carried yet, oldest first. A successful
    // save of this context empties it (`didSave`, below), whoever saved, so what is left at the closing save
    // is exactly what that save would carry for the reconcile, and exactly what a failed one must put back.
    private(set) var unsavedReconcileWrites: [FeedReconcile.Writes] = []
    private let reconcileSaveWatch = SaveWatch()

    func noteReconcile(_ writes: FeedReconcile.Writes) {
        if !writes.isEmpty { unsavedReconcileWrites.append(writes) }
    }

    // Called after a save the landing made itself, which a test may inject and so post no `didSave`.
    func reconcileWritesSaved() { unsavedReconcileWrites = [] }

    // Puts back every reconcile write no save carried, newest first, so a retry counts each miss once.
    func revertUnsavedReconcileWrites() {
        for writes in unsavedReconcileWrites.reversed() { writes.revert() }
        unsavedReconcileWrites = []
    }

    init(context: ModelContext, read: @escaping Read = ScoutService.readProspectTable,
         readKey: @escaping ReadKey = { try Prospect.stored(key: $0, in: $1) },
         policy: Policy = .once) {
        self.context = context
        self.read = read
        self.readKey = readKey
        self.policy = policy
        // #4325: for both policies, since both land. Posted only for a save that succeeded.
        reconcileSaveWatch.token = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: context, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.unsavedReconcileWrites = [] }
        }
        guard policy == .once else { return }
        // A save empties the context's changed and inserted models, so what it is about to carry off is
        // noted as it begins. Posted synchronously by `save()` on the saving thread, which for the main
        // context is this actor.
        saveWatch.token = NotificationCenter.default.addObserver(
            forName: ModelContext.willSave, object: context, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteWrittenRows()
                self?.members = nil
            }
        }
    }

    // Removes the save observer when the landing's working set goes, so a landing leaves nothing registered.
    private final class SaveWatch: @unchecked Sendable {
        var token: NSObjectProtocol?
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    // Marks every row SwiftData says has been written, and not yet saved, to be re-checked. Cheap when there
    // is nothing to say, which is the state right after every source's save.
    private func noteWrittenRows() {
        guard loaded != nil, context.hasChanges else { return }
        for model in context.changedModelsArray + context.insertedModelsArray {
            guard let p = model as? Prospect else { continue }
            let id = ObjectIdentifier(p)
            foldsToCheck.insert(id)
            keysToCheck[id] = p
        }
    }

    // Every stored show a fresh fetch would return right now, in this landing's order. Throws when the store
    // cannot answer.
    func rows() throws -> [Prospect] {
        if policy == .everyRead { return ranked(try read(context)) }
        if let loaded {
            noteWrittenRows()
            // Re-filtering every row on every read was, once keyed lookups came here, a larger cost than the
            // keyed fetch it replaced (measured on the #4275 probe, Debug). So the filtered list is kept, and
            // used only while no deletion is pending, which is what makes it the answer the filter would give.
            let deletionPending = context.hasChanges && !context.deletedModelsArray.isEmpty
            if let members, !deletionPending { return members }
            let current = loaded.filter { !$0.isDeleted }
            members = deletionPending ? nil : current
            return current
        }
        // #4397: held in the landing's own order, never the read's. Every first match the landing makes reads
        // this array, and an unsorted fetch on a context with unsaved changes comes back in a different order
        // each time.
        let fetched = ranked(try read(context))
        loaded = fetched
        members = fetched
        return fetched
    }

    // `rows` in this landing's order: rows it has ranked by their rank, and any it has not yet seen (the whole
    // first read) ranked now, in key order, after them.
    private func ranked(_ rows: [Prospect]) -> [Prospect] {
        let unseen = rows.filter { rank[ObjectIdentifier($0)] == nil }
        for p in Prospect.inKeyOrder(unseen) { rankNext(p) }
        return rows.map { (row: $0, rank: rank[ObjectIdentifier($0)]?.rank ?? Int.max) }
            .sorted { $0.rank < $1.rank }
            .map(\.row)
    }

    private func rankNext(_ p: Prospect) {
        rank[ObjectIdentifier(p)] = (row: p, rank: rank.count)
    }

    // A row this landing has just put into the context. Before the first read there is nothing to add it
    // to, and the read that follows will return it, because a fetch includes unsaved inserts.
    func inserted(_ p: Prospect) {
        // Ranked under both policies once anything has been read, so a fresh read places it where `.once` does.
        if !rank.isEmpty, rank[ObjectIdentifier(p)] == nil { rankNext(p) }
        guard policy == .once, loaded != nil else { return }
        loaded?.append(p)
        members = nil
        generation += 1
        if keyIndex != nil { index(p, at: (loaded?.count ?? 1) - 1) }
    }

    // The stored row holding a natural key, or nil when nobody holds it: what `Prospect.stored(key:in:)`
    // answers from the database, answered from the working set. Throws when the store cannot answer, as the
    // fetch does, because "could not read" and "the key is free" are the same nil to every caller and only
    // one of them is safe to write a unique key on (#2754, L105).
    func stored(key: String) throws -> Prospect? {
        if policy == .everyRead { return try readKey(key, context) }
        // The rows are loaded once; after that only what was written is asked about. A deleted row stays in
        // the index and is refused below, so no read of every row's `isDeleted` is needed here.
        if loaded == nil { _ = try rows() } else { noteWrittenRows() }
        if keyIndex == nil {
            keyIndex = [:]
            keysToCheck = [:]
            for (i, p) in (loaded ?? []).enumerated() { index(p, at: i) }
        } else {
            for (id, p) in keysToCheck where indexedKey[id] != nil && indexedKey[id] != p.naturalKey {
                unindex(p)
                index(p, at: position[id] ?? Int.max)
            }
            keysToCheck = [:]
        }
        // Compared as bytes, as the store compares them: Swift's `==` would also match a canonically equal
        // spelling the database's predicate does not (L273).
        return keyIndex?[key]?.first { !$0.isDeleted && $0.naturalKey.utf8.elementsEqual(key.utf8) }
    }

    private func index(_ p: Prospect, at slot: Int) {
        let id = ObjectIdentifier(p)
        position[id] = slot
        indexedKey[id] = p.naturalKey
        var bucket = keyIndex?[p.naturalKey] ?? []
        bucket.append(p)
        bucket.sort { (position[ObjectIdentifier($0)] ?? Int.max) < (position[ObjectIdentifier($1)] ?? Int.max) }
        keyIndex?[p.naturalKey] = bucket
    }

    private func unindex(_ p: Prospect) {
        let id = ObjectIdentifier(p)
        guard let old = indexedKey[id] else { return }
        keyIndex?[old]?.removeAll { $0 === p }
        if keyIndex?[old]?.isEmpty == true { keyIndex?[old] = nil }
        indexedKey[id] = nil
    }

    // This row's folds, re-derived if any field they came from has changed since they were cached. Compared
    // only when SwiftData has named the row as written since the last comparison (`noteWrittenRows`, run by
    // every read of the rows, which is how every caller came by the row it is asking about).
    func fold(of p: Prospect) -> Fold {
        if policy == .everyRead { return Fold(p) }
        let id = ObjectIdentifier(p)
        let written = foldsToCheck.remove(id) != nil
        if let cached = folds[id] {
            if !written { return cached }
            foldValidations += 1
            if cached.describes(p) { return cached }
        }
        let fresh = Fold(p)
        folds[id] = fresh
        generation += 1
        return fresh
    }

    // The stored rows folded into shows, walked once and walked again only when a row joined, left, or had
    // a folded field change since. The walk is the expensive half of the ambiguous URL rule (a pairwise
    // title test per URL), and before this it was repeated, identically, for every source of a landing.
    // Every row's fold is asked for first, which re-folds any row SwiftData named as written since.
    func storedShowsPerURL() throws -> StoredShows {
        let rows = try rows()
        for row in rows { _ = fold(of: row) }
        if policy == .once, let shows, shows.generation == generation, shows.count == rows.count {
            return shows.value
        }
        var value = StoredShows()
        let seen = rows.flatMap { ScoutService.ambiguityEntries(of: fold(of: $0)) }
        ShowLink.addShows(seen, scopedByVenue: true, into: &value.atAVenue)
        ShowLink.addShows(seen, scopedByVenue: false, into: &value.anywhere)
        shows = (generation, rows.count, value)
        return value
    }
}
