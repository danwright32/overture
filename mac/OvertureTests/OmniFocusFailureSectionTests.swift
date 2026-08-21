import Testing
import Foundation

// #2884: the settings pane's last-failure section, driven without touching Dan's real preferences.
//
// It began as a ViewInspector test that wrote the failure into `UserDefaults.standard` and put it back
// afterwards. `TestsCannotReachSharedStateTests` refused it, correctly: a test must be structurally
// unable to reach a real shared location rather than careful about it (#2540, L2), and this one would
// have written a fabricated failure onto Dan's own masthead if it had died between the write and the
// restore. The decision moved out of the view instead.
@Suite("What the OmniFocus settings pane says about the last failure (#2884)")
struct OmniFocusFailureSectionTests {

    @Test func astoredReasonIsShownWordForWord() {
        let reason = "OmniFocus updated 3 of 4 reminders. It could not update Aurora Strings."
        #expect(OmniFocusFailureSection.reasonLine(failedAt: 1_787_000_000, storedReason: reason) == reason)
    }

    // A clean sync draws NO section. A heading over an empty box is the shape #1547 was.
    @Test func acleanSyncShowsNothingAtAll() {
        #expect(OmniFocusFailureSection.reasonLine(failedAt: 0, storedReason: "") == nil)
        // Even with a reason still lying in the defaults from an older failure: the timestamp is what says
        // a failure is CURRENT, and a stale message is not a fault (L133).
        #expect(OmniFocusFailureSection.reasonLine(failedAt: 0, storedReason: "an old message") == nil)
    }

    // A failure with no reason is its own state, not a blank line under a heading.
    @Test func afailureWithNoReasonSaysThatRatherThanNothing() {
        for stored in ["", "   ", "\n"] {
            let line = OmniFocusFailureSection.reasonLine(failedAt: 1_787_000_000, storedReason: stored)
            #expect(line?.contains("recorded no reason") == true,
                    Comment(rawValue: "a blank reason rendered as \(line ?? "nil")"))
        }
    }

    // The view is dumb, and that is the property the shared-state rule bought: if the pane grew its own
    // reading of the defaults, this suite would be judging a rule nothing renders.
    @Test func thepaneRendersThisRuleRatherThanItsOwn() {
        let source = SourceGuardHelper.source("Overture/UI/OmniFocusSettingsView.swift")
        #expect(!source.isEmpty, "the guard read no source, so it asserts nothing")
        #expect(source.contains("OmniFocusFailureSection.reasonLine"),
                "the pane has to render the rule this suite drives")
        #expect(source.contains("OmniFocusFailureSection.heading"))
    }
}
