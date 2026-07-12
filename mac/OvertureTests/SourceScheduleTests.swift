import Testing
import Foundation
import SwiftData
@testable import Overture

// #802: what a single scout run does to each watched source, decided BEFORE anything is fetched.
//
// This is a pure plan over rows, so every rule that governs Dan's token spend and his queue's safety
// is a real test rather than an emergent property of a loop with a network call in it.
@MainActor
@Suite("What one scout run does to each source (#802)")
struct SourceScheduleTests {
    private func source(_ id: String, kind: SourceKind = .html, active: Bool = true,
                        lastChecked: Date? = nil) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: id, listingsURL: "https://\(id).example/events",
                              kind: kind)
        s.isActive = active
        s.lastCheckedAt = lastChecked
        return s
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 86_400) }

    // Carnegie never touches the generic fetch path. Its endpoint is a POST search API needing two
    // auth headers and a JSON body: SourceFetcher cannot GET it, hash it, or diff it. It runs its own
    // native extractor and costs nothing, so it is never budgeted and never deferred.
    @Test func anAlgoliaSourceRunsNativelyAndIsNeverBudgeted() {
        let plan = SourceSchedule.plan(
            sources: [source("carnegie", kind: .algolia), source("org-a"), source("org-b")],
            depth: .readChanged, budget: 1, now: now)

        #expect(plan.native.map(\.sourceId) == ["carnegie"])
        #expect(plan.fetch.map(\.sourceId).contains("carnegie") == false)
        #expect(plan.deferred.map(\.sourceId).contains("carnegie") == false)
    }

    // A source Dan stopped watching, or one an org asked him to stop, is not checked at all. This is
    // the one that must never regress: re-checking an org that asked to be left alone is how a
    // photographer's name gets a reputation.
    @Test func anInactiveSourceIsNotCheckedAtAll() {
        let refused = source("refused", active: false)
        let plan = SourceSchedule.plan(sources: [refused, source("fine")], depth: .readChanged,
                                       budget: 20, now: now)

        #expect(plan.fetch.map(\.sourceId) == ["fine"])
        #expect(plan.deferred.isEmpty)
        #expect(plan.native.isEmpty)
    }

    @Test func anInactiveAlgoliaSourceIsNotRunNativelyEither() {
        let plan = SourceSchedule.plan(sources: [source("carnegie", kind: .algolia, active: false)],
                                       depth: .readChanged, budget: 20, now: now)
        #expect(plan.native.isEmpty)
    }

    // Oldest first, so a budget STAGGERS rather than starves: a source at the back of the queue moves
    // to the front next run because its lastCheckedAt did not move.
    @Test func theLongestUncheckedSourceGoesFirst() {
        let plan = SourceSchedule.plan(
            sources: [source("yesterday", lastChecked: daysAgo(1)),
                      source("ancient", lastChecked: daysAgo(30)),
                      source("never", lastChecked: nil),
                      source("week", lastChecked: daysAgo(7))],
            depth: .readChanged, budget: 20, now: now)

        // Never checked is the oldest thing there is: it has been waiting since Dan added it.
        #expect(plan.fetch.map(\.sourceId) == ["never", "ancient", "week", "yesterday"])
    }

    @Test func theBudgetCapsHowManySourcesAreCheckedAndDefersTheRest() {
        let plan = SourceSchedule.plan(
            sources: [source("a", lastChecked: daysAgo(3)),
                      source("b", lastChecked: daysAgo(2)),
                      source("c", lastChecked: daysAgo(1))],
            depth: .readChanged, budget: 2, now: now)

        #expect(plan.fetch.map(\.sourceId) == ["a", "b"])
        #expect(plan.deferred.map(\.sourceId) == ["c"])
    }

    // Deferred is a real state and it is neither of the other two. It is not "fine" and it is not
    // "failing": it is "not checked today", and Dan has to be able to see that, or a source could go
    // unchecked for weeks while reporting as healthy.
    @Test func aDeferredSourceKeepsItsOldLastCheckedSoItIsFirstInLineNextRun() {
        let c = source("c", lastChecked: daysAgo(1))
        let plan = SourceSchedule.plan(
            sources: [source("a", lastChecked: daysAgo(3)), source("b", lastChecked: daysAgo(2)), c],
            depth: .readChanged, budget: 2, now: now)

        #expect(plan.deferred.map(\.sourceId) == ["c"])
        #expect(c.lastCheckedAt == daysAgo(1))   // untouched: the plan does not pretend it was checked
    }

    // MARK: - Watching is free. Reading is not. (Dan's 4th decision, 2026-07-12)

    // The daily automatic run fetches and hashes every source, so a dead source is noticed within a
    // day rather than whenever Dan next scouts by hand. It costs nothing and it never launches a
    // Claude run.
    @Test func theDailyRunStillChecksEverySourceBecauseWatchingIsFree() {
        let plan = SourceSchedule.plan(
            sources: [source("a"), source("b"), source("c")],
            depth: .watchOnly, budget: 20, now: now)

        #expect(plan.fetch.count == 3)
        #expect(plan.maySpendTokens == false)
    }

    // Carnegie STILL ingests on the daily run. Its extraction is native Algolia JSON, so it is free,
    // and not ingesting it would be a straight regression of the behavior Dan has today.
    @Test func carnegieStillFullyIngestsOnTheFreeDailyRun() {
        let plan = SourceSchedule.plan(sources: [source("carnegie", kind: .algolia)],
                                       depth: .watchOnly, budget: 20, now: now)
        #expect(plan.native.map(\.sourceId) == ["carnegie"])
    }

    @Test func onlyAScoutDanStartedMaySpendTokens() {
        let watching = SourceSchedule.plan(sources: [source("a")], depth: .watchOnly, budget: 20, now: now)
        let reading = SourceSchedule.plan(sources: [source("a")], depth: .readChanged, budget: 20, now: now)

        #expect(watching.maySpendTokens == false)
        #expect(reading.maySpendTokens == true)
    }

    // The budget bounds the run Dan STARTS (he could add fifty sources and then press Scout). The free
    // daily run has nothing to bound: it spends nothing whatever it checks, and capping it would mean
    // silently not watching sources Dan asked us to watch, which is the one thing this feature promises.
    @Test func theFreeDailyRunIsNotBudgeted() {
        let many = (1...50).map { source("org-\($0)", lastChecked: daysAgo($0)) }
        let plan = SourceSchedule.plan(sources: many, depth: .watchOnly, budget: 20, now: now)

        #expect(plan.fetch.count == 50)
        #expect(plan.deferred.isEmpty)
    }

    @Test func theRunDanStartsIsBudgeted() {
        let many = (1...50).map { source("org-\($0)", lastChecked: daysAgo($0)) }
        let plan = SourceSchedule.plan(sources: many, depth: .readChanged, budget: 20, now: now)

        #expect(plan.fetch.count == 20)
        #expect(plan.deferred.count == 30)
    }
}

