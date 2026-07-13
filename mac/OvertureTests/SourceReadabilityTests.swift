import Testing
import Foundation
import SwiftData
@testable import Overture

// #891: when a source keeps coming back with shows Overture could not read, Dan is told.
//
// The extract run WebFetches each event's own detail page for the venue. An event whose page it never
// reached comes back with no venue and is DROPPED. The app has always known this was happening, and the
// count went nowhere but the lead sheet.
//
// It matters more since #887, which now READS that count: a source that loses more than
// maxRejectedFraction of its shows silently forfeits the right to mark anything cancelled. That is the
// safe behaviour, but a capability switching itself off with no symptom is the "rule that silently never
// fires" problem (#888), and Dan must be able to see it.
//
// The sentence he reads is computed HERE, from the same rule the reconcile used, and not inside the view.
// Two reasons: a rule computed in a view is unreachable by any test (#863, #885), and a display that
// re-derives the tolerance independently would eventually disagree with the reconcile, telling him
// cancellation is fine on a source where it is switched off.
@Suite("Telling Dan a source's shows could not be read (#891)")
struct SourceReadabilityTests {

    // A source that read everything says nothing. Silence must mean healthy, or the line is noise.
    @Test func aSourceThatReadEveryShowSaysNothing() {
        #expect(SourceReadability.note(readable: 40, unreadable: 0) == nil)
    }

    // A stray unreadable listing is worth stating, but it has NOT cost the source anything: it is inside
    // the tolerance, so cancellation still works. The copy must not imply otherwise.
    @Test func aStrayUnreadableShowIsMentionedWithoutAlarm() {
        let note = SourceReadability.note(readable: 39, unreadable: 1)

        #expect(note == "1 of 40 shows couldn't be read.")
    }

    // THE case. Past the tolerance, this source can no longer mark anything cancelled, and saying only
    // "12 shows couldn't be read" would hide the consequence, which is the part Dan can act on.
    @Test func aSourceThatLostTooManyShowsSaysWhatThatCostIt() {
        let note = SourceReadability.note(readable: 68, unreadable: 12)

        #expect(note == "12 of 80 shows couldn't be read, so Overture won't mark anything from this source as gone until it can.")
    }

    // The line the display draws MUST be the line the reconcile drew. If these two ever disagree, Dan is
    // told cancellation is working on a source where it is switched off, which is worse than saying
    // nothing at all. Same function, not a second copy of the rule.
    @Test func theDisplayAgreesWithTheReconcileExactly() {
        for unreadable in 0...20 {
            let readable = 80 - unreadable
            let reconcileWillCancel = FeedReconcile.rejectedIsWithinTolerance(
                readable: readable, unreadable: unreadable)
            let noteSaysItWont = SourceReadability.note(readable: readable, unreadable: unreadable)?
                .contains("won't mark anything") ?? false

            #expect(reconcileWillCancel != noteSaysItWont,
                    "readable \(readable), unreadable \(unreadable): the sheet and the reconcile disagree")
        }
    }

    // A run that read NOTHING is a broken run, and it never gets the tolerance (#887).
    @Test func aRunThatReadNothingSaysSo() {
        let note = SourceReadability.note(readable: 0, unreadable: 6)

        #expect(note?.contains("won't mark anything") == true)
    }
}

// The count has to survive the run that produced it, or the Sources sheet could only ever show it in the
// seconds after a scout, which is exactly when Dan is not looking at the Sources sheet.
@MainActor
@Suite("A source remembers what it could not read (#891)")
struct SourceReadabilityPersistenceTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func source(_ ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: "kaufman", orgName: "Kaufman Music Center",
                              listingsURL: "https://kaufman.example/calendar", kind: .html)
        s.pendingContentHash = "new-hash"
        s.hasUnreadChanges = true
        ctx.insert(s)
        return s
    }

    private func event(_ title: String, venue: String?) -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: title, venue: venue,
                          performanceDate: "2099-10-01",
                          sourceUrl: "https://kaufman.example/\(title)")
    }

    private func ingest(_ events: [ScoutExtractEvent], into ctx: ModelContext) {
        let r = ScoutExtractResults(
            version: 1, generatedAt: "2026-07-13T00:00:00Z",
            results: [ScoutExtractResult(sourceId: "kaufman", verdict: .upcomingListings,
                                         events: events, note: nil)])
        ScoutExtractIngest.ingest(r, clients: [], history: [], blocked: [],
                                  today: ScoutTestClock.beforeAllFixtures,
                                  now: Date(timeIntervalSince1970: 1_800_000_000), into: ctx)
    }

    @Test func anIngestRecordsWhatItCouldNotRead() throws {
        let ctx = try context()
        let s = source(ctx)

        ingest([event("Read", venue: "Merkin Hall"),
                event("Unread", venue: nil)], into: ctx)

        #expect(s.lastReadableCount == 1)
        #expect(s.lastUnreadableCount == 1)
        #expect(s.readabilityNote?.contains("won't mark anything") == true)   // 50%, far past tolerance
    }

    // A source that recovers must STOP saying it is broken, or the warning becomes permanent furniture and
    // Dan learns to skim past the one line he must never skim past.
    @Test func aSourceThatRecoversStopsComplaining() throws {
        let ctx = try context()
        let s = source(ctx)

        ingest([event("Read", venue: "Merkin Hall"), event("Unread", venue: nil)], into: ctx)
        #expect(s.readabilityNote != nil)

        s.pendingContentHash = "newer-hash"      // its page changed again and this run read all of it
        ingest([event("Read", venue: "Merkin Hall"), event("Unread", venue: "Merkin Hall")], into: ctx)

        #expect(s.lastUnreadableCount == 0)
        #expect(s.readabilityNote == nil)
    }
}
