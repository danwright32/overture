import Testing
import Foundation

// #2211: the silently-empty warning was computed per run against the source's baseline, so it carried no
// memory. A calendar dead for a month and one having a genuinely quiet week produced the identical
// sentence, every run, forever, which meant the one signal Dan gets about a broken page could neither
// escalate nor resolve. He was being asked to judge exactly the thing it could not tell him: whether this
// is the first occurrence or the fifth.
//
// Observed 2026-08-06 on The Players Theatre, whose last saved page (26 July) showed a full OvationTix
// listing running well past today, so the empty result was unlikely to be a quiet season.
@MainActor
@Suite("A source that comes back empty run after run (#2211)")
struct EmptyRunStreakTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func source(baseline: Int = 153) -> WatchedSource {
        let s = WatchedSource(sourceId: "players", orgName: "The Players Theatre",
                              listingsURL: "https://example.test/show-schedule.html", kind: .html,
                              addedAt: now.addingTimeInterval(-90 * 86_400))
        s.baselineFeedCount = baseline
        return s
    }

    private func read(_ s: WatchedSource, events: Int, at: Date) {
        s.recordSuccessfulRead(events: events, unreadable: 0, placed: 0,
                               feedHealth: .init(baseline: s.baselineFeedCount,
                                                 degradedStreak: s.degradedStreak,
                                                 lastDegradedCount: s.lastDegradedCount),
                               now: at)
    }

    // The memory the warning never had.
    @Test func consecutiveEmptyRunsAreCounted() {
        let s = source()
        for run in 1...4 {
            read(s, events: 0, at: now.addingTimeInterval(Double(run) * 86_400))
            #expect(s.emptyStreak == run)
        }
    }

    // And it resolves, which is the other half: a source that starts listing again stops being work
    // without anybody clearing anything by hand.
    @Test func aRunThatListsSomethingClearsTheStreak() {
        let s = source()
        read(s, events: 0, at: now)
        read(s, events: 0, at: now.addingTimeInterval(86_400))
        #expect(s.emptyStreak == 2)

        read(s, events: 12, at: now.addingTimeInterval(2 * 86_400))

        #expect(s.emptyStreak == 0)
        #expect(s.lastNonEmptyAt == now.addingTimeInterval(2 * 86_400))
    }

    // A brand-new source has nothing unusual about an empty first check, which is the rule
    // `Outcome.silentlyEmptySources` already applies to the warning. Asked here of the row, so the two
    // cannot disagree about which empties count (L16).
    @Test func aSourceWithNoBaselineIsNotCountedAsGoingQuiet() {
        let fresh = source(baseline: 0)

        read(fresh, events: 0, at: now)

        #expect(fresh.emptyStreak == 0)
        #expect(!SourceAttention.hasGoneQuiet(fresh))
    }

    // Once is a note, not work: the scout summary already says so on the day, and an established calendar
    // genuinely does have quiet days. Escalating on the first would be the cry-wolf failure #1428 and
    // #1498 both pulled back from.
    @Test func oneEmptyRunIsNotYetWork() {
        let s = source()
        read(s, events: 0, at: now)

        #expect(!SourceAttention.needsALook(s, now: now))
        #expect(s.goneQuietNote(now: now) == nil)
    }

    // Three is, and three is the number `FeedReconcile.selfHealThreshold` uses for the mirror-image
    // judgment, so the two halves of feed health escalate on the same clock.
    @Test func threeEmptyRunsIsWork() {
        let s = source()
        for run in 1...3 { read(s, events: 0, at: now.addingTimeInterval(Double(run) * 86_400)) }

        #expect(SourceAttention.emptyStreakThreshold == 3)
        #expect(SourceAttention.needsALook(s, now: now))
        #expect(SourceAttention.split([s], now: now).needsALook.count == 1)
    }

    // Consent outranks it, exactly as it outranks every other condition (#800).
    @Test func aSourceDanStoppedIsNeverWorkHoweverQuiet() {
        let s = source()
        for run in 1...9 { read(s, events: 0, at: now.addingTimeInterval(Double(run) * 86_400)) }
        s.isActive = false
        s.inactiveReason = .orgRefusal

        #expect(!SourceAttention.needsALook(s, now: now))
        #expect(s.goneQuietNote(now: now) == nil)
    }

    // The sentence says WHICH run this is and WHEN it last listed anything, which is the whole of what
    // the per-run warning could not say.
    @Test func theRowSaysWhichRunThisIsAndWhenItLastListedAnything() {
        let line = SourceAttention.goneQuietLine(runs: 5,
                                                 lastNonEmptyAt: now.addingTimeInterval(-31 * 86_400),
                                                 now: now)
        #expect(line.contains("5 runs"))
        #expect(line.contains("31 days"))
    }

    // A row that predates this recording genuinely does not know when it last listed anything, so it
    // leaves the clause out rather than inventing a date.
    @Test func aRowWithNoRecordedLastListingSaysOnlyWhatItKnows() {
        let line = SourceAttention.goneQuietLine(runs: 3, lastNonEmptyAt: nil, now: now)
        #expect(line.contains("3 runs"))
        #expect(!line.contains("listed a show for"))
    }

    @Test func oneRunIsNotSaidAsRuns() {
        #expect(SourceAttention.goneQuietLine(runs: 1, lastNonEmptyAt: nil, now: now).contains("1 run in a row"))
    }

    // The badge's tooltip names the new reason, or it would count a state it never explains.
    @Test func theBadgeHelpNamesTheNewReason() {
        #expect(SourceAttention.help(count: 2).contains("empty run after run"))
    }
}

// A guard and its wiring are two claims (#887): the row has to draw the sentence.
@Suite("The Sources row draws the gone-quiet sentence (#2211)")
struct GoneQuietRowWiringTests {
    private var sourcesView: String { SourceGuardHelper.source("Overture/UI/SourcesView.swift") }

    @Test func theRowRendersTheNote() {
        #expect(!sourcesView.isEmpty)
        #expect(sourcesView.contains("if let goneQuiet = source.goneQuietNote()"))
    }
}
