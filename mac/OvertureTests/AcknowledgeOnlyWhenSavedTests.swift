import Testing
import Foundation
import SwiftData

// #1417: a success banner must never appear over a write that did not reach disk.
//
// The defect this pins is not theoretical and not one call site. The domain editing helpers
// (WatchlistEditing, ExcludedTownEditing, DayOffEditing) persist with a bare `try? context.save()`
// that swallows the error, and every caller then acknowledged success unconditionally: "Stopped
// watching Bargemusic" for a stop that was never written, "Jul 3 to Jul 5 is no longer blocked" for
// a day off still on disk. The change stays in memory and looks right on screen until quit, which is
// exactly when nobody is watching.
//
// Each flow is pinned twice: the failure path (warns, and says nothing that claims success) and the
// success path (still says what it did), so a gate that simply silenced every banner would fail here.
// The failure is a REAL save() throw via ImmutableStoreFixture (#617), not a simulated one.
@MainActor
@Suite("A success line is posted only when the change was saved (#1417)")
struct AcknowledgeOnlyWhenSavedTests {

    private static let schema = Schema([Prospect.self, WatchedSource.self, DayOff.self,
                                        ExcludedTown.self, AllowedSeedTown.self])

    private func source(_ ctx: ModelContext, active: Bool = true, hash: String? = "abc") {
        let s = WatchedSource(sourceId: "s1", orgName: "Bargemusic",
                              listingsURL: "https://bargemusic.org/events", kind: .html)
        s.isActive = active
        if !active { s.inactiveReason = .removedByDan }
        s.lastContentHash = hash
        ctx.insert(s)
    }

    private func firstSource(_ ctx: ModelContext) throws -> WatchedSource {
        try #require((try? ctx.fetch(FetchDescriptor<WatchedSource>()))?.first)
    }

    private func saveFailedFor(_ org: String) -> String { ActionAck.saveFailed(org: org) }

