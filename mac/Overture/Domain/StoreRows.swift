import Foundation
import SwiftData

// #4107: the rows ONE reconcile tick reads, fetched once and handed to every pass in it.
//
// Measured 2026-09-21 (`KEPT-chunk-1790016122.txt`, 603 main thread samples under the scheduled tick):
// the tick's main actor time was not the network. Every Gmail and OmniFocus call was already an `await`
// that gave the main actor back while it waited, and none of them shows in the sample. What held the
// main actor was the same whole store fetch, `FetchDescriptor<Prospect>()`, made again by each pass:
// 94 samples inside the reply search, 94 inside the proposal sweep, 81 inside the threading repair, 91
// inside the OmniFocus push and 91 for the tick's own closing diff, roughly 90 each, about three quarters
// of everything the tick held. The same rows, bought five times over.
//
// So the tick fetches them once, here, and every pass reads this instead of fetching its own. A pass
// called on its own (a button, a test) still fetches for itself: `rows` is an optional parameter on each,
// and nil means "fetch them", which is a complete answer rather than a missing one.
//
// The rows are held across the tick's awaits, and another writer (a scout merging duplicates, Dan
// removing a contact) can delete one meanwhile. A pass must not act on a row that is gone, so every read
// goes through `liveProspects` / `liveInquiries`, which drop what was deleted since the fetch. (Measured in
// the tests for this: a write to a contact deleted and saved mid await was silently dropped rather than
// crashing. That is SwiftData's behaviour to change, not something to lean on.)
// A pass that awaits must read them AFTER its await, not before, since the await is when the deleting
// happens. Rows INSERTED mid tick are not in here; the next tick sees them, and the tick's closing badge
// count fetches afresh so it never states a number the store does not hold.
@MainActor
struct StoreRows {
    let prospects: [Prospect]
    let inquiries: [Inquiry]

    init(prospects: [Prospect], inquiries: [Inquiry]) {
        self.prospects = prospects
        self.inquiries = inquiries
    }

    // `try?` on the inquiries keeps a container that predates Inquiry (an older test harness) working: it
    // yields none, the same allowance every pass made for itself before this existed.
    static func fetch(from context: ModelContext) -> StoreRows {
        StoreRows(prospects: (try? context.fetch(FetchDescriptor<Prospect>())) ?? [],
                  inquiries: (try? context.fetch(FetchDescriptor<Inquiry>())) ?? [])
    }

    var liveProspects: [Prospect] { prospects.filter(Self.isLive) }
    var liveInquiries: [Inquiry] { inquiries.filter(Self.isLive) }

    // Deleted and not yet saved reads `isDeleted`; deleted and saved has lost its context. Either way it is
    // no longer a row anybody should write to.
    static func isLive(_ model: some PersistentModel) -> Bool {
        !model.isDeleted && model.modelContext != nil
    }

    // The same question about a row a pass holds as a protocol (a recipient or an inquiry seen as
    // something to watch or search for). Every such row is a stored model; one that somehow is not has
    // nothing that can be deleted from under it, so it reads as live.
    static func isLiveRow(_ row: AnyObject) -> Bool {
        guard let model = row as? any PersistentModel else { return true }
        return isLive(model)
    }
}

// #4250: what the tick's closing count needs from the store, as VALUES, so it can be read off the main actor.
//
// Measured 2026-09-25 against a clone of the live store (1,340 prospects, three rounds within 3%): the
// closing read was a second whole store fetch on the main actor, 189 to 199ms, and deriving the badge
// (`DueWork.counts` plus `nextChange`) over those rows took another 130ms when the rows were fresh. Unlike
// the tick's OPENING read, nothing here writes a row: it counts, names and arms a timer. So it can be read
// through a background `ModelContext` and handed across as values, with no main context object crossing.
//
// The opening read was measured too and stays on the main actor. Every pass writes to the rows it reads,
// so a background read would have to be re-resolved on the main context by identifier, and re-resolving
// all 1,340 on a context that does not already hold them cost 370ms, nearly twice the 190ms read it would
// replace. It is only cheap (2.6ms) when the main context already holds every row, which is true while the
// queue is on screen and nothing guarantees otherwise.
//
// Two limits, stated rather than hidden. A background context reads what is SAVED, so with unsaved changes
// on the main context `read` takes the reading on the main actor as before, and says so in
// `readOnMainThread`, which is what the tick's timeline reports it by. And the reading is a picture of one
// moment: a show deleted between it and the tick's apply is dropped from the away alert there (see
// `ReconcileScheduler.runSafeReconcilesOnce`); the badge count can be one stale until the next tick or
// republish, which is the same staleness any edit made after a tick already has.
struct DueReading: Sendable {
    struct ShowName: Sendable, Equatable {
        let key: String
        let name: String
    }

    let replied: [ShowName]
    let booked: [ShowName]
    let due: DueWork.Counts
    let nextChange: Date?
    let readOnMainThread: Bool

    static func derive(prospects: [Prospect], inquiries: [Inquiry], now: Date, replyRunAlive: Bool) -> DueReading {
        DueReading(
            replied: prospects.filter(ReconcileScheduler.hasNewReply).map { ShowName(key: $0.naturalKey, name: $0.groupName) },
            booked: prospects.filter { $0.outcome == .booked }.map { ShowName(key: $0.naturalKey, name: $0.groupName) },
            due: DueWork.counts(prospects: prospects, inquiries: inquiries, now: now, replyRunAlive: replyRunAlive),
            nextChange: DueWork.nextChange(prospects: prospects, now: now, replyRunAlive: replyRunAlive),
            readOnMainThread: Thread.isMainThread)
    }

    // The reading through a context of its own. Nonisolated and async, so it runs on the global executor,
    // never the main actor; everything it fetches stays inside this function.
    static func readInBackground(container: ModelContainer, now: Date, replyRunAlive: Bool) async -> DueReading {
        let context = ModelContext(container)
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let inquiries = (try? context.fetch(FetchDescriptor<Inquiry>())) ?? []
        return derive(prospects: prospects, inquiries: inquiries, now: now, replyRunAlive: replyRunAlive)
    }

    // Off the main actor when the store holds everything the main context does; on it otherwise.
    @MainActor
    static func read(from context: ModelContext, now: Date, replyRunAlive: Bool) async -> DueReading {
        if context.hasChanges {
            let rows = StoreRows.fetch(from: context)
            return derive(prospects: rows.prospects, inquiries: rows.inquiries, now: now, replyRunAlive: replyRunAlive)
        }
        return await readInBackground(container: context.container, now: now, replyRunAlive: replyRunAlive)
    }
}
