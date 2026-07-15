import Testing
import Foundation
import SwiftData
@testable import Overture

// #840/#841/#842: what Dan saw walking the Sources sheet.
//
// Three defects, one cause: the sheet prints every fact it holds, whether or not that fact tells him
// anything. A row said "Checked 8 hours ago" and then "Read 8 hours ago", which is one event described
// twice. The header said "The calendars Overture re-checks on every scout" and the Watching section
// said "Checked on every scout", five lines apart. And the only escape hatch in the entire feature,
// "Stop watching", was styled exactly like the metadata above it, so it read as a fourth statement of
// fact rather than as something he could do.
//
// Copy that repeats itself trains him to skim, and the one line that matters here (a calendar whose
// listings changed and that NOBODY has read) is the line that must never be skimmed past.
@MainActor
@Suite("The Sources sheet says each thing once (#840/#841/#842)")
struct SourcesSheetSaysEachThingOnceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func hoursAgo(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 3600) }

    private func source(checked: Date? = nil, succeeded: Date? = nil,
                        unread: Bool = false, kind: SourceKind = .html) -> WatchedSource {
        let s = WatchedSource(sourceId: "org", orgName: "Org",
                              listingsURL: "https://org.example/events", kind: kind)
        s.lastCheckedAt = checked
        s.lastSucceededAt = succeeded
        s.hasUnreadChanges = unread
        return s
    }

    // MARK: - #840: the read line earns its place, or it does not appear

    // Dan's Carnegie row. A native feed's shows ARRIVE with the check, so a successful run stamps both
    // timestamps from the same instant. "Read 8 hours ago" is then the same event as "Checked 8 hours
    // ago", worded differently. Note this is decided by the FACTS (one instant, one event), not by the
    // source's kind: it holds for any source read in the same run that checked it.
    @Test func aReadThatHappenedInTheSameRunAsTheCheckIsNotSaidTwice() {
        let carnegie = source(checked: hoursAgo(8), succeeded: hoursAgo(8), kind: .algolia)

        #expect(SourceReadState.of(carnegie).isWorthShowing(lastCheckedAt: carnegie.lastCheckedAt) == false)
    }

    // The whole reason the line exists (#803). The free daily run fetches and hashes and reads nothing,
    // so this source has been "checked" for weeks while nobody has looked at what is on it. That is a
    // leak, and it must be loud.
    @Test func aCalendarNobodyHasReadStillSaysSo() {
        let neglected = source(checked: hoursAgo(1), succeeded: nil)

        let state = SourceReadState.of(neglected)
        #expect(state.isWorthShowing(lastCheckedAt: neglected.lastCheckedAt))
        #expect(state.label(now: now) == "Not read yet")
    }

    // The one line that must survive at all costs: its listings CHANGED and no scout has read them.
    // Shown even when the timestamps happen to coincide, because this is not a fact about time.
    @Test func newListingsNobodyHasReadAreAlwaysSaidLoudly() {
        let waiting = source(checked: hoursAgo(8), succeeded: hoursAgo(8), unread: true)

        let state = SourceReadState.of(waiting)
        #expect(state.isWorthShowing(lastCheckedAt: waiting.lastCheckedAt))
        #expect(state.needsAScout)
    }

    // Checks have happened SINCE the last read, which is exactly the gap #803 exists to show: the daily
    // run keeps checking, and the listings have not been looked at since Tuesday.
    @Test func aReadThatHasFallenBehindTheChecksIsWorthSaying() {
        let lagging = source(checked: hoursAgo(1), succeeded: hoursAgo(72))

        #expect(SourceReadState.of(lagging).isWorthShowing(lastCheckedAt: lagging.lastCheckedAt))
    }

    // Dan's Bargemusic row: "Never checked" already tells him nobody has read it. "Not read yet"
    // underneath is a second way of saying nothing has happened.
    @Test func aSourceNothingHasHappenedToSaysSoOnce() {
        let fresh = source(checked: nil, succeeded: nil)

        #expect(SourceReadState.of(fresh).isWorthShowing(lastCheckedAt: fresh.lastCheckedAt) == false)
    }

    // #843: a run that died before opening the page (`notRead`) leaves BOTH the unread-changes line and a
    // failure line that says "it has not been read. The next scout will try it again." Shown together they
    // say the one thing, so the read-state line steps aside and lets the failure line (which also says
    // WHY) carry it. The row is not left silent: the failure line is still shown.
    @Test func aPageAScoutNeverReachedDoesNotSayNotReadTwice() {
        let waiting = source(checked: hoursAgo(1), succeeded: nil, unread: true)
        waiting.lastFailure = .verdict(.notRead)

        let state = SourceReadState.of(waiting)
        #expect(state.isWorthShowing(lastCheckedAt: waiting.lastCheckedAt, failure: waiting.lastFailure) == false)
    }

    // Only `notRead` collapses. Every other failure names a distinct reason (a JavaScript page, an empty
    // page, an HTTP error), so the unread-changes line still adds something and stays.
    @Test func anotherFailureDoesNotSuppressTheUnreadChangesLine() {
        let waiting = source(checked: hoursAgo(1), succeeded: hoursAgo(72), unread: true)
        waiting.lastFailure = .verdict(.unreadable)

        let state = SourceReadState.of(waiting)
        #expect(state.isWorthShowing(lastCheckedAt: waiting.lastCheckedAt, failure: waiting.lastFailure))
    }

    // The guard and its wiring are two claims (#887): the rule above is only true on screen if the sheet
    // actually hands the failure to it. Without the argument, `notRead` defaults away and the line comes
    // back, with every domain test still green.
    @Test func theSheetHandsTheFailureToTheReadStateDecision() {
        let sourcesView = SourceGuardHelper.source("Overture/UI/SourcesView.swift")
        #expect(sourcesView.contains("isWorthShowing(lastCheckedAt: source.lastCheckedAt, failure: source.lastFailure)"))
    }

    // MARK: - #841: the header and the section do not say the same thing

    // "Watching" is the default state the sheet's own subtitle already describes, so its explanation was
    // that subtitle restated five lines lower. #843: "Not checked yet" is the same case, its heading says
    // the whole of it, and its old line ("Added, but no scout has reached them yet.") only said it again.
    // The other grades keep theirs: those are the ones where a wrong reading costs something, above all
    // "Stopped at their request", which must never read as "broken".
    @Test func theWatchingSectionDoesNotRestateTheSheetsSubtitle() {
        let selfEvident: Set<SourceGrade> = [.watching, .neverChecked]
        for grade in selfEvident {
            #expect(grade.explanation == nil,
                    "\(grade)'s heading already says it; a second line only restates it")
        }
        for grade in SourceGrade.allCases where !selfEvident.contains(grade) {
            #expect(grade.explanation?.isEmpty == false,
                    "\(grade) still needs its own line: its meaning is not obvious from the heading alone")
        }
        #expect(SourceGrade.stoppedAtTheirRequest.explanation?.contains("asked not to be contacted") == true)
    }
}

