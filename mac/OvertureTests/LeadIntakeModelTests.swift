import Testing
import Foundation
import SwiftData
@testable import Overture

// #799 slice 4b: the sheet's brain. Every dependency is injected, so the whole flow (paste, fetch,
// pin, launch, wait, review, confirm) is a real unit test with no network, no Claude run, and no UI.
//
// The states here are the ones Dan actually sees, so what they SAY is the behaviour under test.
@MainActor
@Suite("Lead intake model (#799)")
struct LeadIntakeModelTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func page() -> FetchedPage {
        FetchedPage(normalizedHTML: "<td>11</td>", finalURL: "https://org.example/events",
                    contentHash: "abc")
    }

    private func results(_ verdict: PageVerdict, _ events: [ScoutExtractEvent], id: String)
    -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                            results: [ScoutExtractResult(sourceId: id, verdict: verdict,
                                                         events: events, note: nil)])
    }

    private static func okFetch(_ url: URL) async throws -> FetchedPage {
        FetchedPage(normalizedHTML: "x", finalURL: url.absoluteString, contentHash: "h")
    }

    private func model(fetch: @escaping (URL) async throws -> FetchedPage = LeadIntakeModelTests.okFetch,
                       launch: @escaping ([ScoutExtractQueueItem]) throws -> Void = { _ in },
                       results: @escaping (String) -> ScoutExtractResults? = { _ in nil })
    -> LeadIntakeModel {
        LeadIntakeModel(defaults: UserDefaults(suiteName: "LeadIntakeModelTests-\(UUID().uuidString)")!,
                        fetch: fetch,
                        pin: { _, _ in URL(fileURLWithPath: "/tmp/pinned.html") },
                        launch: launch,
                        readResults: results)
    }

    @Test func aBlankOrNonsenseLinkIsRefusedBeforeAnythingIsSpent() async {
        let m = model()
        m.urlText = "not a url"
        await m.start(now: Date())

        guard case .problem(let msg) = m.phase else { Issue.record("expected .problem"); return }
        #expect(msg.lowercased().contains("link"))
    }

    // Recognized before a fetch and before a Claude run, because we already know how it ends: a raw
    // fetch of an Instagram post is ~600KB of login wall with no event data at all.
    @Test func anInstagramLinkIsRefusedImmediatelyWithSomethingActionable() async {
        let m = model()
        m.urlText = "https://www.instagram.com/p/abc123/"
        await m.start(now: Date())

        guard case .problem(let msg) = m.phase else { Issue.record("expected .problem"); return }
        #expect(msg.lowercased().contains("paste") || msg.lowercased().contains("instead"))
    }

    // A fetch failure is NAMED, never a spinner that ends in silence. The 404 must read as a 404.
    @Test func aFetchFailureSurfacesItsRealReason() async {
        let m = model(fetch: { _ in throw SourceFetchError.http(404) })
        m.urlText = "https://org.example/events"
        await m.start(now: Date())

        guard case .problem(let msg) = m.phase else { Issue.record("expected .problem"); return }
        #expect(msg.contains("404"))
    }

    // The spike's trap: a link that answers 200 on somebody else's site. It must not read as a healthy
    // page with no events.
    @Test func aRedirectToAnotherSiteIsNamedAsSuch() async {
        let m = model(fetch: { _ in throw SourceFetchError.redirectedAway("www.thirdstreet.nyc") })
        m.urlText = "https://thirdstreetmusicschool.org/events"
        await m.start(now: Date())

        guard case .problem(let msg) = m.phase else { Issue.record("expected .problem"); return }
        #expect(msg.contains("thirdstreet.nyc"))
    }

    // The runner not being configured is the first thing Dan hits. It must say so, in words, with
    // somewhere to go, rather than the feature quietly doing nothing.
    @Test func anUnconfiguredRunnerSaysSoRatherThanHanging() async {
        let m = model(launch: { _ in throw ScoutExtractService.ExtractLaunchError.runnerUnavailable })
        m.urlText = "https://org.example/events"
        await m.start(now: Date())

        guard case .problem(let msg) = m.phase else { Issue.record("expected .problem"); return }
        #expect(msg.lowercased().contains("runner") || msg.lowercased().contains("set up"))
    }

    @Test func aReadablePageEndsInSomethingToConfirm() async {
        let event = ScoutExtractEvent(title: "Brooklyn Youth Chorus", presenter: "Brooklyn Youth Chorus",
                                      venue: "Merkin Hall", performanceDate: "2026-09-19",
                                      sourceUrl: "https://org.example/a")
        let m = model(results: { id in self.results(.upcomingListings, [event], id: id) })
        m.urlText = "https://org.example/events"

        await m.start(now: Date())

        guard case .review(let events, _) = m.phase else { Issue.record("expected .review, got \(m.phase)"); return }
        #expect(events.count == 1)
        #expect(m.selected.count == 1)     // everything checked by default; he unchecks what he doesn't want
    }

    // Off-season is not a failure, and the message must not read like one.
    @Test func anOrgBetweenSeasonsIsToldPlainlyNotAsAnError() async {
        let m = model(results: { id in self.results(.allPast, [], id: id) })
        m.urlText = "https://org.example/events"

        await m.start(now: Date())

        guard case .problem(let msg) = m.phase else { Issue.record("expected .problem"); return }
        #expect(msg.lowercased().contains("no upcoming"))
        #expect(!msg.lowercased().contains("error"))
    }

    // Confirming writes through the REAL pipeline, and only what Dan left checked.
    @Test func onlyTheShowsDanKeepsCheckedAreAdded() async throws {
        let ctx = try context()
        let a = ScoutExtractEvent(title: "Brooklyn Youth Chorus", presenter: "Brooklyn Youth Chorus",
                                  venue: "Merkin Hall", performanceDate: "2026-09-19",
                                  sourceUrl: "https://org.example/a")
        let b = ScoutExtractEvent(title: "Manhattan Girls Chorus", presenter: "Manhattan Girls Chorus",
                                  venue: "Bargemusic", performanceDate: "2026-10-03",
                                  sourceUrl: "https://org.example/b")
        let m = model(results: { id in self.results(.upcomingListings, [a, b], id: id) })
        m.urlText = "https://org.example/events"
        await m.start(now: Date())

        guard case .review(let events, _) = m.phase else { Issue.record("expected .review"); return }
        m.selected = [m.key(for: events[0])]        // he drops the second one

        let added = m.confirm(into: ctx, today: ScoutTestClock.beforeAllFixtures)

        #expect(added == 1)
        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(stored.count == 1)
        #expect(stored.first?.groupName.contains("Brooklyn") == true)
        #expect(stored.first?.tier != nil)          // ranked by the normal pipeline, not hand-inserted
    }

    // Dan's rule, end to end: a link he has actually added is refused the second time, and told plainly
    // why (the org gets watched, so re-reading buys nothing). This also makes the stale-results race
    // unreachable, which is why it replaces a freshness check rather than sitting beside one.
    @Test func aLinkAlreadyAddedIsRefusedTheSecondTime() async throws {
        let ctx = try context()
        let scratch = UserDefaults(suiteName: "LeadIntakeModelTests-\(UUID().uuidString)")!
        let event = ScoutExtractEvent(title: "Brooklyn Youth Chorus", presenter: "Brooklyn Youth Chorus",
                                      venue: "Merkin Hall", performanceDate: "2026-09-19",
                                      sourceUrl: "https://org.example/a")
        let make = { LeadIntakeModel(defaults: scratch,
                                     fetch: LeadIntakeModelTests.okFetch,
                                     pin: { _, _ in URL(fileURLWithPath: "/tmp/pinned.html") },
                                     launch: { _ in },
                                     readResults: { id in self.results(.upcomingListings, [event], id: id) }) }

        let first = make()
        first.urlText = "https://org.example/events"
        await first.start(now: Date())
        #expect(first.confirm(into: ctx, today: ScoutTestClock.beforeAllFixtures) == 1)

        // Same page, spelled the way a person actually re-pastes it (www, trailing slash).
        let second = make()
        second.urlText = "https://www.org.example/events/"
        await second.start(now: Date())

        guard case .problem(let msg) = second.phase else {
            Issue.record("expected .problem, got \(second.phase)"); return
        }
        #expect(msg.lowercased().contains("already"))
    }

    // ...but a link that never produced anything is NOT "handed over". A page that failed to read, or
    // whose shows he dropped, must be retryable: refusing it would strand him with no way back in.
    @Test func aLinkThatProducedNothingCanBeTriedAgain() async throws {
        let ctx = try context()
        let scratch = UserDefaults(suiteName: "LeadIntakeModelTests-\(UUID().uuidString)")!
        let event = ScoutExtractEvent(title: "A", presenter: "A", venue: "Merkin Hall",
                                      performanceDate: "2026-09-19", sourceUrl: "https://org.example/a")
        let make = { LeadIntakeModel(defaults: scratch,
                                     fetch: LeadIntakeModelTests.okFetch,
                                     pin: { _, _ in URL(fileURLWithPath: "/tmp/pinned.html") },
                                     launch: { _ in },
                                     readResults: { id in self.results(.upcomingListings, [event], id: id) }) }

        let first = make()
        first.urlText = "https://org.example/events"
        await first.start(now: Date())
        first.selected = []                                   // he dropped everything
        #expect(first.confirm(into: ctx, today: ScoutTestClock.beforeAllFixtures) == 0)

        let second = make()
        second.urlText = "https://org.example/events"
        await second.start(now: Date())

        guard case .review = second.phase else {
            Issue.record("expected .review (retryable), got \(second.phase)"); return
        }
    }

    @Test func confirmingNothingAddsNothing() async throws {
        let ctx = try context()
        let event = ScoutExtractEvent(title: "A", presenter: "A", venue: "Merkin Hall",
                                      performanceDate: "2026-09-19", sourceUrl: "https://org.example/a")
        let m = model(results: { id in self.results(.upcomingListings, [event], id: id) })
        m.urlText = "https://org.example/events"
        await m.start(now: Date())
        m.selected = []

        #expect(m.confirm(into: ctx, today: ScoutTestClock.beforeAllFixtures) == 0)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).isEmpty)
    }
}
