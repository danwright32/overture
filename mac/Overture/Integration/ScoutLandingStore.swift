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
//     on every read. #4334 (A5): the one delete on the landing path is the failure path revert's, of the
//     rows a failed source inserted and no save carried (`revertFailedSave`). Those are taken out of the
//     working set by name (`discarded(_:)`) rather than left to the deletion filter, because once the save
//     after the delete has run `isDeleted` reads false again and the filter would hand the row back.
//   - EVERY FOLD is re-derived when the raw fields it came from change. A cached fold is compared against
//     the four raw fields it was built from (title, venue, listing URL, run URLs), and folded again on any
//     difference. So an in place write by an earlier source, or by an earlier event of the same source, is
//     seen without any call site having to remember to announce it.
//   - EVERY KEYED LOOKUP (`stored(key:)`, what `Prospect.stored(key:in:)` answers from the database) is
//     answered from a natural key index over the same membership, so it takes the landing's inserts, drops
//     deleted rows, and follows a key moved in place, exactly as the fetch it replaces would.
//   - EVERY STORE WIDE ANSWER a source asks for (the production token poison, the room spellings and the
//     ambiguous URLs) is answered from tables of the stored rows built once and kept current from the same
//     written rows, plus the joins and the revert's deletes (#4333, `LandingBatchTables`), so a source walks
//     its own batch and what changed since the source before it, never every stored row again.
//   - EVERY PER EVENT MATCH ARM (#4460: the concert identity, run URL, production token and stable source
//     arms, and the arrival notes) is handed only the rows carrying one of the show's own keys, from the same
//     tables (`rows(_:)`), never every stored row, so a landing of N new shows no longer walks the store N times.
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
// can write the store while it runs, so the landing's own inserts, and the failure path revert's deletes of
// those same inserts (#4334), are the only changes a fresh fetch could see that the working set does not
// already hold. Both callers build it immediately before their landing loop (`runScout`,
// `ScoutExtractIngest.ingest`), never before the reads that await.
//
// A READ THAT FAILS is not cached. The first call that needs the rows fetches them; if that throws, the
// error goes to that caller exactly as the fetch it replaces would have thrown, and the next caller tries
// again. So a transient failure costs what it touched and no more, which is what separate per read
// fetches gave, and a working set never stands in for rows it could not read (L215).
@MainActor
final class ScoutLandingStore {
    // How the rows are read. The default is the store; a test injects one that counts, or that fails.
    typealias Read = (ModelContext) throws -> [Prospect]
    // #4332 (A3): the same read, safe to call off the main actor, which is how both scout entry points take
    // it: the brand corpus calls it on a background context, the working set on the main one.
    typealias SendableRead = @Sendable (ModelContext) throws -> [Prospect]
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
    // The next rank to hand out. Its own counter rather than `rank.count`, because a row the revert takes
    // out of the working set leaves a gap that a count would fill with a rank another row already holds.
    private var nextRank = 0
    private let saveWatch = SaveWatch()
    // #4327 step 0.7 (RC4): what this working set did, counted, so what each source costs is a measurement
    // and not a reading of this file. Cumulative over the landing; the difference of two snapshots is what the
    // work between them cost, which is how the landing attribution probe reports each source. Counting only:
    // nothing here reads a counter.
    struct Counters: Equatable, Sendable {
        // The label an ingest reports its last snapshot under, taken after the reconcile's read.
        static let afterReconcile = "reconcile"
        // #4333: the batch tables built from every row, which a landing does once, and the rows whose part in
        // them was judged again because SwiftData named them as written, they joined, or they were reverted.
        var tableBuilds = 0
        var tableRowsRejudged = 0
        // Folds taken, by the site that took them: a row folded for the FIRST time (`fold(of:)` with nothing
        // cached), a cached fold that no longer described its row (`fold(of:)`, a written field), and a row the
        // landing inserted (`inserted(_:)`).
        var firstFolds = 0
        var foldsChanged = 0
        var rowsJoined = 0
        // Cached folds compared against their row, because SwiftData named the row as written (#4275).
        var foldValidations = 0
        // Store rows VISITED. `rowsRead` is the rows the one fetch returned. `rowsHandedOut` is the rows every
        // caller of `rows()` was given, each of which walks what it is given. `rowsWalked` is the working
        // set's own walks over every row: the deletion filter, the key index build, and the batch tables build.
        var rowsRead = 0
        var rowsHandedOut = 0
        var rowsWalked = 0
        // #4460: rows a per event match arm was handed from the rows on its keys (`rows(_:)`), in place of
        // every stored row. A lookup that had to take the walk counts in `rowsHandedOut`, as the walk always did.
        var rowsLookedUp = 0