// #842: "Stop watching" is the ONLY way a source leaves the watchlist, and #802's design rests on it: a
// failing source never auto-deactivates, so Dan removing it himself is the deliberate escape hatch. An
// escape hatch he cannot see is not one, and styled as a plain 11pt line under three other 11pt lines,
// he could not.
//
// A guard on the view's source, matching this project's convention for a change with no behavioural
// surface of its own.
@Suite("Stop watching reads as an action (#842)")
struct StopWatchingAffordanceGuardTests {
    private var sourcesView: String { SourceGuardHelper.source("Overture/UI/SourcesView.swift") }

    @Test func stopWatchingCarriesTheAppsSecondaryActionAffordance() {
        guard let range = sourcesView.range(of: "Stop watching") else {
            Issue.record("the Stop watching button is gone")
            return
        }
        let button = sourcesView[range.lowerBound...].prefix(500)

        // The same bordered-capsule idiom the queue's own secondary action (Dismiss) uses, rather than a
        // fourth line of plain text. One visual language for "you can do this".
        #expect(button.contains("Capsule"), "it must be shaped like an action, not like a label")
        #expect(button.contains("strokeBorder"), "a border is what separates an action from a statement")
    }

    // It must not read as a failure, and it must not shout: stopping a source is Dan's ordinary,
    // reversible housekeeping, not an alarm.
    @Test func itIsNotStyledAsAnError() {
        guard let range = sourcesView.range(of: "Stop watching") else {
            Issue.record("the Stop watching button is gone")
            return
        }
        #expect(!sourcesView[range.lowerBound...].prefix(500).contains("OVColor.rust"))
    }
}
