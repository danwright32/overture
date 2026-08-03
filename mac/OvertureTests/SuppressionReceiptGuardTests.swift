import Testing

// #802, Dan's 3rd decision: the do-not-contact guard is shown WORKING, and it is shown in the right
// place.
//
// The wiring is worth its own guard because losing it is silent: the report would simply stop appearing,
// every test would still pass, and Dan would be back to trusting a guard he cannot see, which is the
// exact thing he asked not to have to do.
@Suite("The suppression receipt is shown, and shown as a receipt (#802)")
struct SuppressionReceiptGuardTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    @Test func aScoutShowsWhoWasSuppressed() {
        #expect(!rootView.isEmpty)
        #expect(rootView.contains("SuppressionReport.summary(for: outcome.suppressedOrgs)"))
    }

    // It goes in the STATUS line, never the warning line. Nothing is wrong, nothing needs fixing, and a
    // receipt sitting in the warning slot would teach Dan to dismiss warnings, which is how the one
    // warning that matters gets missed.
    // #1047: it goes through status.set at the default (informational) priority, never priority:
    // .warning, so the receipt shows without sitting in the warning tier that now protects a real
    // scout warning from being erased.
    @Test func itIsAReceiptAndNotAWarning() {
        #expect(rootView.contains("status.set(SuppressionReport.summary(for: outcome.suppressedOrgs))"))
        #expect(rootView.contains("SuppressionReport.summary(for: outcome.suppressedOrgs), priority: .warning") == false)
    }
}
