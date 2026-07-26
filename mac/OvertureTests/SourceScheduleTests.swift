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
                        lastChecked: Date? = nil, lastManualRead: Date? = nil,
                        hasUnreadChanges: Bool = false) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: id, listingsURL: "https://\(id).example/events",
                              kind: kind)
        s.isActive = active
        s.lastCheckedAt = lastChecked
        s.lastManualReadAt = lastManualRead
        s.hasUnreadChanges = hasUnreadChanges
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

    // #1189: a run Dan started orders by the manual scout's OWN fairness clock, not the shared fetch
    // clock. Oldest-manual-read first, so a budget STAGGERS rather than starves: a source at the back of
    // one press moves to the front of the next, because the daily watch-only run never advances this clock
    // and so cannot flatten it into a tie the way it flattens lastCheckedAt.
    @Test func theLongestUnreadSourceGoesFirst() {
        let plan = SourceSchedule.plan(
            sources: [source("yesterday", lastManualRead: daysAgo(1)),
                      source("ancient", lastManualRead: daysAgo(30)),
                      source("never", lastManualRead: nil),
                      source("week", lastManualRead: daysAgo(7))],
            depth: .readChanged, budget: 20, now: now)

        // Never manually read is the oldest thing there is: it has been waiting since Dan added it.
        #expect(plan.fetch.map(\.sourceId) == ["never", "ancient", "week", "yesterday"])
    }

    @Test func theBudgetCapsHowManySourcesAreCheckedAndDefersTheRest() {
        let plan = SourceSchedule.plan(
            sources: [source("a", lastManualRead: daysAgo(3)),
                      source("b", lastManualRead: daysAgo(2)),
                      source("c", lastManualRead: daysAgo(1))],
            depth: .readChanged, budget: 2, now: now)

        #expect(plan.fetch.map(\.sourceId) == ["a", "b"])
        #expect(plan.deferred.map(\.sourceId) == ["c"])
    }

    // Deferred is a real state and it is neither of the other two. It is not "fine" and it is not
    // "failing": it is "not checked today", and Dan has to be able to see that, or a source could go
    // unchecked for weeks while reporting as healthy. The plan never advances a clock, so the deferred
    // source's manual clock is untouched and it is genuinely first in line next press.
    @Test func aDeferredSourceKeepsItsOldManualReadSoItIsFirstInLineNextRun() {
        let c = source("c", lastManualRead: daysAgo(1))
        let plan = SourceSchedule.plan(
            sources: [source("a", lastManualRead: daysAgo(3)), source("b", lastManualRead: daysAgo(2)), c],
            depth: .readChanged, budget: 2, now: now)

        #expect(plan.deferred.map(\.sourceId) == ["c"])
        #expect(c.lastManualReadAt == daysAgo(1))   // untouched: the plan does not pretend it was read
    }

    // MARK: - #1189: changed-first, and the manual clock the daily flatten cannot defeat

    // The starvation the daily run created, reproduced. The overnight watch-only run stamps an identical
    // lastCheckedAt on every fetchable source, and the list is longer than the cap. A source with unread
    // changes sitting deep in what used to be the deferred tail MUST still be read: a changed calendar is
    // never starved behind unchanged ones (an unchanged one has nothing to read).
    @Test func aChangedSourceInTheTailIsNeverStarvedByTheDailyFlatten() {
        let flat = daysAgo(1)   // the overnight run just stamped everyone identically
        var sources = (1...25).map { source("org-\($0)", lastChecked: flat) }
        // The changed source sorts LAST by every non-#1189 key (newest id, same flat clock), so before the
        // fix it lived permanently in the deferred tail past the cap of 20.
        sources.append(source("zzz-changed", lastChecked: flat, hasUnreadChanges: true))

        let plan = SourceSchedule.plan(sources: sources, depth: .readChanged, budget: 20, now: now)

        #expect(plan.fetch.contains { $0.sourceId == "zzz-changed" })
        #expect(plan.deferred.contains { $0.sourceId == "zzz-changed" } == false)
        // And it is first: a changed venue outranks every unchanged one.
        #expect(plan.fetch.first?.sourceId == "zzz-changed")
    }

    // Changed sources are ordered ahead of unchanged ones, even when the changed one looks "newer" by the
    // fetch clock. Coverage then converges: each press clears up to the cap of changed sources, and their
    // flag clears on successful ingest, so the next press reads the next batch.
    @Test func changedSourcesAreOrderedAheadOfUnchangedOnes() {
        let unchangedButOldest = source("a-unchanged", lastChecked: daysAgo(30))
        let changedButNewest = source("z-changed", lastChecked: daysAgo(1), hasUnreadChanges: true)
        let plan = SourceSchedule.plan(sources: [unchangedButOldest, changedButNewest],
                                       depth: .readChanged, budget: 20, now: now)

        #expect(plan.fetch.map(\.sourceId) == ["z-changed", "a-unchanged"])
    }

    // The per-press cap still bounds paid AI reads even when MORE than the cap have changed at once (a
    // first-ever run, or a big batch): changed-first must never let a run read more than the cap.
    @Test func theCapStillBoundsReadsWhenMoreThanTheCapHaveChanged() {
        let sources = (1...30).map { source("org-\($0)", hasUnreadChanges: true) }
        let plan = SourceSchedule.plan(sources: sources, depth: .readChanged, budget: 20, now: now)

        #expect(plan.fetch.count == 20)
        #expect(plan.deferred.count == 10)
    }

    // Only the deferred sources that actually carry unread listings are WAITING to be read. A deferred
    // source with nothing new has nothing to read (the free daily run keeps its hash current), so it must
    // not inflate the "N venues still waiting" count into a fixed total-minus-budget that never converges.
    @Test func onlyDeferredSourcesWithUnreadChangesAreWaiting() {
        let changed = source("changed", hasUnreadChanges: true)
        let quiet = source("quiet", hasUnreadChanges: false)

        #expect(SourceSchedule.waitingToRead(deferred: [changed, quiet]).map(\.sourceId) == ["changed"])
        #expect(SourceSchedule.waitingToRead(deferred: [quiet]).isEmpty)
    }

    // MARK: - #1546: a retry owed is not a page with something on it

    // A source whose last read FAILED and whose bytes have not moved since. `ScoutExtractIngest.fail()`
    // sets hasUnreadChanges on every failed read, deliberately, and for a no_dated_content failure nothing
    // ever clears it, so this row's flag is pinned on forever.
    private func stuckOnAFailedRead(_ id: String, lastManualRead: Date? = nil,
                                    failure: SourceFailure = .verdict(.noDatedContent)) -> WatchedSource {
        let s = source(id, lastManualRead: lastManualRead, hasUnreadChanges: true)
        s.lastFailure = failure
        s.pendingContentHash = "same-bytes"
        s.lastObservedContentHash = "same-bytes"
        return s
    }

    // The live harm. `manualReadOrder` sorted on the raw flag, so a page that failed and cannot succeed
    // sorted AHEAD of a venue that genuinely posted a new season, on every press, forever. That order is
    // what ScoutReadBudget's "read the first batch" slices, so the dead page was eating a slot in the batch
    // Dan agreed to pay for.
    @Test func aRetryOwedOnUnchangedBytesDoesNotOutrankAGenuineChange() {
        let stuck = stuckOnAFailedRead("a-stuck")
        let genuinelyChanged = source("z-changed", hasUnreadChanges: true)

        let plan = SourceSchedule.plan(sources: [stuck, genuinelyChanged], depth: .readChanged,
                                       budget: 20, now: now)

        #expect(plan.fetch.map(\.sourceId) == ["z-changed", "a-stuck"])
    }

    // It is DEMOTED, not dropped. #1217 re-reads a still broken source on a run Dan started, on the
    // assumption he fixed the cause between presses, and that is untouched here: the stuck source still
    // outranks a quiet one, which has nothing to read at all.
    @Test func aRetryOwedStillOutranksASourceWithNothingToRead() {
        let stuck = stuckOnAFailedRead("z-stuck")
        let quiet = source("a-quiet", hasUnreadChanges: false)

        let plan = SourceSchedule.plan(sources: [stuck, quiet], depth: .readChanged, budget: 20, now: now)

        #expect(plan.fetch.map(\.sourceId) == ["z-stuck", "a-quiet"])
    }

    // The whole point of deciding this on the BYTES rather than on the failure. The org fixes their page
    // and posts a season: the hash the free daily pass now sees no longer matches the bytes the failed read
    // was handed, so this is real unread content again and goes straight back to the front. Nothing has to
    // notice or reset anything for that to happen.
    @Test func aPageThatMovedSinceItsFailedReadIsARealChangeAgain() {
        let moved = stuckOnAFailedRead("z-moved")
        moved.lastObservedContentHash = "new-bytes"
        let quiet = source("a-quiet", hasUnreadChanges: false)

        #expect(moved.unreadIsOnlyAnOwedRetry == false)
        let plan = SourceSchedule.plan(sources: [quiet, moved], depth: .readChanged, budget: 20, now: now)
        #expect(plan.fetch.map(\.sourceId) == ["z-moved", "a-quiet"])
    }

    // A source that has never been read at all is not owed a retry, it is genuinely unread, and it keeps
    // its place at the front. Its failure is nil, which is the first thing the rule asks about.
    @Test func aNeverReadSourceIsRealBacklogNotARetry() {
        let brandNew = source("z-new", hasUnreadChanges: true)

        #expect(brandNew.unreadIsOnlyAnOwedRetry == false)
        #expect(brandNew.isCarryingUnreadListings)
    }

    // The count half. A stuck source is not WAITING to be read: reading it again reproduces the same
    // failure. Counting it kept the popup's "N venues are still waiting" off zero however many times Dan
    // pressed Run again, which is the never converging count #1431 fixed arriving through another door.
    @Test func aRetryOwedOnUnchangedBytesIsNotCountedAsWaitingToRead() {
        let stuck = stuckOnAFailedRead("stuck")
        let changed = source("changed", hasUnreadChanges: true)

        #expect(SourceSchedule.waitingToRead(deferred: [stuck, changed]).map(\.sourceId) == ["changed"])
        #expect(SourceSchedule.waitingToRead(deferred: [stuck]).isEmpty)
    }

    // The failure path across REPEATED presses, which is the shape the bug actually had: not one bad run,
    // but the same bad run forever. Two presses, the page still failing and still serving the same bytes,
    // and the genuine change must be first both times and the waiting count empty both times.
    @Test func aStillFailingSourceNeverReclaimsTheFrontAcrossRepeatedPresses() {
        let stuck = stuckOnAFailedRead("a-stuck")
        let changed = source("z-changed", hasUnreadChanges: true)

        for press in 1...2 {
            let plan = SourceSchedule.plan(sources: [stuck, changed], depth: .readChanged,
                                           budget: 20, now: now)
            #expect(plan.fetch.map(\.sourceId) == ["z-changed", "a-stuck"], "press \(press)")
            #expect(SourceSchedule.waitingToRead(deferred: plan.fetch).map(\.sourceId) == ["z-changed"],
                    "press \(press)")
            // The press ends the way a real one does for a page with nothing dated on it: it fails again,
            // re-setting the flag and leaving the bytes exactly where they were.
            stuck.hasUnreadChanges = true
            stuck.lastFailure = .verdict(.noDatedContent)
        }
    }

    // A fetch that never landed is owed a retry too, and for the same reason: nobody has seen new listings
    // here, so it is not backlog. It is still shown as failing, which is where a broken source belongs.
    @Test func aSourceThatCouldNotBeFetchedIsAlsoARetryNotBacklog() {
        let unreachable = stuckOnAFailedRead("unreachable", failure: .fetch(.unreachable))

        #expect(unreachable.unreadIsOnlyAnOwedRetry)
        #expect(SourceSchedule.waitingToRead(deferred: [unreachable]).isEmpty)
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

    // #1217: a source whose last read DROPPED events (the degraded "won't mark anything gone until it
    // can confirm a venue" state, lastUnreadableCount > 0) is re-read on the next MANUAL scout even when
    // its page is byte-for-byte unchanged, on the assumption Dan fixed the underlying cause (a code fix,
    // a runbook fix, a corrected URL) between scouts. Without this the fix never reaches the already-seen
    // show, because an unchanged hash reads as "nothing to do".
    @Test func aDegradedSourceIsReReadOnAManualScoutEvenWhenUnchanged() {
        let s = source(hash: "abc")
        s.lastUnreadableCount = 1
        let decision = SourceCheck.decide(source: s, result: .success(page("abc")),
                                          depth: .readChanged, now: now)
        #expect(decision == .read(page("abc")))
    }

    // A source whose last CHECK was a hard fetch failure is likewise re-read on a manual scout when it
    // now fetches an unchanged page: Dan may have fixed the address or the site may be back up, and the
    // fix has to reach the show even though the bytes match the last ingest.
    @Test func aFailingSourceIsReReadOnAManualScoutWhenItNowFetchesUnchanged() {
        let s = source(hash: "abc", health: .failing)
        let decision = SourceCheck.decide(source: s, result: .success(page("abc")),
                                          depth: .readChanged, now: now)
        #expect(decision == .read(page("abc")))
    }

    // The retry is the SPEND path only. The free daily watch-only run never re-reads a degraded source:
    // it costs a token, and the daily run's whole promise is that it never spends.
    @Test func aDegradedSourceIsNotReReadOnTheFreeDailyRun() {
        let s = source(hash: "abc")
        s.lastUnreadableCount = 1
        let decision = SourceCheck.decide(source: s, result: .success(page("abc")),
                                          depth: .watchOnly, now: now)
        #expect(decision == .unchanged)
    }

    // #1498: the retry used to key off the unreadable COUNT, which is only one of the three things a
    // readability line can be about. A source whose line is about rows the source itself published with no
    // venue has an unreadable count of zero, so it never earned the retry, and a fix to the rule that wrote
    // that line could not reach it until its page happened to change on its own. Measured on the live store:
    // four sources were in exactly that state with no way out.
    @Test func aSourceWhoseOnlyComplaintIsStructuralGapsIsAlsoReReadOnAManualScout() {
        let s = source(hash: "abc")
        s.lastReadableCount = 58
        s.baselineFeedCount = 58
        s.lastStructuralGapCount = 34          // OPERA America's blank-venue rows: unreadable is still 0
        #expect(s.lastUnreadableCount == 0)    // so the old rule did not fire
        #expect(s.readabilityNote != nil)      // yet Dan is being shown a line about it

        #expect(SourceCheck.decide(source: s, result: .success(page("abc")),
                                   depth: .readChanged, now: now) == .read(page("abc")))
    }

    // The shrunken-feed hold is the other one, and it is the case that could get PERMANENTLY stuck: the hold
    // only clears once the smaller size holds for selfHealThreshold reads, and a page that never changes
    // again never earns a read, so it would hold forever. 54 Below is the live example (16 of a usual 28).
    @Test func aSourceHoldingOnAShrunkenFeedIsAlsoReReadOnAManualScout() {
        let s = source(hash: "abc")
        s.lastReadableCount = 16
        s.baselineFeedCount = 28
        #expect(s.lastUnreadableCount == 0)
        #expect(s.readabilityNote != nil)

        #expect(SourceCheck.decide(source: s, result: .success(page("abc")),
                                   depth: .readChanged, now: now) == .read(page("abc")))
    }

    // The cost gate, which is the whole reason this is a note and not "re-read everything": a source with
    // nothing to say is not re-read, however many times Dan presses Scout. Without this the widened rule
    // would turn every press into a full paid sweep of all 62 sources.
    @Test func aSourceWithNothingToSayIsStillNeverReReadWhenUnchanged() {
        let s = source(hash: "abc")
        s.lastReadableCount = 40
        s.baselineFeedCount = 40
        #expect(s.readabilityNote == nil)

        #expect(SourceCheck.decide(source: s, result: .success(page("abc")),
                                   depth: .readChanged, now: now) == .unchanged)
    }

    // And neither new case reaches the free daily run, which still never spends a token.
    @Test func theWidenedRetryStillNeverFiresOnTheFreeDailyRun() {
        let gaps = source(hash: "abc")
        gaps.lastReadableCount = 58
        gaps.baselineFeedCount = 58
        gaps.lastStructuralGapCount = 34

        let shrunken = source(hash: "abc")
        shrunken.lastReadableCount = 16
        shrunken.baselineFeedCount = 28

        for s in [gaps, shrunken] {
            #expect(SourceCheck.decide(source: s, result: .success(page("abc")),
                                       depth: .watchOnly, now: now) == .unchanged)
        }
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

    // #1048: a check DOES record the hash it saw, ingested or not. That is what lets the Sources confirm
    // affordance tell a fresh read from one a watch-only pass has since seen change: the free daily run
    // notices the page moved on but never re-reads, so without this the confirm would anchor to stale
    // bytes and silently fail to suppress. Recorded on BOTH branches (changed and unchanged) and on the
    // watch-only run, because "the live page as far as we know" is true whatever the run did next.
    @Test func aCheckRecordsTheHashItSaw() {
        let changed = source(hash: "abc")
        _ = SourceCheck.decide(source: changed, result: .success(page("xyz")),
                               depth: .watchOnly, now: now)
        #expect(changed.lastObservedContentHash == "xyz")     // the free daily run saw new bytes

        let unchanged = source(hash: "abc")
        _ = SourceCheck.decide(source: unchanged, result: .success(page("abc")),
                               depth: .readChanged, now: now)
        #expect(unchanged.lastObservedContentHash == "abc")   // still current, and now recorded

        let failed = source(hash: "abc")
        failed.lastObservedContentHash = "abc"
        _ = SourceCheck.decide(source: failed, result: .failure(.http(500)),
                               depth: .readChanged, now: now)
        #expect(failed.lastObservedContentHash == "abc")      // a fetch that failed saw nothing new
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
