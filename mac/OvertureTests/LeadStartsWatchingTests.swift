import Testing
import Foundation
import SwiftData

// #768: handing Overture a lead puts that organization's calendar on the watchlist, so the NEXT show
// these people put on is found without Dan having to trip over it. That is the whole point of the
// feature: today everything he finds himself is a dead end after one pitch.
//
// The test this suite exists for is `aRefusedOrgCannotBeReAddedByPastingALead`. A lead is exactly the
// route by which the unrecoverable mistake would happen: Dan pastes a show he liked, having forgotten
// it is the org that wrote to him last spring asking to be left alone, and a helpful watchlist quietly
// puts them back on the list and starts surfacing their shows to pitch again.
@MainActor
@Suite("Handing over a lead starts watching its calendar (#768)")
struct LeadStartsWatchingTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private static let realPageHTML =
        "<h1>Upcoming concerts</h1>"
        + "<p>Bargemusic presents an evening of chamber music at the Boathouse, with works by Brahms "
        + "and Dvorak, followed by a conversation with the performers. Doors open at seven and the "
        + "programme begins at half past. Tickets are available at the box office or online, and the "
        + "players stay afterwards to talk with anyone who would like to.</p>"
        + "<ul><li><a href=\"/show/1\">October 3: Piano Trios of Haydn, Brahms and Dvorak, with guests "
        + "from the orchestra, in the recital hall on the second floor</a></li></ul>"
        + "<p>All concerts begin at half past seven. The hall is fully accessible, and there is a lift "
        + "to the second floor from the lobby entrance on the street.</p>"

    private func model(url: String = "https://bargemusic.org/events",
                       verdict: PageVerdict = .upcomingListings) -> LeadIntakeModel {
        let m = LeadIntakeModel(
            defaults: UserDefaults(suiteName: "LeadStartsWatchingTests-\(UUID().uuidString)")!,
            fetch: { u in
                FetchedPage(normalizedHTML: Self.realPageHTML, finalURL: url, contentHash: "h")
            },
            pin: { _, _ in URL(fileURLWithPath: "/tmp/pinned.html") },
            launch: { _ in },
            readResults: { id in
                ScoutExtractResults(
                    version: 1, generatedAt: "2026-07-12T00:00:00Z",
                    results: [ScoutExtractResult(
                        sourceId: id, verdict: verdict,
                        events: [ScoutExtractEvent(title: "Bargemusic Piano Trios",
                                                   presenter: "Bargemusic", venue: "Merkin Hall",
                                                   performanceDate: "2099-10-03",
                                                   sourceUrl: "https://bargemusic.org/show/1")],
                        note: nil)])
            })
        m.urlText = url
        return m
    }

    // #859: start() lands the shows itself. The proposal is then built on the screen that tells him so.
    private func drive(_ m: LeadIntakeModel, _ ctx: ModelContext) async {
        await m.start(into: ctx, now: Date(), today: ScoutTestClock.beforeAllFixtures)
        let sources = (try? ctx.fetch(FetchDescriptor<WatchedSource>())) ?? []
        m.prepareWatchProposal(existing: sources)
    }

    private func sources(_ ctx: ModelContext) throws -> [WatchedSource] {
        try ctx.fetch(FetchDescriptor<WatchedSource>())
    }

    // MARK: - The unrecoverable mistake

    // THE test. An org that asked Dan to stop cannot be put back on the watchlist by pasting one of
    // their shows, and the guarantee does NOT live in the UI: `confirm` re-derives the verdict from the
    // store before writing anything, so even a sheet that had it wrong writes nothing.
    @Test func aRefusedOrgCannotBeReAddedByPastingALead() async throws {
        let ctx = try context()
        let refused = WatchedSource(sourceId: "bargemusic", orgName: "Bargemusic",
                                    listingsURL: "https://bargemusic.org/calendar", kind: .html)
        refused.isActive = false
        refused.inactiveReason = .orgRefusal
        ctx.insert(refused)

        let m = model()
        await drive(m, ctx)

        #expect(m.watchVerdict == .refused(orgName: "Bargemusic"))
        #expect(m.watchThisCalendar == false)

        // Now force the flag on, as a broken sheet or a future refactor might. It still must not write.
        m.watchThisCalendar = true
        m.watchOrgName = "Bargemusic"
        m.watchURL = "https://bargemusic.org/events"
        m.finishWatching(into: ctx)

        let all = try sources(ctx)
        #expect(all.count == 1)                    // no second row
        #expect(all.first?.isActive == false)      // and they are still left alone
        #expect(all.first?.inactiveReason == .orgRefusal)
    }

    // MARK: - The happy path

    @Test func confirmingALeadStartsWatchingItsCalendar() async throws {
        let ctx = try context()
        let m = model()
        await drive(m, ctx)

        #expect(m.watchVerdict == .propose(orgName: "Bargemusic",
                                           listingsURL: "https://bargemusic.org/events"))
        #expect(m.watchThisCalendar)               // Overture proposes; he need only accept

        m.finishWatching(into: ctx)

        let watched = try #require(try sources(ctx).first)
        #expect(watched.orgName == "Bargemusic")
        #expect(watched.listingsURL == "https://bargemusic.org/events")
        #expect(watched.kind == .html)             // read by the extract run, not by Carnegie's API
        #expect(watched.isActive)
        #expect(watched.health == .neverChecked)   // no scout has reached it yet, and it says so
    }

    // Unticking it is the touring-act escape hatch, and it must actually work.
    @Test func untickingItAddsTheShowsWithoutWatchingTheCalendar() async throws {
        let ctx = try context()
        let m = model()
        await drive(m, ctx)

        m.watchThisCalendar = false
        m.finishWatching(into: ctx)

        #expect(try sources(ctx).isEmpty)                                  // nothing watched
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).isEmpty == false)  // but the show landed
    }

    // MARK: - Not watching the same calendar twice

    @Test func anOrgAlreadyWatchedIsNotAddedASecondTime() async throws {
        let ctx = try context()
        ctx.insert(WatchedSource(sourceId: "bargemusic", orgName: "Bargemusic",
                                 listingsURL: "https://bargemusic.org/calendar", kind: .html))

        let m = model()
        await drive(m, ctx)

        #expect(m.watchVerdict == .alreadyWatching(orgName: "Bargemusic"))
        m.finishWatching(into: ctx)

        #expect(try sources(ctx).count == 1)   // still one row, not two for the same organization
    }

    // MARK: - What is not worth watching

    // A page we could not read is not a calendar we can watch: adding it would mean a source that
    // reports as failing every single run, forever, with nothing Dan can do about it.
    @Test func anUnreadablePageIsNotProposedForWatching() async throws {
        let ctx = try context()
        let m = model(verdict: .noDatedContent)
        await drive(m, ctx)

        #expect(m.watchVerdict == .nothingToWatch)
        #expect(m.watchThisCalendar == false)

        m.finishWatching(into: ctx)
        #expect(try sources(ctx).isEmpty)
    }

    // A source id is derived from the HOST, so an org that publishes /events and /calendar cannot end up
    // with two rows fetching, hashing and reading the same calendar twice a run.
    @Test func theSourceIdIsStablePerOrganizationNotPerURL() {
        #expect(WatchedSource.newSourceId(for: "https://bargemusic.org/events")
                == WatchedSource.newSourceId(for: "https://www.bargemusic.org/calendar/2026"))
        #expect(WatchedSource.newSourceId(for: "https://bargemusic.org/events")
                != WatchedSource.newSourceId(for: "https://merkin.example/events"))
    }
}
