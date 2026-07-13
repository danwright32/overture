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

    // A page with REAL content in it. It has to be: the model now refuses, natively, to spend a Claude
    // run on a page whose bytes carry only a navigation shell (the Wix case Dan hit on his first real
    // lead), so a one-character fixture would be rejected as unreadable and every test below would be
    // exercising the wrong path.
    private static let realPageHTML =
        "<h1>Upcoming concerts</h1>"
        + "<p>Second Ending Ensemble presents an evening of chamber music at Merkin Hall, with works "
        + "by Brahms and Dvorak, followed by a conversation with the performers. Doors open at seven "
        + "and the programme begins at half past. Tickets are available at the box office or online, "
        + "and members of the ensemble stay afterwards to talk with anyone who would like to.</p>"
        + "<ul>"
        + "<li><a href=\"/show/1\">October 3: Piano Trios of Haydn, Brahms and Dvorak, with guests "
        + "from the orchestra, in the recital hall on the second floor</a></li>"
        + "<li><a href=\"/show/2\">November 14: Mozart and Schubert, works for violin and piano, "
        + "an evening built around the late chamber works of both composers</a></li>"
        + "<li><a href=\"/show/3\">December 5: Complete Beethoven Piano Sonatas with Conversation, "
        + "Part 2, the second of five evenings running through the spring</a></li>"
        + "</ul>"
        + "<p>All concerts begin at half past seven. The hall is fully accessible, and there is a "
        + "lift to the second floor from the lobby entrance on the street.</p>"

    private static func okFetch(_ url: URL) async throws -> FetchedPage {
        FetchedPage(normalizedHTML: realPageHTML, finalURL: url.absoluteString, contentHash: "h")
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
        // A login wall, NOT a JavaScript-drawn calendar. Two different causes, two different messages:
        // telling him an Instagram link "builds its calendar with JavaScript" would be confidently wrong.
        #expect(msg.lowercased().contains("login"))
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

    // What Dan hit on his second link: the FIRST run had already written its results and shown him an
    // answer, but its process was still exiting, so it still held the lock. His next attempt was
    // refused outright with "a scout-extract run is already in progress. Wait for it to finish."
    //
    // That is a dead end dressed as an error. He did the right thing, the app knew what he wanted, and
    // it told him to go away and try again. A run that is finishing is a reason to WAIT (a few seconds),
    // not a reason to refuse: the lock exists to stop two runs clobbering one results file, not to stop
    // Dan queueing his next lead.
    @Test func aRunThatIsStillFinishingIsWaitedOutRatherThanRefused() async {
        let event = ScoutExtractEvent(title: "Second Ending Ensemble", presenter: "Second Ending Ensemble",
                                      venue: "Merkin Hall", performanceDate: "2026-10-03",
                                      sourceUrl: "https://org.example/a")
        var attempts = 0
        let m = model(launch: { _ in
                          attempts += 1
                          // Busy for the first two tries, as a run finishes up; free on the third.
                          if attempts < 3 { throw ScoutExtractService.ExtractLaunchError.alreadyRunning }
                      },
                      results: { id in self.results(.upcomingListings, [event], id: id) })
        m.urlText = "https://org.example/events"

        await m.start(now: Date(), pollEvery: 0, sleep: { _ in })

        guard case .review(let events, _) = m.phase else {
            Issue.record("expected .review after waiting out the busy run, got \(m.phase)"); return
        }
        #expect(events.count == 1)
        #expect(attempts == 3)          // it waited and retried rather than giving up on the first no
    }

    // ...but it must not wait FOREVER. A run that is genuinely wedged has to end in something Dan can
    // act on, not an eternal "still working" that is indistinguishable from progress.
    @Test func aRunThatNeverFreesTheLockEventuallySaysSo() async {
        let m = model(launch: { _ in throw ScoutExtractService.ExtractLaunchError.alreadyRunning })
        m.urlText = "https://org.example/events"

        await m.start(now: Date(), pollEvery: 0, giveUpAfter: 0, sleep: { _ in })

        guard case .problem(let msg) = m.phase else {
            Issue.record("expected .problem, got \(m.phase)"); return
        }
        #expect(msg.lowercased().contains("still") || msg.lowercased().contains("in progress"))
    }

    // The Wix case, caught natively before a Claude run is spent: a page whose bytes carry only a
    // navigation shell is UNREADABLE, and says so honestly, rather than being handed to the AI to
    // produce a confident wrong "no events here" about a page full of events we cannot see.
    @Test func aJavaScriptOnlySiteIsCalledUnreadableWithoutSpendingARun() async {
        var launched = false
        let shell = FetchedPage(
            normalizedHTML: "<div><a>Home</a><a>Our Story</a><a>Contact</a></div><div>Wix.com</div>",
            finalURL: "https://www.secondendingensemble.com/", contentHash: "h")
        let m = model(fetch: { _ in shell }, launch: { _ in launched = true })
        m.urlText = "https://www.secondendingensemble.com/"

        await m.start(now: Date())

        guard case .problem(let msg) = m.phase else { Issue.record("expected .problem"); return }
        #expect(!launched)                                    // no Claude run spent on a page we cannot read
        #expect(msg.lowercased().contains("can't read") || msg.lowercased().contains("cannot read"))
        // And it must NOT blame the page for not being an events page: it IS one; we are the blind ones.
        #expect(!msg.lowercased().contains("not their events page"))
    }

    // If Overture reads a DIFFERENT page than the one Dan pasted, it has to say so. He pasted his
    // ensemble's site; the listing came off Lincoln Center's. Silently swapping the page under him would
    // be exactly the kind of quiet cleverness that makes a tool impossible to trust.
    @Test func followingATicketLinkIsDisclosedNotDoneQuietly() async {
        let event = ScoutExtractEvent(title: "Second Ending Ensemble: Mahler 1", presenter: "Second Ending Ensemble",
                                      venue: "Alice Tully Hall", performanceDate: "2026-10-03",
                                      sourceUrl: "https://lincolncenter.org/e/1")
        var page = FetchedPage(normalizedHTML: LeadIntakeModelTests.realPageHTML,
                               finalURL: "https://lincolncenter.org/venue/alice-tully-hall/second-ending-290",
                               contentHash: "h")
        page.followedTicketLinkFrom = "https://www.secondendingensemble.com/single-project-1"

        let m = model(fetch: { _ in page },
                      results: { id in self.results(.upcomingListings, [event], id: id) })
        m.urlText = "https://www.secondendingensemble.com/single-project-1"

        await m.start(now: Date())

        guard case .review(_, let note) = m.phase else { Issue.record("expected .review"); return }
        let text = try! #require(note)
        #expect(text.contains("lincolncenter.org"))          // names the page it actually read
        #expect(text.lowercased().contains("ticket link"))   // and says WHY it read that one
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

// #848: the run FINISHED and wrote nothing for the source we asked about, and the sheet kept spinning.
//
// Dan watched "Reading the page 0 of 1... 2:59" tick upward on a run whose process had already exited
// three minutes earlier. It would have counted to ten minutes and then blamed a timeout, which is not
// what happened: the run finished fast and produced nothing.
//
// The app had everything it needed to know that. The run's heartbeat marker was gone, so `isRunning` was
// already false. The wait loop simply never asked, and treated "no results yet" as "still working".
// CLAUDE.md's rule is explicit that still-alive and failed must be visibly distinct, and seven minutes of
// a live-looking counter on a dead run is the exact defect it exists to prevent.
@MainActor
@Suite("The lead sheet stops waiting on a run that is already dead (#848)")
struct LeadIntakeDeadRunTests {
    private static let realPageHTML =
        "<h1>Upcoming concerts</h1>"
        + "<p>Second Ending Ensemble presents an evening of chamber music at Merkin Hall, with works "
        + "by Brahms and Dvorak, followed by a conversation with the performers. Doors open at seven "
        + "and the programme begins at half past. Tickets are available at the box office or online.</p>"
        + "<ul><li><a href=\"/show/1\">October 3: Piano Trios of Haydn, Brahms and Dvorak, in the "
        + "recital hall on the second floor</a></li></ul>"
        + "<p>All concerts begin at half past seven. The hall is fully accessible.</p>"

    private func model(alive: @escaping () -> Bool,
                       results: @escaping (String) -> ScoutExtractResults? = { _ in nil })
    -> LeadIntakeModel {
        LeadIntakeModel(
            defaults: UserDefaults(suiteName: "LeadIntakeDeadRunTests-\(UUID().uuidString)")!,
            fetch: { url in
                FetchedPage(normalizedHTML: Self.realPageHTML, finalURL: url.absoluteString,
                            contentHash: "h")
            },
            pin: { _, _ in URL(fileURLWithPath: "/tmp/pinned.html") },
            launch: { _ in },
            readResults: results,
            isRunAlive: alive)
    }

    // THE test. The run is gone and it left nothing for us. Say so at once, and say what actually
    // happened, rather than counting to ten minutes and then blaming a timeout that did not occur.
    @Test func aRunThatDiedWithoutResultsIsReportedAtOnce() async {
        let m = model(alive: { false })          // its heartbeat is gone: the process has exited
        m.urlText = "https://org.example/events"

        await m.start(now: Date(), pollEvery: 0, giveUpAfter: 600, sleep: { _ in })

        guard case .problem(let message) = m.phase else {
            Issue.record("expected .problem, got \(m.phase)"); return
        }
        // What actually happened: it finished, and it produced nothing.
        #expect(message.localizedCaseInsensitiveContains("finished"))
        // NOT a timeout. That is a different fault with a different fix, and saying it would send Dan
        // off to wait for a run that is already dead.
        #expect(message.localizedCaseInsensitiveContains("in time") == false)
    }

    // A run that is still genuinely alive must NOT be cut short just because it has not written yet. The
    // whole point of the heartbeat is to tell a slow run from a dead one, and getting this backwards
    // would kill every run that takes longer than one poll.
    @Test func aSlowButLivingRunIsLeftAlone() async {
        var polls = 0
        let m = model(alive: { true },           // still beating
                      results: { id in
                          polls += 1
                          // It writes on the third poll: slow, not dead.
                          guard polls >= 3 else { return nil }
                          return ScoutExtractResults(
                              version: 1, generatedAt: "2026-07-12T00:00:00Z",
                              results: [ScoutExtractResult(
                                  sourceId: id, verdict: .upcomingListings,
                                  events: [ScoutExtractEvent(title: "Second Ending Ensemble",
                                                             presenter: "Second Ending Ensemble",
                                                             venue: "Merkin Hall",
                                                             performanceDate: "2099-10-03",
                                                             sourceUrl: "https://org.example/1")],
                                  note: nil)])
                      })
        m.urlText = "https://org.example/events"

        await m.start(now: Date(), pollEvery: 0, giveUpAfter: 600, sleep: { _ in })

        guard case .review(let events, _) = m.phase else {
            Issue.record("a slow run must be waited for, not killed. Got \(m.phase)"); return
        }
        #expect(events.count == 1)
    }

    // The race that would make this worse than the bug: the run writes its results and exits between two
    // polls. The results are RIGHT THERE. Reading them must win over noticing the process is gone, or a
    // fast, perfectly successful run would be reported as having produced nothing.
    @Test func aRunThatFinishedAndWroteResultsIsReadEvenThoughItIsNoLongerAlive() async {
        let m = model(alive: { false },          // already exited...
                      results: { id in           // ...but it left us exactly what we asked for
                          ScoutExtractResults(
                              version: 1, generatedAt: "2026-07-12T00:00:00Z",
                              results: [ScoutExtractResult(
                                  sourceId: id, verdict: .upcomingListings,
                                  events: [ScoutExtractEvent(title: "Second Ending Ensemble",
                                                             presenter: "Second Ending Ensemble",
                                                             venue: "Merkin Hall",
                                                             performanceDate: "2099-10-03",
                                                             sourceUrl: "https://org.example/1")],
                                  note: nil)])
                      })
        m.urlText = "https://org.example/events"

        await m.start(now: Date(), pollEvery: 0, giveUpAfter: 600, sleep: { _ in })

        guard case .review(let events, _) = m.phase else {
            Issue.record("a finished run's results must be read, not discarded. Got \(m.phase)"); return
        }
        #expect(events.count == 1)
    }
}
