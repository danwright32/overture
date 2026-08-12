import Testing
import Foundation
import SwiftData

// #1759: a source that has failed to read for ten runs said exactly what one that failed once said.
//
// The failure line is a PROMISE ("The next scout will try it again"), and after several runs it is a
// promise the app has made and broken every time without ever saying so. Nothing on the row counted
// consecutive runs that came away without reading the page, so the difference between a hiccup and a
// calendar that is simply gone was invisible, and Dan was left deciding whether to intervene with no
// evidence about whether waiting had been working.
//
// The shape mirrors #2211's empty-run streak deliberately, down to the threshold: these are the two
// halves of the same judgment (it read nothing / it could not be read), and they escalate on one clock.
@MainActor
@Suite("A source that keeps failing to read says how long it has been going on (#1759)")
struct RepeatedReadFailureTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // Watched for months and read successfully until recently, which is the case this is about: a source
    // with a history, not a brand-new one (that state is #2231's, and it says more than this line could).
    private func source(lastSucceeded: Date? = nil) -> WatchedSource {
        let s = WatchedSource(sourceId: "org", orgName: "Org",
                              listingsURL: "https://org.example/events", kind: .html,
                              addedAt: now.addingTimeInterval(-120 * 86_400))
        s.lastSucceededAt = lastSucceeded ?? now.addingTimeInterval(-12 * 86_400)
        s.successfulCheckCount = 20
        return s
    }

    private func results(_ verdict: PageVerdict, events: [ScoutExtractEvent] = []) -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                            results: [ScoutExtractResult(sourceId: "org", verdict: verdict,
                                                         events: events, note: nil)])
    }

    private let aRealShow = ScoutExtractEvent(title: "A Concert", presenter: "A Concert",
                                              venue: "Merkin Hall", performanceDate: "2099-09-19",
                                              sourceUrl: "https://org.example/a")

    @discardableResult
    private func ingest(_ r: ScoutExtractResults, into ctx: ModelContext) -> ScoutService.Outcome {
        ScoutExtractIngest.ingest(r, clients: [], history: [], blocked: .empty,
                                  today: ScoutTestClock.beforeAllFixtures, now: now, into: ctx)
    }

    // MARK: - The memory the row never had

    // The whole of the defect: run ten was indistinguishable from run one.
    @Test func consecutiveRunsThatFailedToReadAreCounted() throws {
        let ctx = try context()
        let s = source()
        ctx.insert(s)
        try ctx.save()

        for run in 1...10 {
            ingest(results(.notRead), into: ctx)
            #expect(s.failedReadStreak == run)
        }
    }

    // The other half, and the one that decides whether the warning can ever be trusted: a source that
    // reads again is not one run away from the warning, it is back at nothing.
    @Test func aRunThatActuallyReadThePageClearsTheStreak() throws {
        let ctx = try context()
        let s = source()
        ctx.insert(s)
        try ctx.save()

        for _ in 1...9 { ingest(results(.notRead), into: ctx) }
        #expect(s.failedReadStreak == 9)
        #expect(s.repeatedFailureNote(now: now) != nil)

        ingest(results(.upcomingListings, events: [aRealShow]), into: ctx)

        #expect(s.failedReadStreak == 0)
        #expect(s.repeatedFailureNote(now: now) == nil)

        // And it stays back at nothing: one later failure must not re-arm a warning built on nine runs
        // that have been answered. (The row is still work while it carries that fresh failure, which is
        // the failing grade's job and predates this; what must not come back is the history.)
        ingest(results(.notRead), into: ctx)
        #expect(s.failedReadStreak == 1)
        #expect(s.repeatedFailureNote(now: now) == nil)
        #expect(!SourceAttention.hasFailedToReadRepeatedly(s))
    }

    // A page read in part is a page that was read: real shows came back from it and were ingested, so it
    // is not a run that came away with nothing.
    @Test func aPartlyReadPageClearsTheStreakToo() throws {
        let ctx = try context()
        let s = source()
        s.pendingPageMonths = ["2026-08", "2026-09"]        // the app stitched two months in
        ctx.insert(s)
        try ctx.save()

        for _ in 1...4 { ingest(results(.notRead), into: ctx) }
        #expect(s.failedReadStreak == 4)

        s.pendingPageMonths = ["2026-08", "2026-09"]
        ingest(results(.upcomingListings, events: [aRealShow]), into: ctx)   // covers one of the two

        #expect(s.failedReadStreak == 0)
    }

    // #1027: Dan confirmed this page is the right one and merely quiet. The read worked; there is no
    // failure to count and no history left to complain about.
    @Test func aConfirmedEmptyReadClearsTheStreak() throws {
        let ctx = try context()
        let s = source()
        s.confirmedEmptyHash = "H_empty"
        s.pendingContentHash = "H_empty"
        ctx.insert(s)
        try ctx.save()

        s.failedReadStreak = 6

        ingest(results(.noDatedContent), into: ctx)

        #expect(s.failedReadStreak == 0)
    }

    // Dan's own answers about the page clear it too, and they are the whole of the rest of the class: the
    // only other places that clear `lastFailure` because the page is understood to be fine. A count that
    // survived the one action the line asks for would keep nagging about a question he has answered.
    @Test func dansOwnAnswersAboutThePageClearTheStreak() throws {
        let ctx = try context()
        let confirmed = source()
        confirmed.pendingContentHash = "H_empty"
        let revived = source()
        revived.sourceId = "revived"                    // set before insert: the id is unique
        revived.isActive = false
        revived.inactiveReason = .removedByDan
        ctx.insert(confirmed)
        ctx.insert(revived)
        try ctx.save()
        confirmed.failedReadStreak = 5
        revived.failedReadStreak = 5

        WatchlistEditing.confirmEmpty(confirmed, in: ctx)
        WatchlistEditing.resumeWatching(revived, in: ctx)

        #expect(confirmed.failedReadStreak == 0)
        // #1673: nothing checked this page for the whole time it sat stopped, so a run of failures from
        // before the stop may not present itself as this source's state now. It re-earns the sentence
        // within three runs if it is still broken.
        #expect(revived.failedReadStreak == 0)
    }

    // MARK: - The sibling failure paths (the class, not the instance)

    // A fetch that never landed the page is a run that came away without reading it, exactly as a read
    // that came back unusable is. Counting only the second would leave a source that has been 404ing for
    // a fortnight saying the unqualified line forever.
    @Test func aFetchThatNeverLandedThePageCountsToo() {
        let s = source()

        _ = SourceCheck.decide(source: s, result: .failure(.unreachable), depth: .watchOnly, now: now)
        _ = SourceCheck.decide(source: s, result: .failure(.http(404)), depth: .watchOnly, now: now)

        #expect(s.failedReadStreak == 2)
        #expect(s.health == .failing)
    }

    // The trap this counter exists to survive. The free daily run FETCHES every source and reads none of
    // them, and a successful fetch clears `health` and `lastFailure` (SourceCheck.decide). So the row's
    // failing display is wiped every morning while the page still cannot be read, and a streak reset by a
    // mere fetch would be reset every morning too: it would never reach any threshold, on precisely the
    // source it was built for.
    @Test func aFetchThatSucceedsButReadsNothingDoesNotClearTheStreak() {
        let s = source()
        for _ in 1...5 { s.recordFailedRead(.verdict(.noDatedContent), now: now) }

        let page = FetchedPage(normalizedHTML: "<html></html>",
                               finalURL: "https://org.example/events", contentHash: "H")
        _ = SourceCheck.decide(source: s, result: .success(page), depth: .watchOnly, now: now)

        #expect(s.health == .ok)                 // the fetch really did work, and the row says so
        #expect(s.lastFailure == nil)
        #expect(s.failedReadStreak == 5)         // but nothing was READ, so the history stands
    }

    // Every path that records a failed check goes through the one recorder, so a fifth one cannot be
    // added that silently keeps no history. Derived from the code rather than a remembered list (L96):
    // the fingerprint is the assignment itself, in the files that make it.
    @Test func noFailurePathWritesTheFailingStateBehindTheRecordersBack() {
        for file in ["Overture/Integration/ScoutExtractIngest.swift",
                     "Overture/Integration/ScoutService.swift",
                     "Overture/Domain/SourceSchedule.swift"] {
            let text = SourceGuardHelper.source(file)
            #expect(!text.isEmpty, "\(file) could not be read, so this guard measures nothing")
            let offenders = SwiftSource.scannableLines(in: text)
                .filter { $0.code.contains("health = .failing") }
            #expect(offenders.isEmpty, """
                \(file) line \(offenders.first?.line ?? 0): a failed check is recorded by hand here. \
                Call WatchedSource.recordFailedRead so the run counts toward the streak the row reads from.
                """)
        }
    }

    // MARK: - When it becomes work

    // Once is not work. The scout summary already says so on the day it happens, and a run that died
    // before reaching a page really is answered by the next scout. Escalating on the first is the
    // cry-wolf failure #1428 and #1498 both pulled back from.
    @Test func oneFailedRunIsNotYetWork() {
        let s = source()
        s.recordFailedRead(.verdict(.notRead), now: now)

        #expect(s.repeatedFailureNote(now: now) == nil)
        #expect(!SourceAttention.hasFailedToReadRepeatedly(s))
    }

    // Three is, and three is what both neighbouring judgments use (#2211's empty streak and
    // FeedReconcile.selfHealThreshold), so every part of source health escalates on one clock.
    @Test func threeFailedRunsInARowIsWork() {
        let s = source()
        for _ in 1...3 { s.recordFailedRead(.verdict(.noDatedContent), now: now) }

        #expect(SourceAttention.failedReadStreakThreshold == 3)
        #expect(SourceAttention.failedReadStreakThreshold == SourceAttention.emptyStreakThreshold)
        #expect(SourceAttention.hasFailedToReadRepeatedly(s))
        #expect(SourceAttention.needsALook(s, now: now))
        #expect(SourceAttention.split([s], now: now).needsALook.count == 1)
    }

    // The case the existing conditions cannot see, which is the reason this earns a place in the section
    // rather than riding on the failing grade: the daily fetch keeps succeeding, so the row grades as
    // perfectly healthy while every read of it fails.
    @Test func aSourceWhosePageFetchesFineAndNeverReadsIsStillWork() {
        let s = source()
        for _ in 1...4 { s.recordFailedRead(.verdict(.unreadable), now: now) }
        let page = FetchedPage(normalizedHTML: "<html></html>",
                               finalURL: "https://org.example/events", contentHash: "H")
        _ = SourceCheck.decide(source: s, result: .success(page), depth: .watchOnly, now: now)

        #expect(SourceGrade(s) != .failing)          // nothing else in the sheet would flag it
        #expect(SourceAttention.needsALook(s, now: now))
    }

    // Consent outranks it, exactly as it outranks every other condition (#800). An org that asked to be
    // left alone must never reappear as work, whatever its page is doing.
    @Test func aSourceDanStoppedIsNeverWorkHoweverBroken() {
        let s = source()
        for _ in 1...9 { s.recordFailedRead(.verdict(.unreadable), now: now) }
        s.isActive = false
        s.inactiveReason = .orgRefusal

        #expect(!SourceAttention.needsALook(s, now: now))
        #expect(s.repeatedFailureNote(now: now) == nil)
    }

    // MARK: - What the row says

    // The two facts the unqualified promise could not carry: which run this is, and how long it has been
    // since anything was read here.
    @Test func theRowSaysHowManyRunsAndHowLongSinceTheLastRead() {
        let line = SourceAttention.repeatedFailureLine(runs: 10,
                                                       lastSucceededAt: now.addingTimeInterval(-12 * 86_400),
                                                       now: now)
        #expect(line.contains("10 runs"))
        #expect(line.contains("12 days"))
    }

    // A row that has never been read does not invent a date, exactly as the gone-quiet line beside it
    // leaves its own clause out rather than guessing.
    @Test func aRowWithNoRecordedReadSaysOnlyWhatItKnows() {
        let line = SourceAttention.repeatedFailureLine(runs: 4, lastSucceededAt: nil, now: now)
        #expect(line.contains("4 runs"))
        #expect(!line.contains("days"))
    }

    @Test func oneRunIsNotSaidAsRuns() {
        #expect(SourceAttention.repeatedFailureLine(runs: 1, lastSucceededAt: nil, now: now)
                .contains("1 run in a row"))
    }

    // #843: a source that has NEVER read its calendar already carries a stronger sentence saying so and
    // ending in the same instruction. Two gold lines a line apart, both saying to check the link, is the
    // duplicated-copy defect this sheet keeps being filed for, so this one steps aside for it.
    @Test func aSourceThatHasNeverReadAtAllKeepsItsOwnSentence() {
        let s = source(lastSucceeded: nil)
        s.lastSucceededAt = nil
        s.successfulCheckCount = 0
        for _ in 1...5 { s.recordFailedRead(.verdict(.unreadable), now: now) }

        #expect(s.neverReadNote(now: now) != nil)
        #expect(s.repeatedFailureNote(now: now) == nil)
    }

    // The note is a fact about the row, decided beside the data and never in the view (#863/#885), and it
    // is read off the SAME rule that puts the row in the attention section, so the sentence and the badge
    // cannot disagree about which sources they mean.
    @Test func theNoteAndTheBadgeAgreeAboutWhichSourcesTheyMean() {
        let s = source()
        for run in 1...6 {
            s.recordFailedRead(.verdict(.notRead), now: now)
            #expect((s.repeatedFailureNote(now: now) != nil)
                    == SourceAttention.hasFailedToReadRepeatedly(s),
                    "run \(run): the sentence and the rule disagree")
        }
    }
}

// A guard and its wiring are two claims (#887): the row has to draw the sentence, or every test above
// passes while Dan sees nothing.
@Suite("The Sources row draws the repeated-failure sentence (#1759)")
struct RepeatedReadFailureRowWiringTests {
    private var sourcesView: String { SourceGuardHelper.source("Overture/UI/SourcesView.swift") }

    @Test func theRowRendersTheNote() {
        #expect(!sourcesView.isEmpty)
        #expect(sourcesView.contains("if let repeatedFailure = source.repeatedFailureNote()"))
    }
}