    // A queue row whose location offers a town to refuse (EventPlace.excludableTown needs a named
    // in-region state and a non-borough town).
    private func row(inTown location: String) -> QueueItem {
        var q = QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "V",
                          performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "unknown", profile: "neutral",
                          coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .new)
        q.location = location
        return q
    }

    // MARK: - Watchlist

    @Test("stopping a watch that cannot be saved warns instead of saying it stopped")
    func stopWatchingFailure() async throws {
        let feedback = ActionFeedback()

        try await ImmutableStoreFixture.withFailingSave(
            schema: Self.schema,
            seed: { self.source($0) },
            body: { ctx in
                WatchlistMutations.stopWatching(try self.firstSource(ctx), context: ctx, feedback: feedback)
            })

        #expect(feedback.message == saveFailedFor("Bargemusic"))
        #expect(feedback.tone == .warning)
        // The specific lie: the banner must not be offering an Undo for something that never happened.
        #expect(feedback.action == nil)
    }

    @Test("stopping a watch that saves still says it stopped, with its Undo")
    func stopWatchingSuccess() throws {
        let ctx = ModelContext(try ModelContainer(for: Self.schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let feedback = ActionFeedback()
        source(ctx)

        WatchlistMutations.stopWatching(try firstSource(ctx), context: ctx, feedback: feedback)

        #expect(feedback.message == ActionAck.stoppedWatching(org: "Bargemusic"))
        #expect(feedback.tone == .info)
        #expect(feedback.action != nil)
    }

    @Test("resuming a watch that cannot be saved warns instead of saying it resumed")
    func resumeWatchingFailure() async throws {
        let feedback = ActionFeedback()

        try await ImmutableStoreFixture.withFailingSave(
            schema: Self.schema,
            seed: { self.source($0, active: false) },
            body: { ctx in
                WatchlistMutations.resumeWatching(try self.firstSource(ctx), context: ctx, feedback: feedback)
            })

        #expect(feedback.message == saveFailedFor("Bargemusic"))
        #expect(feedback.tone == .warning)
    }

    @Test("resuming a watch that saves still says it resumed")
    func resumeWatchingSuccess() throws {
        let ctx = ModelContext(try ModelContainer(for: Self.schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let feedback = ActionFeedback()
        source(ctx, active: false)

        WatchlistMutations.resumeWatching(try firstSource(ctx), context: ctx, feedback: feedback)

        #expect(feedback.message == ActionAck.resumedWatching(org: "Bargemusic"))
    }

    @Test("a venue location that cannot be saved warns instead of saying it saved")
    func venueLocationFailure() async throws {
        let feedback = ActionFeedback()

        try await ImmutableStoreFixture.withFailingSave(
            schema: Self.schema,
            seed: { self.source($0) },
            body: { ctx in
                WatchlistMutations.saveVenueLocation(try self.firstSource(ctx), to: "1 Water St, Brooklyn, NY",
                                                     context: ctx, feedback: feedback)
            })

        #expect(feedback.message == saveFailedFor("Bargemusic"))
        #expect(feedback.tone == .warning)
    }

    @Test("a venue location that saves still confirms it")
    func venueLocationSuccess() throws {
        let ctx = ModelContext(try ModelContainer(for: Self.schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let feedback = ActionFeedback()
        source(ctx)

        WatchlistMutations.saveVenueLocation(try firstSource(ctx), to: "1 Water St, Brooklyn, NY",
                                             context: ctx, feedback: feedback)

        #expect(feedback.message == VenueLocationCopy.savedAck(org: "Bargemusic"))
    }

    @Test("a corrected address that cannot be saved warns, and does not report the fix")
    func fixURLFailure() async throws {
        let feedback = ActionFeedback()

        let outcome = try await ImmutableStoreFixture.withFailingSave(
            schema: Self.schema,
            seed: { self.source($0) },
            body: { ctx in
                WatchlistMutations.fixURL(try self.firstSource(ctx), to: "https://bargemusic.org/calendar",
                                          context: ctx, feedback: feedback)
            })

        #expect(outcome == .notSaved)
        #expect(feedback.message == saveFailedFor("Bargemusic"))
        #expect(feedback.tone == .warning)
    }

    @Test("a corrected address that saves reports the fix")
    func fixURLSuccess() throws {
        let ctx = ModelContext(try ModelContainer(for: Self.schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let feedback = ActionFeedback()
        source(ctx)

        let outcome = WatchlistMutations.fixURL(try firstSource(ctx), to: "https://bargemusic.org/calendar",
                                                context: ctx, feedback: feedback)

        #expect(outcome == .saved(sourceId: "s1"))
        #expect(feedback.message == SourceFixConfirmCopy.fixedAck(org: "Bargemusic"))
    }

    @Test("a page confirmation that cannot be saved warns instead of confirming")
    func confirmEmptyFailure() async throws {
        let feedback = ActionFeedback()

        try await ImmutableStoreFixture.withFailingSave(
            schema: Self.schema,
            seed: { self.source($0) },
            body: { ctx in
                WatchlistMutations.confirmEmpty(try self.firstSource(ctx), context: ctx, feedback: feedback)
            })

        #expect(feedback.message == saveFailedFor("Bargemusic"))
        #expect(feedback.tone == .warning)
    }

    @Test("a page confirmation that saves still confirms it")
    func confirmEmptySuccess() throws {
        let ctx = ModelContext(try ModelContainer(for: Self.schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let feedback = ActionFeedback()
        source(ctx)

        WatchlistMutations.confirmEmpty(try firstSource(ctx), context: ctx, feedback: feedback)

        #expect(feedback.message == SourceFixConfirmCopy.confirmedAck(org: "Bargemusic"))
    }

    // The two forms that say nothing at all on success: closing IS the confirmation, so a form that
    // closes over a failed write claims exactly as much as a banner would.

    @Test("a source that cannot be saved leaves the add form open rather than closing over nothing")
    func addSourceFailure() async throws {
        let feedback = ActionFeedback()

        let outcome = try await ImmutableStoreFixture.withFailingSave(
            schema: Self.schema,
            seed: { _ in },
            body: { ctx in
                WatchlistMutations.addSource(orgName: "Bargemusic", listingsURL: "https://bargemusic.org/events",
                                             context: ctx, feedback: feedback)
            })

        #expect(outcome == .notSaved)
        #expect(feedback.message == saveFailedFor("Bargemusic"))
        #expect(feedback.tone == .warning)
    }

    @Test("a source that saves closes the add form")
    func addSourceSuccess() throws {
        let ctx = ModelContext(try ModelContainer(for: Self.schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let feedback = ActionFeedback()

        let outcome = WatchlistMutations.addSource(orgName: "Bargemusic",
                                                   listingsURL: "https://bargemusic.org/events",
                                                   context: ctx, feedback: feedback)

        #expect(outcome == .added)
        #expect(feedback.message == nil)
    }

    @Test("a blocked range that cannot be saved leaves the form open rather than closing over nothing")
    func addDayOffFailure() async throws {
        let feedback = ActionFeedback()

        let outcome = try await ImmutableStoreFixture.withFailingSave(
            schema: Self.schema,
            seed: { _ in },
            body: { ctx in
                DayOffMutations.add(start: "2026-08-03", end: "2026-08-05", note: nil, export: ([], []),
                                    context: ctx, feedback: feedback)
            })

        #expect(outcome == .notSaved)
        #expect(feedback.tone == .warning)
        #expect(feedback.message?.contains("Couldn't save") == true)
    }

    @Test("a blocked range that saves closes the form")
    func addDayOffSuccess() throws {
        let ctx = ModelContext(try ModelContainer(for: Self.schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let feedback = ActionFeedback()

        let outcome = DayOffMutations.add(start: "2026-08-03", end: "2026-08-05", note: nil, export: ([], []),
                                          context: ctx, feedback: feedback)

        #expect(outcome == .added)
        #expect(feedback.message == nil)
    }

    // MARK: - Excluded towns

    @Test("un-skipping a seed town that cannot be saved warns instead of saying it can appear")
    func allowTownFailure() async throws {
        let feedback = ActionFeedback()

        try await ImmutableStoreFixture.withFailingSave(
            schema: Self.schema,
            seed: { _ in },
            body: { ctx in
                ExcludedTownMutations.allow("albany", context: ctx, feedback: feedback)
            })

        #expect(feedback.message == saveFailedFor("Albany"))
        #expect(feedback.tone == .warning)
    }

    @Test("un-skipping a seed town that saves still says it can appear")
    func allowTownSuccess() throws {
        let ctx = ModelContext(try ModelContainer(for: Self.schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let feedback = ActionFeedback()

        ExcludedTownMutations.allow("albany", context: ctx, feedback: feedback)

        #expect(feedback.message == ActionAck.townUnexcluded(town: "Albany"))
    }

    @Test("re-skipping a seed town that cannot be saved warns instead of saying it is skipped")
    func reskipTownFailure() async throws {
        let feedback = ActionFeedback()

        try await ImmutableStoreFixture.withFailingSave(
            schema: Self.schema,
            seed: { $0.insert(AllowedSeedTown(town: "albany")) },
            body: { ctx in
                ExcludedTownMutations.reskip("albany", context: ctx, feedback: feedback)
            })

        #expect(feedback.message == saveFailedFor("Albany"))
        #expect(feedback.tone == .warning)
    }

    @Test("removing a refusal that cannot be saved warns instead of saying the town is back")
    func removeTownFailure() async throws {
        let feedback = ActionFeedback()

        try await ImmutableStoreFixture.withFailingSave(
            schema: Self.schema,
            seed: { $0.insert(ExcludedTown(town: "newark")) },
            body: { ctx in
                ExcludedTownMutations.remove("newark", context: ctx, feedback: feedback)
            })

        #expect(feedback.message == saveFailedFor("Newark"))
        #expect(feedback.tone == .warning)
    }

    @Test("removing a refusal that saves still says the town is back")
    func removeTownSuccess() throws {
        let ctx = ModelContext(try ModelContainer(for: Self.schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let feedback = ActionFeedback()
        ctx.insert(ExcludedTown(town: "newark"))

        ExcludedTownMutations.remove("newark", context: ctx, feedback: feedback)

        #expect(feedback.message == ActionAck.townUnexcluded(town: "Newark"))
    }

    // #1417: the one site the issue actually named. Blocking a town from a queue row DID call
    // saveOrWarn, and then posted its success line over the warning microseconds later.
    @Test("blocking a town from a row that cannot be saved warns instead of saying it is blocked")
    func excludeTownFromRowFailure() async throws {
        let feedback = ActionFeedback()

        try await ImmutableStoreFixture.withFailingSave(
            schema: Self.schema,
            seed: { _ in },
            body: { ctx in
                ProspectMutations.excludeTown(self.row(inTown: "Newark, NJ"), context: ctx, feedback: feedback)
            })

        #expect(feedback.message == saveFailedFor("Newark"))
        #expect(feedback.tone == .warning)
        #expect(feedback.action == nil)
    }

    // MARK: - Days off

    @Test("removing a day off that cannot be saved warns instead of saying it is free")
    func removeDayOffFailure() async throws {
        let feedback = ActionFeedback()

        try await ImmutableStoreFixture.withFailingSave(
            schema: Self.schema,
            seed: { $0.insert(DayOff(startDate: "2026-08-03", endDate: "2026-08-05", note: nil)) },
            body: { ctx in
                let row = try #require((try? ctx.fetch(FetchDescriptor<DayOff>()))?.first)
                DayOffMutations.remove(row, export: ([], []), context: ctx, feedback: feedback)
            })

        #expect(feedback.tone == .warning)
        #expect(feedback.message?.contains("Couldn't save") == true)
    }

    @Test("removing a day off that saves still says it is free")
    func removeDayOffSuccess() throws {
        let ctx = ModelContext(try ModelContainer(for: Self.schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let feedback = ActionFeedback()
        ctx.insert(DayOff(startDate: "2026-08-03", endDate: "2026-08-05", note: nil))
        let row = try #require((try? ctx.fetch(FetchDescriptor<DayOff>()))?.first)

        DayOffMutations.remove(row, export: ([], []), context: ctx, feedback: feedback)

        #expect(feedback.message == ActionAck.dayOffRemoved(range: QueueModel.runDateLabel(start: "2026-08-03",
                                                                                           end: "2026-08-05")))
    }

    @Test("blocking days off that cannot be saved warns instead of saying they are blocked")
    func blockDaysOffFailure() async throws {
        let feedback = ActionFeedback()

        let blocked = try await ImmutableStoreFixture.withFailingSave(
            schema: Self.schema,
            seed: { _ in },
            body: { ctx in
                ProspectMutations.blockDaysOff(start: "2026-08-03", end: "2026-08-05", export: ([], []),
                                               context: ctx, feedback: feedback)
            })

        #expect(!blocked)
        #expect(feedback.tone == .warning)
        #expect(feedback.message?.contains("Couldn't save") == true)
        #expect(feedback.action == nil)
    }

    @Test("blocking days off that saves still says they are blocked")
    func blockDaysOffSuccess() throws {
        let ctx = ModelContext(try ModelContainer(for: Self.schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let feedback = ActionFeedback()

        let blocked = ProspectMutations.blockDaysOff(start: "2026-08-03", end: "2026-08-05", export: ([], []),
                                                     context: ctx, feedback: feedback)

        #expect(blocked)
        #expect(feedback.message == ActionAck.dayOffBlocked(range: QueueModel.runDateLabel(start: "2026-08-03",
                                                                                          end: "2026-08-05")))
    }
}
