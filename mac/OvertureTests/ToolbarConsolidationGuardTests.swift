import Testing
import Foundation

// Epic #356 Phase 2 (#352, #344, #355, #337): toolbar consolidation. View-only changes with no
// separate behavioral surface beyond OmniFocusSyncStatus's lastSuccessAt (covered in
// OmniFocusSyncStatusTests), so held in place with source guards, matching this project's existing
// convention (MastheadGuardTests, ProspectRowGuardTests).
@Suite("Toolbar consolidation (#352, #344, #355, #337)")
struct ToolbarConsolidationGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var rootView: String { source("Overture/App/RootView.swift") }
    private var queueView: String { source("Overture/UI/QueueView.swift") }

    // #352: Scout and Prep merge into one menu, Scout's content listed before Prep's, each keeping
    // its own keyboard shortcut and its own independent disabled condition.
    @Test func scoutAndPrepShareOneMenuWithScoutFirst() {
        #expect(!rootView.isEmpty)
        let scoutButtonRange = rootView.range(of: "Button(\"Run scout now\")")
        let prepButtonRange = rootView.range(of: "Label(\"Prep kept\", systemImage: \"envelope.badge\")")
        #expect(scoutButtonRange != nil)
        #expect(prepButtonRange != nil)
        if let scoutButtonRange, let prepButtonRange {
            #expect(scoutButtonRange.lowerBound < prepButtonRange.lowerBound)
        }
    }

    @Test func scoutAndPrepEachKeepTheirOwnKeyboardShortcut() {
        #expect(rootView.contains("keyboardShortcut(\"r\", modifiers: .command)"))
        #expect(rootView.contains("keyboardShortcut(\"p\", modifiers: .command)"))
    }

    @Test func scoutAndPrepEachKeepTheirOwnDisabledCondition() {
        #expect(rootView.contains(".disabled(isScanning)"))
        #expect(rootView.contains(".disabled(!canStartPrep)"))
    }

    // There should be exactly one merged Scout/Prep menu now, not two separate toolbar controls.
    @Test func thereIsOnlyOneRunScoutNowButton() {
        let count = rootView.components(separatedBy: "Button(\"Run scout now\")").count - 1
        #expect(count == 1)
    }

    // Dan's call: clicking the merged icon should never guess which of Scout or Prep he meant.
    // A Menu's `primaryAction:` trailing closure is what gives a plain click a default action
    // instead of always opening the dropdown; the control must not have one.
    @Test func scoutAndPrepMenuHasNoDefaultClickAction() {
        #expect(!rootView.isEmpty)
        #expect(!rootView.contains("primaryAction: {"))
    }

    // #344: the connected state collapses to a bare icon (no visible "Gmail connected" text
    // wrapper), only the disconnected/connecting states stay prominent.
    @Test func gmailConnectedStateIsABareIconNotALabel() {
        #expect(!rootView.isEmpty)
        #expect(!rootView.contains("Label(\"Gmail connected\", systemImage: \"checkmark.circle.fill\")"))
        #expect(rootView.contains("Image(systemName: \"checkmark.circle.fill\")"))
    }

    // #355: the manual sync action moves into a menu alongside the enabled toggle and a status
    // readout, instead of being a bare always-prominent button.
    @Test func omniFocusManualSyncIsInsideAMenu() {
        #expect(!rootView.isEmpty)
        #expect(rootView.contains("syncOmniFocus(force: true)"))
        // The old bare-button form: a ToolbarItem whose direct label was the checklist icon with no
        // surrounding Menu. Its replacement must wrap the same action in a Menu instead.
        #expect(rootView.contains("Menu {") )
        #expect(rootView.contains("omniFocusEnabled"))
    }

    @Test func omniFocusEnabledToggleSharesTheReminderSettingsKey() {
        // Must bind through the SAME AppStorage key OmniFocusSettingsView uses, so toggling from
        // either surface stays in sync rather than tracking a second, divergent flag.
        #expect(rootView.contains("OmniFocusSyncConfig.Keys.enabled"))
    }

    // #337: idle-state toolbar buttons use the shared label instead of a bare system Label (whose text
    // macOS's toolbar hides by default at this size).
    @Test func toolbarButtonsUseTheSharedLabel() {
        #expect(!rootView.isEmpty)
        let occurrences = rootView.components(separatedBy: "ToolbarHoverLabel(").count - 1
        // Dismissed, Due, What converts, Voice guidance, Sources (#800), Days off (#901), Skipped towns
        // (#1118), Presenters (#1731), the merged Scout/Prep idle state, the disconnected-Gmail CTA, and
        // the OmniFocus menu's idle state: eleven call sites.
        //
        // The number is pinned deliberately rather than loosened to "at least one". SwiftUI's toolbar
        // builder tops out at ten CHILDREN and the row already overflows into the macOS ">>" menu, so a
        // new button is never free: it pushes something else towards being hidden. Making this test fail
        // is the point, because it forces whoever adds one to decide what it displaces.
        #expect(occurrences == 11)
    }

    // #901 (Dan's walk, 2026-07-14): Days off is ordered AHEAD of the settings-ish buttons (What
    // converts, Voice guidance), so if the toolbar ever overflows into the macOS ">>" menu the brand-new
    // Days off button is not the first thing hidden. The daily-driver and "what Overture works from"
    // buttons come first; the settings views can fall into overflow instead.
    @Test func daysOffIsOrderedAheadOfTheSettingsButtons() {
        #expect(!rootView.isEmpty)
        guard let daysOff = rootView.range(of: "showDaysOff = true"),
              let whatConverts = rootView.range(of: "showPatterns = true") else {
            Issue.record("expected both the Days off and What converts buttons in the toolbar")
            return
        }
        #expect(daysOff.lowerBound < whatConverts.lowerBound)
    }

    // #931's rehome, #2397's trim. The four reminder-interval steppers went with the conversation states
    // they tuned; the OmniFocus look-ahead window has no other home and stays. Pinned so the sheet cannot
    // rot back into dead code with no caller.
    @Test func theOmniFocusSyncWindowIsReachableFromRootView() {
        #expect(!rootView.isEmpty)
        #expect(rootView.contains("OmniFocusSettingsView"))      // presented
        #expect(rootView.contains("Sync window"))                // the menu entry that opens it
    }

    // #931: on/off for OmniFocus sync lives once, in the toolbar menu that opens the reminder sheet, so
    // the sheet must NOT carry its own duplicate enable toggle (two controls doing one job). The
    // look-ahead window has no other home, so it stays. Re-adding the toggle turns this red.
    @Test func theSyncSheetDoesNotDuplicateTheOmniFocusToggle() {
        let sheet = source("Overture/UI/OmniFocusSettingsView.swift")
        #expect(!sheet.isEmpty)
        #expect(!sheet.contains("Sync due reminders to OmniFocus"))   // the old duplicate toggle's label
        #expect(!sheet.contains("Toggle(isOn: $omniFocusEnabled)"))   // and its control
        #expect(sheet.contains("Look-ahead window"))                  // the setting that has no other home stays
    }

    // #1134: stage-only navigation removed the four queue filters, including the pending-bookings toolbar
    // toggle (#932). The masthead still shows the "N to confirm" count; there is simply no filter toggle
    // for it any more. Pin that the removed toggle stays gone (it must not creep back into the toolbar).
    @Test func theBookingsFilterToggleIsGone() {
        #expect(!queueView.isEmpty)
        #expect(!queueView.contains("showPendingBookingsOnly"))
        #expect(!queueView.contains("QueueModel.confirmBookingsLabel"))
    }

    // #901 (Dan's walk, 2026-07-14): the toolbar is icon-only, names on hover. Animating a button's width
    // to reveal its label made neighbouring buttons overlap and the icon spill out of its container
    // mid-animation, because macOS doesn't reflow the toolbar in step. This guard pins that the hover
    // reveal and its width animation stay gone, because quietly reintroducing either brings the overlap
    // back. (The label still shows STATICALLY when a caller passes showsTitle, with no hover involved,
    // covered by ToolbarHoverLabelTests.)
    @Test func theToolbarLabelDoesNotHideBehindHover() {
        let label = source("Overture/UI/ToolbarHoverLabel.swift")
        #expect(!label.isEmpty)
        #expect(!label.contains("onHover"))
        #expect(!label.contains("isHovering"))
        #expect(!label.contains(".animation("))   // no width animation left to overlap on
    }
}
