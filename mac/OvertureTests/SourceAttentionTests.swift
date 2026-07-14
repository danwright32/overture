import Testing
import Foundation
import SwiftData
@testable import Overture

// #805: the failure mode with no visible symptom.
//
// A source that 404s is loud. A source that half works is silent: the fetch succeeds, the verdict is
// upcomingListings, health stays .ok, and it quietly returns 8 of its 12 shows forever. #917 gave that
// state a sentence in the Sources sheet, and a sentence in a sheet Dan has no reason to open is not a
// symptom. It is a fact he will never see, which is what this issue said the problem was.
//
// So the toolbar button carries the count, and the rule behind it is written ONCE. The number on the
// button Dan clicks and the rows he lands on must be the same number by construction, not by
// coincidence: a badge that disagrees with the list behind it is the #863 defect, and DueWork exists
// because that same mistake was made with the Due pill.
@Suite("A source that needs a look says so on the toolbar (#805)")
struct SourceAttentionTests {

    private func source(health: SourceHealth = .ok, readable: Int = 30, unreadable: Int = 0,
                        baseline: Int = 30, isActive: Bool = true,
                        reason: SourceInactiveReason? = nil) -> WatchedSource {
        let s = WatchedSource(sourceId: "kaufman", orgName: "Kaufman Music Center",
                              listingsURL: "https://kaufman.example/calendar", kind: .html)
        s.health = health
        s.lastReadableCount = readable
        s.lastUnreadableCount = unreadable
        s.baselineFeedCount = baseline
        s.successfulCheckCount = WatchedSource.warmupRuns
        s.isActive = isActive
        s.inactiveReason = reason
        return s
    }

    // The steady state. A source doing its job asks for nothing, and the toolbar stays quiet: a badge
    // that is always lit is furniture Dan learns to skim past.
    @Test func aHealthySourceAtItsUsualSizeNeedsNothing() {
        #expect(SourceAttention.needsALook(source()) == false)
    }

    // Loud already, but only inside the sheet. It belongs on the count too.
    @Test func aFailingSourceNeedsALook() {
        #expect(SourceAttention.needsALook(source(health: .failing)))
    }

    // THE case this issue is about. Nothing failed. The page was read, the verdict was healthy, and it
    // returned 16 of the 30 shows this source usually lists. Overture will not mark anything from it as
    // gone until that holds (#897), and Dan is now told without having to go looking.
    @Test func aSourceThatQuietlyCameBackHalfSizeNeedsALook() {
        #expect(SourceAttention.needsALook(source(readable: 16, baseline: 30)))
    }

    // The other way a source forfeits its cancelling (#887): it read the page fine and could not reach
    // the detail pages behind it.
    @Test func aSourceWhoseDetailPagesWentUnreadNeedsALook() {
        #expect(SourceAttention.needsALook(source(readable: 20, unreadable: 10, baseline: 30)))
    }

    // A calendar that lost a show or two is normal and still cancels. It is not an alarm.
    @Test func aNormalDeclineIsNotAnAlarm() {
        #expect(SourceAttention.needsALook(source(readable: 29, baseline: 30)) == false)
    }

    // A growing calendar is never suspicious.
    @Test func aGrowingSourceIsNotAnAlarm() {
        #expect(SourceAttention.needsALook(source(readable: 45, baseline: 30)) == false)
    }

    // An empty feed is a quiet off-season or a broken fetch, and health already speaks for the broken
    // case. Counting it here would light the badge on every source all summer, which is exactly the
    // noise #805 warned this must not become.
    @Test func aSourceWithNothingUpcomingIsNotAnAlarm() {
        #expect(SourceAttention.needsALook(source(readable: 0, baseline: 30)) == false)
    }

    // A source that is NOT WATCHED can never nag. An org that asked Dan to stop must never appear as work
    // he owes anyone, whatever its scraper is doing: that is the one mistake in this feature that cannot
    // be taken back (#800).
    @Test func anOrgThatRefusedDanNeverNagsHimHoweverBrokenItIs() {
        let refused = source(health: .failing, readable: 2, baseline: 30,
                             isActive: false, reason: .orgRefusal)

        #expect(SourceAttention.needsALook(refused) == false)
    }

    @Test func aSourceDanStoppedWatchingNeverNagsHim() {
        let removed = source(health: .failing, isActive: false, reason: .removedByDan)

        #expect(SourceAttention.needsALook(removed) == false)
    }

    // A brand new source has no history to be judged against and is not an alarm on its first sight.
    @Test func aSourceNotCheckedYetIsNotAnAlarm() {
        #expect(SourceAttention.needsALook(source(health: .neverChecked, readable: 0, baseline: 0)) == false)
    }

    // The pill's number is a promise about rows (#863). It counts sources, and only the ones that need
    // Dan.
    @Test func theCountIsExactlyTheSourcesThatNeedHim() {
        let sources = [source(), source(health: .failing), source(readable: 16, baseline: 30),
                       source(isActive: false, reason: .orgRefusal)]

        #expect(SourceAttention.count(sources) == 2)
    }