        static func - (a: Counters, b: Counters) -> Counters {
            Counters(tableBuilds: a.tableBuilds - b.tableBuilds,
                     tableRowsRejudged: a.tableRowsRejudged - b.tableRowsRejudged,
                     firstFolds: a.firstFolds - b.firstFolds,
                     foldsChanged: a.foldsChanged - b.foldsChanged,
                     rowsJoined: a.rowsJoined - b.rowsJoined,
                     foldValidations: a.foldValidations - b.foldValidations,
                     rowsRead: a.rowsRead - b.rowsRead,
                     rowsHandedOut: a.rowsHandedOut - b.rowsHandedOut,
                     rowsWalked: a.rowsWalked - b.rowsWalked,
                     rowsLookedUp: a.rowsLookedUp - b.rowsLookedUp)
        }
    }
    private(set) var counters = Counters()
    // How many cached folds were compared against their row. Counted so a test can pin that it does not
    // grow with the store (#4275).
    var foldValidations: Int { counters.foldValidations }

    // #4333 (A4): the stored rows' half of the poison, spelling and ambiguity passes (`LandingBatchTables`),
    // built from every row the first time a source asks and kept current after that from a CHANGE FEED: the
    // rows SwiftData names as written (`noteWrittenRows`, the same feed the folds and the key index read),
    // the rows this landing inserts (`inserted(_:)`), the rows a failed save's revert put back
    // (`revertFailedSave`), and the rows it deleted (`discarded(_:)`). Each source then re-judges only those
    // rows, and asks only about the keys its own batch carries.
    private var tables: LandingBatchTables?
    private var tablesToCheck: [ObjectIdentifier: Prospect] = [:]
    // A row that joined since the last re-judgement, and its place in the tables' order: after every row
    // already there, in the order inserted, which is the order `loaded` holds them in.
    private var joinOrder: [ObjectIdentifier: Int] = [:]
    private var nextTableOrder = 0
    // #4460: the row behind each identifier the tables hold, so a keyed lookup can hand back the rows it found.
    // Kept beside the tables: filled by their build and by every join, emptied by the revert's deletes.
    private var tableRows: [ObjectIdentifier: Prospect] = [:]
    // #4460: every field a row's contribution is built from, as it stood when the row was last judged, so a row
    // named as written that nothing has changed is not rebuilt. The four folded fields come from the row's fold
    // (already compared against the row by `fold(of:)`), so no archived field is decoded twice.
    // It is the contribution's ONLY input beside the fold (`contribution(of:_:)` takes it, never the row), so a field
    // the contribution comes to read has to be added here first, and the unchanged check cannot fall behind the
    // contribution it guards (lessons review of #4460: a second hand written list would, L41).
    private struct Judged: Equatable {
        var groupName = "", venue: String?, listing: String?, runs: [String] = []
        var seriesId: String?, night: String?, sourceIds: [String] = []
        var isDeleted = false
        static let deleted = Judged(isDeleted: true)
        init(isDeleted: Bool) { self.isDeleted = isDeleted }
        init(_ p: Prospect, _ folded: Fold) {
            groupName = folded.groupName; venue = folded.venue; listing = folded.sourceListingURL
            runs = folded.runSourceURLs; seriesId = p.seriesId; night = p.performanceDate; sourceIds = p.sourceIds
        }
    }
    private var judged: [ObjectIdentifier: Judged] = [:]

    // #4325: the reconcile writes of this landing that no save has carried yet, oldest first. A successful
    // save of this context empties it (`didSave`, below), whoever saved, so what is left at the closing save
    // is exactly what that save would carry for the reconcile, and exactly what a failed one must put back.
    private(set) var unsavedReconcileWrites: [FeedReconcile.Writes] = []
    // #4334: the same rows as each of those, with the values the reconcile LEFT them holding, so the revert
    // of a later source's failed save can put an earlier source's pending reconcile back after restoring the
    // committed values underneath it.
    private var unsavedReconcileResults: [FeedReconcile.Writes] = []
    private let reconcileSaveWatch = SaveWatch()

    func noteReconcile(_ writes: FeedReconcile.Writes) {
        guard !writes.isEmpty else { return }
        unsavedReconcileWrites.append(writes)
        unsavedReconcileResults.append(FeedReconcile.Writes(entries: writes.entries.map {
            FeedReconcile.Writes.Entry(show: $0.show, missedScoutCount: $0.show.missedScoutCount,
                                       survivedMergeAt: $0.show.survivedMergeAt,
                                       mergeSurvivorUnseenAt: $0.show.mergeSurvivorUnseenAt)
        }))
    }

