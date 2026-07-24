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

    // A transient fetch failure CAN be cleared by another scout, so "Run a scout to read them" is honest
    // advice there and the line stays.
    @Test func aTransientFetchFailureDoesNotSuppressTheUnreadChangesLine() {
        let waiting = source(checked: hoursAgo(1), succeeded: hoursAgo(72), unread: true)
        waiting.lastFailure = .fetch(.unreachable)

        let state = SourceReadState.of(waiting)
        #expect(state.isWorthShowing(lastCheckedAt: waiting.lastCheckedAt, failure: waiting.lastFailure))
    }

    // #958: a JavaScript-drawn page (`unreadable`) reads the same empty shell on every plain re-fetch, so
    // "Run a scout to read them" promises a re-run will fix what a re-run cannot. The line steps aside for
    // the failure line ("drawn by JavaScript, nothing to read"), which is the truth.
    @Test func aJavaScriptDrawnPageDoesNotSayToRunAScoutThatCannotHelp() {
        let waiting = source(checked: hoursAgo(1), succeeded: hoursAgo(72), unread: true)
        waiting.lastFailure = .verdict(.unreadable)

        let state = SourceReadState.of(waiting)
        #expect(state.isWorthShowing(lastCheckedAt: waiting.lastCheckedAt, failure: waiting.lastFailure) == false)
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

    // #1426: anchored on the constant rather than the literal. Both surfaces that offer this action now
    // take its words from SourceFixConfirmCopy.stopWatchingTitle, so the sheet no longer spells them out.
    @Test func stopWatchingCarriesTheAppsSecondaryActionAffordance() {
        guard let range = sourcesView.range(of: "stopWatchingTitle") else {
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
        guard let range = sourcesView.range(of: "stopWatchingTitle") else {
            Issue.record("the Stop watching button is gone")
            return
        }
        #expect(!sourcesView[range.lowerBound...].prefix(500).contains("OVColor.rust"))
    }
}

// #1185: a single-venue feed (VenueTix) carries no city in its own data, so until Dan supplies its
// address its shows resolve as location-unknown and never place in his area. #1175 gave him the control
// to add it, but nothing prompted him while a watched calendar sat unplaced, so the feature relied on him
// remembering it exists. When such a source has ACTUALLY surfaced shows and still has no address, the row
// says the concrete consequence ("its shows are not placed in your area") rather than the setup prompt.
//
// The two are one line that varies, not two lines, so the row never states the missing address twice
// (#843): the setup prompt before any shows exist, the consequence once they do.
@Suite("A single-venue feed with no address nudges once it has shows (#1185)")
struct SingleVenueFeedAddressNudgeTests {

    // Before any shows have surfaced, the row shows the neutral setup prompt: there is no problem yet, only
    // a thing worth doing.
    @Test func withNoShowsYetItIsTheNeutralSetupPrompt() {
        #expect(VenueLocationCopy.promptWhenUnset(hasSurfacedShows: false)
                == "Add this venue's address so its shows count as in your area.")
    }

    // Once shows exist, they are actively unplaced, so the row states that consequence and points at the
    // same Add address control.
    @Test func withShowsSurfacedItStatesTheConsequence() {
        #expect(VenueLocationCopy.promptWhenUnset(hasSurfacedShows: true)
                == "No address yet, so its shows are not placed in your area.")
    }

    // The guard and its wiring are two claims (#887): the varying prompt is only true on screen if the row
    // actually hands it whether shows have surfaced. Without the argument the nudge never appears.
    @Test func theRowFeedsWhetherShowsHaveSurfacedIntoThePrompt() {
        let sourcesView = SourceGuardHelper.source("Overture/UI/SourcesView.swift")
        #expect(sourcesView.contains("VenueLocationCopy.promptWhenUnset(hasSurfacedShows:"))
    }
}

// #1177: the address editor is offered on EVERY active, editable (non-algolia) source row, not only on a
// failed one. Before this, "Fix the address" appeared only inside the failure block, so The Cell (which
// reads fine but is empty, no failure) could never be re-pointed from the sheet. The safe re-point logic
// (WatchlistEditing.editURL) and the editor (SourceFixConfirmActions) already existed; this wires them in
// without a second edit path.
@MainActor
@Suite("The address editor is offered on every editable source row (#1177)")
struct SourceAddressEditorEverywhereTests {

    // With no failure the editor still offers Fix (a wrong address is exactly what a persistently empty
    // but readable source might have) and never offers Confirm (there is no empty-page failure to confirm).
    @Test func aHealthySourceOffersFixButNotConfirm() {
        #expect(SourceFixConfirmActions.offersFix(nil, kind: .html))
        #expect(!SourceFixConfirmActions.offersConfirm(nil, kind: .html))
    }

    // A real failure keeps deciding exactly as before: the two predicates on the failure itself win.
    @Test func aFailingSourceDefersToTheFailuresOwnPredicates() {
        #expect(SourceFixConfirmActions.offersConfirm(.verdict(.noDatedContent), kind: .html))
        #expect(SourceFixConfirmActions.offersFix(.verdict(.noDatedContent), kind: .html))
        #expect(!SourceFixConfirmActions.offersFix(.verdict(.notRead), kind: .html))          // self-heals; no address fix
        #expect(!SourceFixConfirmActions.offersConfirm(.fetch(.http(404)), kind: .html))
    }

    // The wiring claim: the sheet renders the editor on every active row regardless of failure, passing
    // the live (optional) failure. A guard, because a view has no behavioural surface a domain test can
    // reach (#887). #1450: it is no longer the sheet that excludes Carnegie's feed; the component decides
    // what a source's kind allows, and draws nothing when that is nothing.
    @Test func theSheetRendersTheEditorOutsideTheFailureBlock() {
        let sourcesView = SourceGuardHelper.source("Overture/UI/SourcesView.swift")
        #expect(sourcesView.contains("SourceFixConfirmActions(source: source, failure: source.lastFailure)"))
    }
}