    // A zero never sits on the masthead pretending to be work (#885's rule for the Due pill, and the same
    // rule here, because the toolbar is one surface and must read as one).
    @Test func aQuietToolbarSaysNothingButItsName() {
        #expect(SourceAttention.badgeTitle(count: 0) == "Sources")
        #expect(SourceAttention.badgeTitle(count: 1) == "Sources (1)")
        #expect(SourceAttention.badgeTitle(count: 2) == "Sources (2)")
    }

    // Words, never color alone (#800). The gold tint is what catches Dan's eye across the room; the
    // sentence is what tells him what it means, and it must say what he will find and why it matters.
    @Test func theTooltipSaysWhatIsWrongAndNotJustThatSomethingIs() {
        #expect(SourceAttention.help(count: 0)
                == "The calendars Overture re-checks on every scout, and how each one is doing")

        let one = SourceAttention.help(count: 1)
        #expect(one.contains("1 source"))
        #expect(one.contains("can't mark shows as gone"))
        #expect(SourceAttention.help(count: 3).contains("3 sources"))
    }

    // THE invariant, and the reason this rule is not written twice. The badge counts a source exactly when
    // the sheet Dan lands on shows him something is wrong with it: it is failing, or it says out loud that
    // it cannot mark shows gone. If these two ever drift, the toolbar sends him to a sheet where he can see
    // nothing wrong, or (far worse) stays quiet about a source that has silently stopped working.
    @Test func theBadgeAndTheSheetNeverDisagree() {
        let cases = [source(), source(health: .failing), source(readable: 16, baseline: 30),
                     source(readable: 20, unreadable: 10, baseline: 30), source(readable: 29, baseline: 30),
                     source(readable: 0, baseline: 30), source(readable: 45, baseline: 30),
                     source(health: .failing, isActive: false, reason: .orgRefusal)]

        for s in cases {
            let sheetShowsAProblem = SourceGrade(s) == .failing
                || (s.readabilityNote?.contains("won't mark anything") ?? false)
            // A source Dan is not watching is not in the sheet's working sections at all, and its scraper's
            // opinion is not work he owes anyone.
            let visibleProblem = sheetShowsAProblem && s.isActive

            #expect(SourceAttention.needsALook(s) == visibleProblem,
                    "read \(s.lastReadableCount) of usual \(s.baselineFeedCount), \(s.lastUnreadableCount) unread, active \(s.isActive), health \(s.health): the badge and the sheet disagree")
        }
    }
}

// The count has to reach the toolbar, and the toolbar has to read the LIVE store. A rule with perfect
// tests and no wire renders nothing, and that exact cut has gone unnoticed in this app before (#887, and
// again in #917's own sheet line).
@Suite("The Sources badge is wired into the toolbar (#805)")
struct SourceAttentionWiringTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    @Test func theToolbarAsksTheDomainForItsTitleRatherThanHardcodingOne() {
        #expect(!rootView.isEmpty)
        #expect(rootView.contains("SourceAttention.badgeTitle"))
        #expect(rootView.contains("SourceAttention.help"))
        // The old hardcoded pair, which could not carry a count and could not agree with anything.
        #expect(rootView.contains("ToolbarHoverLabel(title: \"Sources\"") == false)
    }

    // Read from the live store, not a snapshot taken when the window opened: a source that degrades
    // during a scout must light the badge on that scout, not on the next launch.
    @Test func theToolbarReadsTheLiveStore() {
        #expect(rootView.contains("@Query private var watchedSources: [WatchedSource]"))
    }

    // THE thing Dan actually sees. ToolbarHoverLabel hides its title until the pointer is on it, so a count
    // that only appears on hover is a symptom only a man already looking for it could find, which is the
    // very thing #805 says is the bug. The words stay up while a source needs him.
    //
    // Asserted as WORDS and not as the tint, deliberately: a colour on a toolbar button's label is at the
    // mercy of what macOS does with it, and a test asserting the source says "gold" would prove the source
    // says gold, not that Dan sees anything. The count surviving the tint being ignored is the whole point.
    @Test func theCountStaysUpWithoutHoveringWhileASourceNeedsHim() {
        #expect(rootView.contains("showsTitle: sourcesNeedingALook > 0"))
    }

    @Test func theTintIsThereToo() {
        #expect(rootView.contains("OVColor.gold"))
    }
}

// The label itself. #805 kept the count visible without the pointer on it by force-showing the title for a
// reporting button (isHovering || showsTitle). #901 went further: EVERY label is always up now, because
// the hover-to-expand width animation made toolbar buttons overlap (see
// ToolbarConsolidationGuardTests.theToolbarLabelDoesNotHideBehindHover). So the "keep the count up" intent
// is preserved by construction, and the guard for it is the always-shown one, not this hover check.
@Suite("A toolbar label always shows its title (#805/#901)")
struct ToolbarHoverLabelTests {
    private var label: String { SourceGuardHelper.source("Overture/UI/ToolbarHoverLabel.swift") }

    // The count, and every label, is up without the pointer on it: Text(title) renders unconditionally.
    @Test func theTitleIsAlwaysShown() {
        #expect(label.contains("Text(title)"))
        #expect(!label.contains("if titleIsVisible"))   // no longer gated on hover/state
    }

    // The parameter stays for source compatibility across the nine call sites, even though it no longer
    // changes anything.
    @Test func showsTitleParameterIsRetained() {
        #expect(label.contains("var showsTitle: Bool = false"))
    }
}