    // Called after a save the landing made itself, which a test may inject and so post no `didSave`.
    func reconcileWritesSaved() { saved() }

    // Everything this landing tracks about writes no save has carried yet, emptied by a save that succeeded.
    private func saved() {
        unsavedReconcileWrites = []
        unsavedReconcileResults = []
        settledSinceSave = []
        savingWriteSet = nil
    }

    // #4334 (A5): the save every landing source makes, and how its failure is classified, injected so a test
    // can fail one source's save and not the next (a real refusal fails every save the container makes).
    let saveSource: (ModelContext) throws -> Void
    let classify: (Error) -> LandingSaveFailure.Scope
    // The pending set as the most recent save began (`willSave`), which is what a save that then failed was
    // carrying. Emptied by a save that succeeded.
    private var savingWriteSet: LandingRevert.WriteSet?
    private let writeSetWatch = SaveWatch()
    // The rows the settled slots (a source that failed, was unchanged, or was confirmed quiet) wrote since the
    // previous save. Not part of the next source's turn, so a failure of that source's save leaves them
    // pending for the save after it.
    private var settledSinceSave: Set<PersistentIdentifier> = []

    func noteSettled(_ row: any PersistentModel) { settledSinceSave.insert(row.persistentModelID) }

    // #4331 (A2): the stamp rule, the next apply ordinal, and the merge candidate index. See `IngestedAtStamp`.
    let stampRule: IngestedAtStamp.Rule
    private var nextOrdinal = 0
    private var candidates: MergeCandidateIndex?
    // Rows SwiftData has named as written, or the landing has inserted, since the index last looked at them.
    private var candidatesToCheck: [ObjectIdentifier: Prospect] = [:]
    // Rows this landing touched and did not change, and that had no twin when touched, with the stamp each
    // would have taken then. Asked again at the end of every later apply, in case a later write gave one a twin.
    private var unstamped: [ObjectIdentifier: (row: Prospect, stamp: Date)] = [:]

    // The stamp of the next row this landing applies: its `now` plus the apply ordinal, in microseconds.
    func nextStamp(at now: Date) -> Date {
        defer { nextOrdinal += 1 }
        return IngestedAtStamp.at(now, ordinal: nextOrdinal)
    }

    // A stored row the landing has just applied an event to. Stamped when the apply changed it, or when it
    // shares a merge reader's candidate key with another row (or the index cannot be read, which stamps, as
    // every row was stamped before #4331: an unreadable answer must not pass for "no twin", L215).
    func stampTouched(_ p: Prospect, changed: Bool, at now: Date) {
        let stamp = nextStamp(at: now)
        let id = ObjectIdentifier(p)
        unstamped[id] = nil
        if changed || stampRule == .everyTouch || hasATwin(p) {
            p.ingestedAt = stamp
        } else {
            unstamped[id] = (row: p, stamp: stamp)
        }
    }

    // Run at the end of every apply, before its save: a row left unstamped when touched is stamped, with the
    // stamp it would have taken then, if a write since has given it a twin.
    func stampRowsGivenATwin() {
        guard !unstamped.isEmpty else { candidates?.forgetJoined(); return }
        let index = try? candidateIndex()
        for (id, entry) in unstamped {
            if entry.row.isDeleted { unstamped[id] = nil; continue }
            let twin: Bool
            if let index {
                // The reference policy asks the whole question again over a fresh index; the working set asks
                // only about the rows that joined since, which the equality tests hold to the same answer.
                twin = policy == .everyRead ? index.isContested(entry.row) : index.isContestedByARowThatJoined(entry.row)
            } else {
                twin = true
            }
            if twin {
                entry.row.ingestedAt = entry.stamp
                unstamped[id] = nil
            }
        }
        index?.forgetJoined()
    }

    private func hasATwin(_ p: Prospect) -> Bool {
        guard let index = try? candidateIndex() else { return true }
        return index.isContested(p)
    }

    private func candidateIndex() throws -> MergeCandidateIndex {
        let rows = try currentRows()
        if policy == .everyRead { return MergeCandidateIndex(rows: rows, tokens: { Fold($0).tokens }) }
        if let candidates {
            for (_, p) in candidatesToCheck {
                if p.isDeleted { candidates.remove(p) } else { candidates.update(p, tokens: fold(of: p).tokens) }
            }
            candidatesToCheck = [:]
            return candidates
        }
        let built = MergeCandidateIndex(rows: rows, tokens: { self.fold(of: $0).tokens })
        candidates = built
        candidatesToCheck = [:]
        return built
    }

