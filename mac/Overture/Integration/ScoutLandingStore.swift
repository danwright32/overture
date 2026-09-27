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
//   - MEMBERSHIP is the fetch plus every row the landing inserts (`inserted`), in that order, which is the
//     order a fresh fetch returns them in (an unsorted fetch comes back in insertion order, and a row
//     inserted since sits after every row that was already there). Rows deleted from the context drop out
//     on every read. Nothing in the landing deletes a show today; the filter is there so the day something
//     does, the working set cannot hand back a row a fresh fetch would not.
//   - EVERY FOLD is re-derived when the raw fields it came from change. Each read of a row's fold compares
//     the four raw fields it was built from (title, venue, listing URL, run URLs) against the ones cached,
//     and folds again on any difference. So an in place write by an earlier source, or by an earlier event
//     of the same source, is seen without any call site having to remember to announce it.
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
    let policy: Policy
    private var loaded: [Prospect]?
    private var folds: [ObjectIdentifier: Fold] = [:]
    // Moves whenever any row's folds are (re)computed or a row joins, so a value derived from every row's
    // folds knows when it has to be derived again.
    private var generation = 0
    private var shows: (generation: Int, count: Int, value: StoredShows)?

    // The stored rows' URLs folded into SHOWS (`ShowLink.addShows`), in both scopes the ambiguity rule asks.
    struct StoredShows {
        var atAVenue: [String: [String]] = [:]
        var anywhere: [String: [String]] = [:]
    }

    init(context: ModelContext, read: @escaping Read = ScoutService.readProspectTable,
         policy: Policy = .once) {
        self.context = context
        self.read = read
        self.policy = policy
    }

    // Every stored show, as a fresh fetch would return it right now. Throws when the store cannot answer.
    func rows() throws -> [Prospect] {
        if policy == .everyRead { return try read(context) }
        if let loaded { return loaded.filter { !$0.isDeleted } }
        let fetched = try read(context)
        loaded = fetched
        return fetched
    }

    // A row this landing has just put into the context. Before the first read there is nothing to add it
    // to, and the read that follows will return it, because a fetch includes unsaved inserts.
    func inserted(_ p: Prospect) {
        guard policy == .once, loaded != nil else { return }
        loaded?.append(p)
        generation += 1
    }

    // This row's folds, re-derived if any field they came from has changed since they were cached.
    func fold(of p: Prospect) -> Fold {
        if policy == .everyRead { return Fold(p) }
        let id = ObjectIdentifier(p)
        if let cached = folds[id], cached.describes(p) { return cached }
        let fresh = Fold(p)
        folds[id] = fresh
        generation += 1
        return fresh
    }

    // The stored rows folded into shows, walked once and walked again only when a row joined, left, or had
    // a folded field change since. The walk is the expensive half of the ambiguous URL rule (a pairwise
    // title test per URL), and before this it was repeated, identically, for every source of a landing.
    // Every row's fold is re-checked first, which is what notices an in place write.
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
