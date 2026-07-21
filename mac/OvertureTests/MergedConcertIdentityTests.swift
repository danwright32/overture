import Testing
import Foundation
import SwiftData
@testable import Overture

// #1260 Phase 2: a merged same-date+venue prospect (SameDateVenueMerge, #1236) is identified for
// re-scout by its natural key (the emit-order-dependent conductor-list name) and, failing that, by the
// representative row's URL. DCINY lists each conductor as a separate recruiting row with its own
// getfeedback link, so a re-scout that lists the same concert in a new order or with refreshed links
// shifts BOTH the name and the URL, missing all three existing match arms and silently INSERTING A
// DUPLICATE, stranding Dan's keep/dismiss. Persisting the synthetic concert id and matching on it closes
// that. These pin it: mutation-verified (the identity arm is load-bearing), plus a guard that it can
// never fuse two genuinely separate shows.
@Suite("Merged-concert identity survives re-scout (#1260 Phase 2)")
struct MergedConcertIdentityTests {
    private let venue = "Stern Auditorium / Perelman Stage"
    private let date = "2026-11-16"

    private func event(_ title: String, url: String) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: "DCINY", venue: venue, performanceDate: date,
                       sourceUrl: url, location: "New York, NY", seriesId: nil)
    }

    private func ctx() throws -> ModelContext {
        let container = try ModelContainer(for: Schema([Prospect.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    // Run A merges 3 per-conductor rows into one kept prospect. Run B is the SAME concert re-listed in a
    // new order with refreshed getfeedback links: name and representative URL both shift, so exact-key,
    // run-URL, and stable-source all miss. The merged prospect must still UPDATE IN PLACE (Dan's keep
    // survives), not spawn a second row.
    @MainActor
    @Test func aReorderedRelistWithNewUrlsUpdatesInPlaceNotDuplicates() throws {
        let context = try ctx()

        let runA = [event("We Sing Noel", url: "https://dciny.getfeedback.com/a1"),
                    event("Craig Courtney", url: "https://dciny.getfeedback.com/b1"),
                    event("The Four Freedoms", url: "https://dciny.getfeedback.com/c1")]
        _ = ScoutService.apply(events: SameDateVenueMerge.stamped(runA), clients: [], history: [],
                               blocked: .empty, today: "2026-07-01", into: context)

        let afterA = try context.fetch(FetchDescriptor<Prospect>())
        #expect(afterA.count == 1)
        let kept = try #require(afterA.first)
        kept.statusRaw = ReviewStatus.queued.rawValue   // Dan kept it
        try context.save()

        // Same concert, rows reordered AND every recruiting link refreshed.
        let runB = [event("The Four Freedoms", url: "https://dciny.getfeedback.com/c2"),
                    event("We Sing Noel", url: "https://dciny.getfeedback.com/a2"),
                    event("Craig Courtney", url: "https://dciny.getfeedback.com/b2")]
        _ = ScoutService.apply(events: SameDateVenueMerge.stamped(runB), clients: [], history: [],
                               blocked: .empty, today: "2026-07-01", into: context)

        let afterB = try context.fetch(FetchDescriptor<Prospect>())
        #expect(afterB.count == 1)                                   // updated in place, no duplicate
        #expect(afterB.first?.statusRaw == ReviewStatus.queued.rawValue)   // Dan's keep survived
    }

    // The gate: two GENUINELY DIFFERENT shows on one date+venue from a non-merge source (no synthetic id)
    // must stay two prospects. The identity arm keys on the merge id, which is never minted here, so it
    // cannot fuse them.
    @MainActor
    @Test func nonMergedSameDateShowsAreNeverFusedByTheIdentityArm() throws {
        let context = try ctx()
        // NOT stamped: an ordinary source's matinee and evening, different acts, same date+venue.
        let events = [event("Boston Symphony", url: "https://ex.org/matinee"),
                      event("A Cappella Gala", url: "https://ex.org/evening")]
        _ = ScoutService.apply(events: events, clients: [], history: [],
                               blocked: .empty, today: "2026-07-01", into: context)
        #expect(try context.fetch(FetchDescriptor<Prospect>()).count == 2)

        // Re-ingest: still two, never fused.
        _ = ScoutService.apply(events: events, clients: [], history: [],
                               blocked: .empty, today: "2026-07-01", into: context)
        #expect(try context.fetch(FetchDescriptor<Prospect>()).count == 2)
    }
}