    // #4334 (A5): puts back what a failed save was carrying, through `LandingRevert` (committed values read
    // through a fresh context, pending inserts deleted, never `rollback()`), and takes the deleted inserts out
    // of the working set.
    //
    // A SOURCE's save (`closing: false`) is put back as that source's turn: the pending set at the failed
    // save minus the rows the settled slots wrote since the previous save, which stay pending; and the
    // reconcile an EARLIER source made, still pending under it, is put back on top afterwards, so the only
    // thing the revert removes is the failed source's own writes. A CLOSING save (`closing: true`) is put
    // back whole, its reconcile included, because there is no later save in this landing to carry any of it.
    //
    // Whatever the revert could not restore is in the report's `notRestorable`; the caller stops the landing
    // on it, by name, rather than carry on over rows it could not put back.
    @discardableResult
    func revertFailedSave(closing: Bool) -> LandingRevert.Report {
        // #4335: the capture AND what is pending now. A capture can outlive the save that made it when that save
        // carried nothing (a recovery re-applies a source it already landed, which writes nothing new), and the
        // source whose injected save failed next was then never put back: found by
        // `LandingRecoveryTests.aRecoveryThatKeepsFailingStopsAfterTheCap`. After a real failed save the two are
        // equal (#4334's probe), so this changes nothing there.
        let pendingNow = LandingRevert.WriteSet.pending(in: context)
        let carried = savingWriteSet.map { $0.adding(pendingNow) } ?? pendingNow
        savingWriteSet = nil
        let set = closing ? carried : carried.excluding(settledSinceSave)
        let earlierReconciles = closing ? [] : unsavedReconcileResults
        let report = LandingRevert.revert(set, in: context)
        discarded(set.inserted.compactMap { $0 as? Prospect })
        // #4333: a row the revert put back was written by it, whatever SwiftData lists afterwards, so its fold,
        // its key and its part in the batch tables are all judged again on the next read.
        for case let p as Prospect in set.changed { markWritten(p) }
        if closing {
            unsavedReconcileWrites = []
            unsavedReconcileResults = []
            settledSinceSave = []
        } else {
            for results in earlierReconciles { results.revert() }
        }
        return report
    }

    // #4334: rows the landing inserted and then deleted (the failure path revert), taken out of every table
    // the working set keeps, so neither `rows()` nor `stored(key:)` can hand one back.
    func discarded(_ rows: [Prospect]) {
        guard !rows.isEmpty else { return }
        let ids = Set(rows.map { ObjectIdentifier($0) })
        loaded?.removeAll { ids.contains(ObjectIdentifier($0)) }
        members = nil
        for p in rows {
            let id = ObjectIdentifier(p)
            candidates?.remove(p)
            candidatesToCheck[id] = nil
            unstamped[id] = nil
            unindex(p)
            position[id] = nil
            folds[id] = nil
            foldsToCheck.remove(id)
            keysToCheck[id] = nil
            rank[id] = nil
            tables?.remove(id)
            tablesToCheck[id] = nil
            joinOrder[id] = nil
            tableRows[id] = nil
            judged[id] = nil
            // #4482: a discarded row's identifier can be handed to a later object once nothing holds it, and a
            // watched identifier is never marked, so it is forgotten with the row.
            watched.remove(id)
        }
    }