// What one source's check DECIDED, given what came back from the network. Pure, so every rule about
// Dan's token spend and his sources' health is a test rather than a branch inside an async loop.
@MainActor
@Suite("What one source's check decides (#802)")
struct SourceCheckTests {
    private func source(_ id: String = "org", hash: String? = nil,
                        health: SourceHealth = .ok) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: id, listingsURL: "https://\(id).example/events",
                              kind: .html)
        s.lastContentHash = hash
        s.health = health
        return s
    }

    private func page(_ hash: String) -> FetchedPage {
        FetchedPage(normalizedHTML: "<p>listings</p>", finalURL: "https://org.example/events",
                    contentHash: hash)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // The hash is a CORRECTNESS mechanism, not only a cost lever. If the page did not change, the
    // extractor never runs, so an extracted title cannot drift between runs and re-key a prospect into
    // a duplicate while the original gets marked gone. Determinism by abstention.
    @Test func anUnchangedPageIsNotRead() {
        let s = source(hash: "abc")
        let decision = SourceCheck.decide(source: s, result: .success(page("abc")),
                                          depth: .readChanged, now: now)

        #expect(decision == .unchanged)
        #expect(s.health == .ok)
        #expect(s.lastCheckedAt == now)
        #expect(s.hasUnreadChanges == false)
    }

    @Test func aChangedPageIsReadWhenDanStartedTheRun() {
        let s = source(hash: "abc")
        let decision = SourceCheck.decide(source: s, result: .success(page("xyz")),
                                          depth: .readChanged, now: now)

        #expect(decision == .read(page("xyz")))
        #expect(s.hasUnreadChanges)          // until an ingest actually lands it
        #expect(s.health == .ok)
    }

    // The free daily run notices the change and says so, but does not spend a token on it. That is the
    // whole of Dan's 4th decision, in one branch.
    @Test func aChangedPageIsOnlyFlaggedOnTheFreeDailyRun() {
        let s = source(hash: "abc")
        let decision = SourceCheck.decide(source: s, result: .success(page("xyz")),
                                          depth: .watchOnly, now: now)

        #expect(decision == .changedButNotRead)
        #expect(s.hasUnreadChanges)          // Dan can see there is something waiting
        #expect(s.health == .ok)
        #expect(s.lastCheckedAt == now)
    }

    // A source with no hash yet has never been ingested, so it is changed by definition.
    @Test func aSourceNeverIngestedCountsAsChanged() {
        let s = source(hash: nil)
        #expect(SourceCheck.decide(source: s, result: .success(page("first")),
                                   depth: .readChanged, now: now) == .read(page("first")))
    }

    // The hash is NEVER stamped by a check, only by an ingest that saved. Stamp it here and a run that
    // reads everything and then fails to persist (the #499 saveFailed path) leaves the hash saying
    // "nothing changed": the source then fetches fine, reports fine, and silently ingests nothing,
    // forever.
    @Test func aCheckNeverStampsTheContentHash() {
        let s = source(hash: "abc")
        _ = SourceCheck.decide(source: s, result: .success(page("xyz")), depth: .readChanged, now: now)
        #expect(s.lastContentHash == "abc")   // still the last hash we actually INGESTED
    }

    // MARK: - Failure is named, recorded, and never fatal to the source

    @Test func everyFetchFailureIsNamedOnTheRowAndTheSourceKeepsBeingWatched() {
        let failures: [SourceFetchError] = [
            .http(404), .http(429), .unreachable,
            .notHTML("application/pdf"), .redirectedAway("thirdstreetmusicschool.org"),
        ]
        for error in failures {
            let s = source()
            let decision = SourceCheck.decide(source: s, result: .failure(error), depth: .readChanged,
                                              now: now)

            #expect(decision == .failed(.fetch(error)))
            #expect(s.health == .failing)
            #expect(s.lastFailure == .fetch(error))
            #expect(s.lastCheckedAt == now)

            // The rule Dan was most explicit about: a broken source is STILL WATCHED. Nothing but an
            // org's refusal or his own removal ever takes a source off the list.
            #expect(s.isActive, "a failing source must never deactivate itself")
            #expect(s.inactiveReason == nil)
        }
    }

    // A failing source has not succeeded, so its last-succeeded time must not move. Otherwise a source
    // that has been 404ing for a month would still read as "checked an hour ago, all fine".
    @Test func aFailedCheckDoesNotClaimSuccess() {
        let s = source()
        s.lastSucceededAt = Date(timeIntervalSince1970: 1)
        _ = SourceCheck.decide(source: s, result: .failure(.http(500)), depth: .readChanged, now: now)

        #expect(s.lastSucceededAt == Date(timeIntervalSince1970: 1))
        #expect(s.successfulCheckCount == 0)
    }

    // A source that starts working again says so, rather than carrying a stale error forever.
    @Test func aSourceThatRecoversClearsItsFailure() {
        let s = source(hash: "abc", health: .failing)
        s.lastFailure = .fetch(.http(500))

        _ = SourceCheck.decide(source: s, result: .success(page("abc")), depth: .readChanged, now: now)

        #expect(s.health == .ok)
        #expect(s.lastFailure == nil)
    }
}
