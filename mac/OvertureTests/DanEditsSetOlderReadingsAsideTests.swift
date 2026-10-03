import Testing
import Foundation
import SwiftData

// #4404: an edit Dan makes to a watched source outside any landing (an address correction, a resume, a
// confirmed empty page, a venue answer) makes every reading of that source taken BEFORE it the older one. A
// landing whose read phase came before the edit (a detached read in flight, a kept copy offered again) sets that
// reading aside, and Dan's edit stands. #4335's idle recovery of an interrupted landing adds its own case here.
//
// Before #4404 the edits left `lastTouchedSequence` where it was, so the landing's re-validation could not tell
// a reading of the old address from one of the new, and landed the old page over the correction. Every name is
// invented (L155).
@MainActor
@Suite("An edit Dan makes sets every older reading of that source aside (#4404)")
final class DanEditsSetOlderReadingsAsideTests {
    private let sandboxes = TemporarySandboxes()
    private let started = Date(timeIntervalSince1970: 1_790_000_000.25)
    private struct SaveRefused: Error {}

    // Each edit kind, applied to source "b" on a context, and what it leaves that a stale landing would undo.
    enum Edit: String, CaseIterable, CustomStringConvertible {
        case addressCorrection, resume, confirmEmpty, venueLocation, venueName
        var description: String { rawValue }
    }

    private func apply(_ edit: Edit, to b: WatchedSource, in ctx: ModelContext) {
        switch edit {
        case .addressCorrection:
            #expect(WatchlistEditing.editURL(b, to: "https://b-corrected.example/calendar", in: ctx)
                    == .saved(sourceId: "b"))
        case .resume:
            b.isActive = false
            b.inactiveReason = .removedByDan
            try? ctx.save()
            #expect(WatchlistEditing.resumeWatching(b, in: ctx) == .resumed)
        case .confirmEmpty:
            #expect(WatchlistEditing.confirmEmpty(b, in: ctx) == .confirmed)
        case .venueLocation:
            WatchlistEditing.setVenueLocation(b, to: "Brooklyn, NY", in: ctx)
        case .venueName:
            WatchlistEditing.setVenueName(b, to: "The Corrected Room", in: ctx)
        }
    }

    private func container() throws -> ModelContainer {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        c.mainContext.autosaveEnabled = false
        return c
    }

    private func night(_ n: Int) -> String {
        EasternDate.dayString(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: 30 + n, to: started)!)
    }

    @discardableResult
    private func html(_ id: String, in ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Org \(id)", listingsURL: "https://\(id).example/events",
                              kind: .html)
        s.venueLocation = "New York, NY"
        s.lastContentHash = "old-\(id)"
        s.pendingContentHash = "new-\(id)"
        s.hasUnreadChanges = true
        ctx.insert(s)
        return s
    }

    private func data(_ ids: [String]) throws -> Data {
        try JSONEncoder().encode(ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z", results: ids.map { id in
            ScoutExtractResult(sourceId: id, verdict: .upcomingListings,
                               events: (0..<2).map { k in
                                   ScoutExtractEvent(title: "Recital \(id) \(k)", presenter: "Recital \(id) \(k)",
                                                     venue: "Merkin Hall", performanceDate: night(k),
                                                     sourceUrl: "https://\(id).example/r\(k)")
                               },
                               note: "read \(id)")
        }))
    }

    private struct Folders {
        let pending: PendingScoutIngests
        let journals: LandingJournals
    }

    private func folders(_ name: String) throws -> Folders {
        let root = try sandboxes.make(named: name)
        return Folders(pending: PendingScoutIngests(directory: root.appendingPathComponent("pending"),
                                                    readFailures: HandoffReadFailures()),
                       journals: LandingJournals(directory: root.appendingPathComponent("journals"),
                                                 readFailures: HandoffReadFailures()))
    }

    private func titles(_ c: ModelContainer) throws -> [String] {
        try ModelContext(c).fetch(FetchDescriptor<Prospect>()).map(\.groupName).filter { $0.hasPrefix("Recital") }.sorted()
    }

    private func source(_ id: String, _ c: ModelContainer) throws -> WatchedSource {
        try #require(try ModelContext(c).fetch(FetchDescriptor<WatchedSource>()).first { $0.sourceId == id })
    }

    // What the edit left on b that a stale landing of the earlier reading would have overwritten.
    private func editStands(_ edit: Edit, on b: WatchedSource) -> Bool {
        switch edit {
        case .addressCorrection: return b.listingsURL == "https://b-corrected.example/calendar" && b.lastContentHash == nil
        case .resume: return b.isActive && b.lastContentHash == "old-b" && b.successfulCheckCount == 0
        case .confirmEmpty: return b.confirmedEmptyHash == "new-b" && b.successfulCheckCount == 0
        case .venueLocation: return b.venueLocation == "Brooklyn, NY" && b.lastContentHash == nil
        case .venueName: return b.venueName == "The Corrected Room" && b.lastContentHash == nil
        }
    }

    // THE NORMAL LANDING. A reading taken before the edit (here, results landed under the sequence their read
    // phase was minted with, as a kept copy is) is set aside for the edited source and lands for the other.
    @Test(arguments: Edit.allCases)
    func aReadingFromBeforeTheEditIsSetAsideWhenItLands(_ edit: Edit) async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b"] { html(id, in: ctx) }
        try ctx.save()
        // The read phase's sequence, minted as the product mints it, before the edit.
        let readAt = LandingSingleFlight.shared.mintSequence(above: 0)
        let b = try #require(try ctx.fetch(FetchDescriptor<WatchedSource>()).first { $0.sourceId == "b" })
        apply(edit, to: b, in: ctx)
        #expect(b.lastTouchedSequence > readAt, "the \(edit) did not make the earlier reading the older one")

        let outcome = await ScoutExtractIngest.ingest(
            try ScoutExtractResultsDecoder.decode(try data(["a", "b"])), clients: [], history: [], blocked: .empty,
            today: QueueModel.easternToday(started), now: started, landings: LandingSingleFlight(sleep: { _ in }),
            sequence: readAt, sequenceFloor: { 0 }, into: ctx)
        let states = Dictionary(uniqueKeysWithValues: outcome.sources.map { ($0.sourceId, $0.state) })
        #expect(states["b"] == .superseded, Comment(rawValue: "after a \(edit), b landed as \(String(describing: states["b"]))"))
        #expect(states["a"] == .ingested(found: 2))
        #expect(try titles(c) == ["Recital a 0", "Recital a 1"], "the old reading of b landed over the \(edit)")
        #expect(editStands(edit, on: try source("b", c)), "the \(edit) was overwritten by a stale reading")
    }

    // L2: the edits' floor reads the kept copies and the journals through `.live`, which under tests must be
    // this run's own handoff folder in the temp directory, never Dan's. Checked rather than assumed, so these
    // tests (and every test of an edit) can never depend on, or touch, his real landing state.
    @Test func theFloorAnEditMintsAboveNeverReadsDansFolders() {
        let testRun = StoreLocation.testRunHandoffDirectory.standardizedFileURL.path
        for folder in [PendingScoutIngests.live.directory, LandingJournals.live.directory] {
            let path = folder.standardizedFileURL.path
            #expect(path.hasPrefix(testRun), Comment(rawValue: "an edit's floor reads \(path) under test"))
            #expect(!StoreLocation.isLiveHandoffDirectory(folder.deletingLastPathComponent()),
                    Comment(rawValue: "\(path) is inside Dan's handoff folder"))
        }
    }
}