    init(context: ModelContext, read: @escaping Read = ScoutService.readProspectTable,
         readKey: @escaping ReadKey = { try Prospect.stored(key: $0, in: $1) },
         policy: Policy = .once,
         saveSource: @escaping (ModelContext) throws -> Void = { try $0.save() },
         classify: @escaping (Error) -> LandingSaveFailure.Scope = LandingSaveFailure.classify,
         stampRule: IngestedAtStamp.Rule = .whenChanged) {
        self.context = context
        self.stampRule = stampRule
        self.read = read
        self.readKey = readKey
        self.policy = policy
        self.saveSource = saveSource
        self.classify = classify
        // #4325: for both policies, since both land. Posted only for a save that succeeded.
        reconcileSaveWatch.token = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: context, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.saved() }
        }
        // #4334: what each save is carrying, as it begins, for both policies, so a save that fails can be put
        // back. Posted synchronously by `save()` on the saving thread, which for the main context is this actor.
        writeSetWatch.token = NotificationCenter.default.addObserver(
            forName: ModelContext.willSave, object: context, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.savingWriteSet = .pending(in: self.context)
            }
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
    //
    // #4482: and only ONCE per write. SwiftData keeps naming a row as written until its source saves, and the
    // per event arms read several times an event, so marking every named row on every read re-checked each of a
    // source's unsaved rows on every read: square in the batch. A row marked here is WATCHED (`watch(_:)`): it is
    // not marked again until one of the fields the working set derives from it is written, which the watch hears
    // through the row's own observation, so a second write before the save is still seen.
    private func noteWrittenRows() {
        guard loaded != nil, context.hasChanges else { return }
        for id in writeWatch.takeWritten() { watched.remove(id) }
        for model in context.changedModelsArray + context.insertedModelsArray {
            guard let p = model as? Prospect else { continue }
            if watched.contains(ObjectIdentifier(p)) { continue }
            markWritten(p)
            watch(p)
        }
    }

    // #4482: rows marked and not written since, and the rows whose watch has heard a write. The watch's
    // `onChange` fires on whatever thread wrote, so what it heard is behind a lock (as `ScopeMemo`'s flag is).
    private var watched: Set<ObjectIdentifier> = []
    private let writeWatch = WriteWatch()
    private final class WriteWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var written: Set<ObjectIdentifier> = []
        func heard(_ id: ObjectIdentifier) { lock.lock(); written.insert(id); lock.unlock() }
        func takeWritten() -> Set<ObjectIdentifier> {
            lock.lock(); defer { written = []; lock.unlock() }
            return written
        }
    }

    // Watches every field the working set derives from this row: the fold's, the batch tables', the natural key
    // index's and the merge candidate index's, read here by the SAME derivations those consumers run, so a field
    // one of them comes to read is watched without being listed twice (L370). Fires once, on the next write, and
    // is renewed when the row is next marked. A watch that never fires stays on its row until the row's next
    // write, one per row a landing wrote; the reason per row observation was rejected for EVERY row (#4275) does
    // not apply to these few.
    private func watch(_ p: Prospect) {
        let id = ObjectIdentifier(p)
        watched.insert(id)
        withObservationTracking {
            _ = Fold(p)
            _ = Self.contribution(of: p, Fold(p))
            _ = p.naturalKey
            _ = MergeCandidateIndex.keys(of: p, tokens: [])
        } onChange: { [writeWatch] in
            writeWatch.heard(id)
        }
    }

    private func markWritten(_ p: Prospect) {
        let id = ObjectIdentifier(p)
        foldsToCheck.insert(id)
        keysToCheck[id] = p
        if tables != nil { tablesToCheck[id] = p }
        // #4331: the merge candidate index judges the same written rows again (a re-key or a reverted title
        // can make or break a twin), once the index exists; before then it is built fresh from the store.
        if candidates != nil { candidatesToCheck[id] = p }
    }

    // Every stored show a fresh fetch would return right now, in this landing's order. Throws when the store
    // cannot answer.
    func rows() throws -> [Prospect] {
        let current = try currentRows()
        counters.rowsHandedOut += current.count
        return current
    }

    // `rows()` without counting the rows as handed to a caller, for the working set's own reads.
    private func currentRows() throws -> [Prospect] {
        if policy == .everyRead { return ranked(try read(context)) }
        if let loaded {
            noteWrittenRows()
            // Re-filtering every row on every read was, once keyed lookups came here, a larger cost than the
            // keyed fetch it replaced (measured on the #4275 probe, Debug). So the filtered list is kept, and
            // used only while no deletion is pending, which is what makes it the answer the filter would give.
            let deletionPending = context.hasChanges && !context.deletedModelsArray.isEmpty
            if let members, !deletionPending { return members }
            counters.rowsWalked += loaded.count
            let current = loaded.filter { !$0.isDeleted }
            members = deletionPending ? nil : current
            return current
        }
        // #4397: held in the landing's own order, never the read's. Every first match the landing makes reads
        // this array, and an unsorted fetch on a context with unsaved changes comes back in a different order
        // each time.
        let fetched = ranked(try read(context))
        counters.rowsRead += fetched.count
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
        rank[ObjectIdentifier(p)] = (row: p, rank: nextRank)
        nextRank += 1
    }

    // A row this landing has just put into the context. Before the first read there is nothing to add it
    // to, and the read that follows will return it, because a fetch includes unsaved inserts.
    func inserted(_ p: Prospect) {
        // Ranked under both policies once anything has been read, so a fresh read places it where `.once` does.
        if !rank.isEmpty, rank[ObjectIdentifier(p)] == nil { rankNext(p) }
        guard policy == .once, loaded != nil else { return }
        loaded?.append(p)
        members = nil
        counters.rowsJoined += 1
        if keyIndex != nil { index(p, at: (loaded?.count ?? 1) - 1) }
        if tables != nil {
            let id = ObjectIdentifier(p)
            joinOrder[id] = nextTableOrder
            nextTableOrder += 1
            tablesToCheck[id] = p
            tableRows[id] = p
        }
        if candidates != nil { candidatesToCheck[ObjectIdentifier(p)] = p }
    }

    // The stored row holding a natural key, or nil when nobody holds it: what `Prospect.stored(key:in:)`
    // answers from the database, answered from the working set. Throws when the store cannot answer, as the
    // fetch does, because "could not read" and "the key is free" are the same nil to every caller and only
    // one of them is safe to write a unique key on (#2754, L105).
    func stored(key: String) throws -> Prospect? {
        if policy == .everyRead { return try readKey(key, context) }
        // The rows are loaded once; after that only what was written is asked about. A deleted row stays in
        // the index and is refused below, so no read of every row's `isDeleted` is needed here.
        if loaded == nil { _ = try currentRows() } else { noteWrittenRows() }
        if keyIndex == nil {
            keyIndex = [:]
            keysToCheck = [:]
            counters.rowsWalked += loaded?.count ?? 0
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
            counters.foldValidations += 1
            if cached.describes(p) { return cached }
            counters.foldsChanged += 1
        } else {
            counters.firstFolds += 1
        }
        let fresh = Fold(p)
        folds[id] = fresh
        return fresh
    }

    // MARK: the batch tables (#4333, A4)

    // Each source's three store wide answers: the stored rows' half from the tables, continued with the
    // source's own batch, which is exactly what the walk over every stored row and then the batch answers
    // (`LandingBatchTables`, where the reason each rule takes the structure it does is written). Under
    // `.everyRead` each is that walk itself (`ScoutService`'s from-scratch functions), so the reference the
    // equality tests compare against stays the code that ran before #4333. Each throws when the store cannot
    // answer, exactly as the walk did, and the caller decides the direction (L215).
    func poisonedTokens(adding incoming: [AssembledProspect]) throws -> Set<String> {
        if policy == .everyRead {
            return try ScoutService.poisonedTokensForBatch(incoming, storedRows: { try rows() })
        }
        return try currentTables().poisoned(adding: Self.tokens(ScoutService.poisonEntries(of: incoming)))
    }

    func ambiguousURLs(adding incoming: [AssembledProspect]) throws -> ScoutService.AmbiguousURLs {
        if policy == .everyRead {
            return try ScoutService.ambiguousURLsForBatch(incoming, storedRows: { try rows() })
        }
        let tables = try currentTables()
        let links = Self.links(ScoutService.ambiguityEntries(of: incoming))
        return ScoutService.AmbiguousURLs(atAVenue: tables.atAVenue.answer(adding: links),
                                          anywhere: tables.anywhere.answer(adding: links))
    }

    // #4460: the stored rows a per event match arm could match, in this landing's order: the rows carrying one
    // of the show's own keys, from the batch tables, in place of every stored row. The arm applies its own
    // predicate to them unchanged, and every row that predicate could accept carries one of these keys, so the
    // first match, and every filter, is the one the walk found. Under `.everyRead` it IS the walk (every row,
    // freshly read), so the reference the equality tests compare against stays the code before #4460.
    //
    // An empty URL is the one empty key a stored row can carry (a blank listing URL folds to itself), and the
    // tables key no empty URL, so a lookup naming one takes the walk rather than miss that row. Throws when
    // the store cannot answer, exactly as the walk did, so the arm refuses the show (L215).
    func rows(_ lookup: LandingBatchTables.Lookup) throws -> [Prospect] {
        if policy == .everyRead { return try rows() }
        if case .sharingURL(let urls) = lookup, urls.contains("") { return try rows() }
        let tables = try currentTables()
        let found = tables.rows(lookup).compactMap { tableRows[$0] }.filter { !$0.isDeleted }
        counters.rowsLookedUp += found.count
        return found
    }

    #if DEBUG
    // The walk `rows(_:)` replaced, for the tests' comparison: every row a fresh read returns that carries one of
    // the lookup's keys, read off a FRESH fold of the row (never the cached one), in this landing's order.
    func walkedRows(_ lookup: LandingBatchTables.Lookup) throws -> [Prospect] {
        try currentRows().filter { p in
            let folded = Fold(p)
            switch lookup {
            case .sharingURL(let urls): return !folded.allURLFolds.isDisjoint(with: urls)
            case .sharingToken(let tokens): return !Set(folded.tokens).isDisjoint(with: tokens)
            case .series(let id): return p.seriesId == id
            case .night(let night): return p.performanceDate == night
            case .ownedBy(let owners): return !Set(p.sourceIds).isDisjoint(with: owners)
            }
        }
    }
    #endif

    // #4475: the stored rows a reconcile of these reports could change, in this landing's order, in place of every
    // stored row. `FeedReconcile.reconcile` changes a row only when a report LISTS it (its natural key among the
    // seen keys, one of its links among the seen links, or a structural gap on its night under one of the
    // report's sources) or when every source owning it was asked and none had it. Each of those needs the row to
    // hold a seen key, carry a seen link, or be owned by a report's source, so every row it can change is here,
    // and the reconcile still decides each one exactly as it did. Rows it cannot change are left out, which is
    // what stops runScout's per source reconcile walking the whole store once a source (#4475).
    //
    // Under `.everyRead` it is every row, freshly read, so the reference stays the code before #4475. Throws when
    // the store cannot answer, exactly as the read of every row did, so the caller names the failure (#4474).
    func rows(reconciledBy reports: [FeedReconcile.SourceReport]) throws -> [Prospect] {
        if policy == .everyRead { return try rows() }
        // The links folded the way the URL lists are keyed: a row whose raw link is a seen link folds to the same
        // key, so the lookup holds every row the reconcile's raw comparison can match, and the reconcile decides.
        let links = Set(reports.flatMap(\.seenSourceURLs).map(ListingURL.fold))
        var found = try rows(.sharingURL(links)) + rows(.ownedBy(Set(reports.map(\.sourceId))))
        for key in Set(reports.flatMap(\.seenKeys)) { found += try rowsHolding(key: key) }
        let tables = try currentTables()
        var seen: Set<ObjectIdentifier> = []
        let unique = found.filter { seen.insert(ObjectIdentifier($0)).inserted }
        return unique.sorted {
            (tables.order(of: ObjectIdentifier($0)) ?? .max) < (tables.order(of: ObjectIdentifier($1)) ?? .max)
        }
    }

    // Every row holding this natural key, from the key index brought current. Compared as Swift compares
    // strings, as the reconcile's `seenKeys.contains` does, rather than as bytes, which `stored(key:)` uses for
    // a write: a lookup that matched fewer rows than the reconcile would leave a listed row unreset.
    private func rowsHolding(key: String) throws -> [Prospect] {
        _ = try stored(key: key)
        let held = (keyIndex?[key] ?? []).filter { !$0.isDeleted }
        counters.rowsLookedUp += held.count
        return held
    }

    // How the stored rows have spelled their rooms, per source id, for `VenueSpellingLock.locked`.
    struct VenueSpellings {
        fileprivate let lookup: ([String]) -> [String]
        func used(by sourceIds: [String]) -> [String] { lookup(sourceIds) }
    }

    func venueSpellings() throws -> VenueSpellings {
        if policy == .everyRead {
            // The walk #1848 made over every stored row, once per batch.
            var bySource: [String: [String]] = [:]
            for row in try rows() {
                guard let venue = row.venue, !venue.isEmpty else { continue }
                for id in row.sourceIds { bySource[id, default: []].append(venue) }
            }
            return VenueSpellings(lookup: { ids in ids.flatMap { bySource[$0] ?? [] } })
        }
        let tables = try currentTables()
        return VenueSpellings(lookup: { tables.spellings(usedBy: $0) })
    }

    #if DEBUG
    // The tables as they stand, brought current, and the same tables rebuilt now from every row with a FRESH
    // fold of each (never the cached one), as two snapshots: what the tests compare after each source. Debug
    // only, so no shipping build carries a whole store rebuild.
    func batchTablesSnapshot() throws -> LandingBatchTables.Snapshot {
        try currentTables().snapshot(naming: { String(describing: $0) })
    }

    func rebuiltBatchTablesSnapshot() throws -> LandingBatchTables.Snapshot {
        let rows = try currentRows()
        return LandingBatchTables.rebuilt(rows.map { (ObjectIdentifier($0), Self.contribution(of: $0, Fold($0))) })
            .snapshot(naming: { String(describing: $0) })
    }

    // #4512: the table build's loop over these rows, in its parts, each summed over every row in nanoseconds:
    // the fold, the row's judged fields, the contribution built from them, and the table write. The probe
    // reads it to attribute the build; it writes nothing the landing keeps. Debug only.
    static func buildPartsNanoseconds(_ rows: [Prospect], clock: () -> UInt64) -> [String: UInt64] {
        var parts: [String: UInt64] = ["fold": 0, "judged": 0, "contribution": 0, "set": 0]
        var built = LandingBatchTables()
        for (i, p) in rows.enumerated() {
            var t = clock()
            let folded = Fold(p)
            parts["fold", default: 0] += clock() &- t
            t = clock()
            let judged = Judged(p, folded)
            parts["judged", default: 0] += clock() &- t
            t = clock()
            let c = contribution(of: judged, folded)
            parts["contribution", default: 0] += clock() &- t
            t = clock()
            built.set(ObjectIdentifier(p), order: i, to: c)
            parts["set", default: 0] += clock() &- t
        }
        return parts
    }
    #endif

    // Tables that should exist and do not: never answered as empty, which would poison nothing and call no
    // URL ambiguous, so the caller takes its could-not-read direction instead (L42, L215).
    struct TablesMissing: Error {}

    // The tables, built from every row the first time and brought current after that from the change feed.
    // Changed IN PLACE through `self.tables`, never through a local copy: a copy would make the first change
    // duplicate every table, which is the store sized cost this exists to remove (#4333 review).
    private func currentTables() throws -> LandingBatchTables {
        if tables == nil {
            let current = try currentRows()
            counters.tableBuilds += 1
            counters.rowsWalked += current.count
            var built = LandingBatchTables()
            for (i, p) in current.enumerated() {
                let folded = fold(of: p)
                // The row's judged fields read once, for its contribution and for the unchanged check alike.
                let now = Judged(p, folded)
                built.set(ObjectIdentifier(p), order: i, to: Self.contribution(of: now, folded))
                tableRows[ObjectIdentifier(p)] = p
                judged[ObjectIdentifier(p)] = now
            }
            nextTableOrder = current.count
            tablesToCheck = [:]
            joinOrder = [:]
            tables = built
        } else {
            noteWrittenRows()
            // A deletion still pending is out of every read (`currentRows` filters it), so out of the tables too.
            if context.hasChanges {
                for case let p as Prospect in context.deletedModelsArray { tablesToCheck[ObjectIdentifier(p)] = p }
            }
            let pending = tablesToCheck
            let joins = joinOrder
            tablesToCheck = [:]
            joinOrder = [:]
            for (id, p) in pending {
                // A row the landing does not hold (one nobody announced) is in no read, so in no table.
                guard let order = tables?.order(of: id) ?? joins[id] else { continue }
                // #4460: a row SwiftData still names as written, but whose every field the tables read is as it was
                // when it was last judged, is not judged again. An unsaved insert stays in the inserted list until
                // its source saves, and the per event arms read the tables several times an event, so without this
                // every insert of a source was rebuilt on every read: square in the batch (measured, 601 visits
                // for sixteen new shows against 31 for four). Its fold is still validated, as before.
                let folded = p.isDeleted ? nil : fold(of: p)
                let now = folded.map { Judged(p, $0) } ?? Judged.deleted
                if joins[id] == nil, judged[id] == now { continue }
                counters.tableRowsRejudged += 1
                let value = folded.map { Self.contribution(of: now, $0) } ?? LandingBatchTables.Contribution.none
                tables?.set(id, order: order, to: value)
                judged[id] = now
            }
        }
        guard let tables else { throw TablesMissing() }
        return tables
    }

    // One row's part in each pass, from the SAME entry builders the from-scratch walks use (L370). Built from the
    // row's `Judged` fields and its fold, never the row itself, so the unchanged check reads what this reads.
    private static func contribution(of row: Judged, _ folded: Fold) -> LandingBatchTables.Contribution {
        var c = LandingBatchTables.Contribution()
        c.tokens = Set(tokens(ScoutService.poisonEntries(of: folded)))
        c.urls = links(ScoutService.ambiguityEntries(of: folded)).sorted { $0.url < $1.url }
        // #1848's walk reads the row's own venue and source ids, which no fold carries.
        if let venue = row.venue, !venue.isEmpty {
            c.spellings = row.sourceIds.map { .init(sourceId: $0, venue: venue) }
        }
        // #4460: the two keys the concert identity arm and the arrival notes ask by, which no fold carries.
        if let id = row.seriesId, !id.isEmpty { c.seriesId = id }
        if let night = row.night, !night.isEmpty { c.night = night }
        // #4475: whoever owns the row, for the reconcile.
        c.owners = Set(row.sourceIds)
        return c
    }

    private static func contribution(of p: Prospect, _ folded: Fold) -> LandingBatchTables.Contribution {
        contribution(of: Judged(p, folded), folded)
    }

    private static func tokens(_ entries: [(token: String, title: String, venue: String)])
        -> [LandingBatchTables.Contribution.Token] {
        entries.map { .init(token: $0.token, title: $0.title, venue: $0.venue) }
    }

    private static func links(_ entries: [(url: String, title: String, venue: String)])
        -> [LandingBatchTables.Contribution.Link] {
        entries.map { .init(url: $0.url, title: $0.title, venue: $0.venue) }
    }
}
