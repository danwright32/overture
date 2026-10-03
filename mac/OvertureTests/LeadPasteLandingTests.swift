import Testing
import Foundation
import SwiftData

// #4339 (A11): the lead paste lands like every other entry point. Its whole table reads (the brand corpus and
// the history it matches against) run off the main thread behind the entry flush, it takes its turn for the
// store at Dan's priority, a whole table read that fails is recorded rather than read as an empty store, and a
// save that fails is put back and said, never left pending and never counted as shows added.
@MainActor
@Suite("#4339 the lead paste lands off the main thread, in turn, and puts back a failed save", .serialized)
struct LeadPasteLandingTests {

    // Thread facts recorded from a background read, so they are lock protected.
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var onMain: [Bool] = []
        func note() { lock.lock(); onMain.append(Thread.isMainThread); lock.unlock() }
        var all: [Bool] { lock.lock(); defer { lock.unlock() }; return onMain }
    }

    struct Refused: Error {}

    private static let today = "2026-10-05"
    private static let now = ISO8601DateFormatter().date(from: "2026-10-05T16:00:00Z")!

    private func event(_ title: String) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: "Pier Nine Players", venue: "Pier Nine Room",
                       performanceDate: "2026-11-21", sourceUrl: "https://piernine.example/" + title.lowercased(),
                       location: "New York, NY")
    }

    private func seeded() throws -> (ModelContainer, ModelContext) {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        let context = container.mainContext
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: "Stored Show", performanceDate: "2026-10-30",
                                                             venue: "Pier Nine Room"),
                         groupName: "Stored Show", discipline: "music", venue: "Pier Nine Room",
                         performanceDate: "2026-10-30", sourceListingURL: "https://piernine.example/stored",
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "invented",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         ingestedAt: Self.now)
        context.insert(p)
        try context.save()
        return (container, context)
    }

    private func count(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<Prospect>())
    }

    @Test func theShowTableIsReadOffTheMainThreadAndOnlyThere() async throws {
        let (container, context) = try seeded()
        let reads = Reads()
        let result = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            readProspectTable: { reads.note(); return try $0.fetch(FetchDescriptor<Prospect>()) },
            into: context)
        guard case .landed(let outcome) = result else {
            Issue.record("the paste did not land: \(result)")
            return
        }
        #expect(outcome.inserted == 1)
        #expect(try count(container) == 2)
        // The read phase reads the table ONCE, off the main thread, for the corpus and the history together.
        // What follows it on the main thread is the landing's own working set (`ScoutLandingStore`, A4's),
        // read under the token as every entry point's landing block reads it.
        #expect(reads.all.first == false, "the read phase read the show table on the main thread: \(reads.all)")
        #expect(reads.all.filter { !$0 }.count == 1, "the show table was read off the main thread \(reads.all.filter { !$0 }.count) times")
    }

    @Test func anUnreadableShowTableIsRecordedRatherThanReadAsEmpty() async throws {
        // The container is held for the whole test: a context whose container has been released traps in
        // SwiftData on its first use, which is a fault of the test, not of the landing.
        let (container, context) = try seeded()
        defer { withExtendedLifetime(container) {} }
        // Unreadable in the read phase only; the landing's own working set, on the main thread, still reads.
        let result = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            readProspectTable: { context in
                guard Thread.isMainThread else { throw Refused() }
                return try context.fetch(FetchDescriptor<Prospect>())
            },
            into: context)
        guard case .landed(let outcome) = result else {
            Issue.record("the paste did not land: \(result)")
            return
        }
        #expect(outcome.degradedReads.contains(.repeatClientHistory), "degraded: \(outcome.degradedReads)")
        #expect(outcome.degradedReads.contains(.venueBrandCorpus), "degraded: \(outcome.degradedReads)")
    }

    @Test func aSaveThatFailsIsPutBackAndSaidAndCountsNoShows() async throws {
        let (container, context) = try seeded()
        let result = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights"), event("Low Tide")], today: Self.today, now: Self.now,
            landings: LandingSingleFlight(), saveSource: { _ in throw Refused() }, into: context)
        guard case .refused(let sentence) = result else {
            Issue.record("a paste whose save failed reported \(result)")
            return
        }
        #expect(sentence == LeadIntake.saveFailedMessage, "said: \(sentence)")
        // Not `!hasChanges`, which a revert cannot give (a field written back to its committed value still reads
        // as changed): the context holds exactly what the store holds, with no pending insert or delete.
        #expect(try ScoutFailedSaveIsolationTests.holdsOnlyWhatTheStoreHolds(context, container),
                "the failed save's writes were left pending for a later save to carry")
        #expect(try count(container) == 1)
    }

    @Test func aPendingEditIsSavedBeforeThePasteLandsAndAFlushThatFailsRefusesIt() async throws {
        let (container, context) = try seeded()
        let stored = try #require(try context.fetch(FetchDescriptor<Prospect>()).first)
        stored.groupName = "Renamed By Dan"
        let refused = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            saveEntry: { _ in throw Refused() }, into: context)
        #expect(refused == .refused(LeadIntake.recentEditsUnsaved(["Renamed By Dan"])), "said \(refused)")
        #expect(try count(container) == 1, "a refused paste landed shows")
        #expect(stored.groupName == "Renamed By Dan" && context.hasChanges, "the refusal touched Dan's edit")

        let landed = await LeadPasteLanding.landPastedLead(
            [event("Harbor Lights")], today: Self.today, now: Self.now, landings: LandingSingleFlight(),
            into: context)
        guard case .landed = landed else {
            Issue.record("the paste did not land: \(landed)")
            return
        }
        let fresh = try ModelContext(container).fetch(FetchDescriptor<Prospect>()).map(\.groupName).sorted()
        #expect(fresh == ["Harbor Lights", "Renamed By Dan"], "the store holds \(fresh)")
    }

    /// The second entry flush, the one taken once the store is held: an edit Dan makes while the paste reads and
    /// waits is saved before anything is applied, so the put back of a failed save, which restores COMMITTED
    /// values, cannot take his edit with it.
    @Test func anEditMadeWhileThePasteWaitsSurvivesItsFailedSave() async throws {
        let (container, context) = try seeded()
        let flight = LandingSingleFlight(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        let held = try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout, deadline: .seconds(60))
        let paste = Task { @MainActor in
            await LeadPasteLanding.landPastedLead([event("Harbor Lights")], today: Self.today, now: Self.now,
                                                  landings: flight, saveSource: { _ in throw Refused() },
                                                  into: context)
        }
        let waiting = await waitUntil("the paste waits its turn", timeout: .seconds(30)) { flight.queue == [.leadPaste] }
        #expect(waiting, "the paste never queued for the store: \(flight.queue)")
        let stored = try #require(try context.fetch(FetchDescriptor<Prospect>()).first)
        stored.groupName = "Renamed While Waiting"
        held.end()
        let result = await paste.value
        #expect(result == .refused(LeadIntake.saveFailedMessage), "said \(result)")
        let fresh = try ModelContext(container).fetch(FetchDescriptor<Prospect>()).map(\.groupName)
        #expect(fresh == ["Renamed While Waiting"], "the store holds \(fresh) after the paste's failed save")
        #expect(stored.groupName == "Renamed While Waiting", "the put back undid Dan's edit")
    }

    @Test func thePasteWaitsForTheLandingInProgressAtTheFrontOfTheQueue() async throws {
        let (container, context) = try seeded()
        let flight = LandingSingleFlight(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        let held = try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout, deadline: .seconds(60))
        // A scout landing queued FIRST, so the paste reaches the front only by its priority, never by its order.
        let scoutWaiting = Task { @MainActor in
            try await flight.begin(entryPoint: .runScoutLanding, priority: .scout, deadline: .seconds(60))
        }
        let scoutQueued = await waitUntil("the scout landing queues", timeout: .seconds(30)) {
            flight.queue == [.runScoutLanding]
        }
        #expect(scoutQueued, "the scout landing never queued: \(flight.queue)")
        let paste = Task { @MainActor in
            await LeadPasteLanding.landPastedLead([event("Harbor Lights")], today: Self.today, now: Self.now,
                                                  landings: flight, into: context)
        }
        let waiting = await waitUntil("the paste waits at the front", timeout: .seconds(30)) {
            flight.queue == [.leadPaste, .runScoutLanding]
        }
        #expect(waiting, "the paste is not waiting at the front of the queue: \(flight.queue)")
        #expect(try count(container) == 1, "the paste landed while another landing held the store")
        held.end()
        let result = await paste.value
        (try? await scoutWaiting.value)?.end()
        guard case .landed = result else {
            Issue.record("the paste did not land once the store was free: \(result)")
            return
        }
        #expect(try count(container) == 2)
        #expect(!flight.isHeld, "the paste kept the store after it landed")
    }
}
