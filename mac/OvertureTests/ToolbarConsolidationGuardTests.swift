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
        // Must bind through the SAME AppStorage key ReminderSettingsView uses, so toggling from
        // either surface stays in sync rather than tracking a second, divergent flag.
        #expect(rootView.contains("OmniFocusSyncConfig.Keys.enabled"))
    }

    // #337: idle-state toolbar buttons use the shared hover-expand treatment instead of a bare
    // system Label (whose text macOS's toolbar hides by default at this size).
    @Test func toolbarButtonsUseTheHoverExpandLabel() {
        #expect(!rootView.isEmpty)
        let occurrences = rootView.components(separatedBy: "ToolbarHoverLabel(").count - 1
        // Dismissed, Due, What converts, Voice guidance, the merged Scout/Prep idle state, the
        // disconnected-Gmail CTA, and the OmniFocus menu's idle state: seven call sites.
        #expect(occurrences == 7)
    }
}
