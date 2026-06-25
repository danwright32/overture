import Testing
@testable import Overture

// #27: a scout run that extracts zero events almost always means the venue page changed
// or was unreachable, not that there is genuinely nothing on. That must surface as a
// warning, not a silent "0 found". Zero-events takes precedence over a client-list
// warning (with no events there is nothing to match anyway).
@MainActor
@Suite("Scout outcome warning")
struct ScoutOutcomeWarningTests {
    private func outcome(found: Int, clientListWarning: String? = nil) -> ScoutService.Outcome {
        ScoutService.Outcome(found: found, inserted: 0, updated: 0, skipped: 0,
                             uncertain: 0, clientListWarning: clientListWarning)
    }

    @Test func zeroEventsWarns() {
        #expect(outcome(found: 0).warning?.isEmpty == false)
    }

    // The empty-result warning must read as "nothing matched", distinct from a feed
    // connection failure (which is the thrown-error path, ScoutFailure). #126.
    @Test func zeroEventsWarnsAboutEmptyResultNotConnection() {
        let w = outcome(found: 0).warning ?? ""
        #expect(w.localizedCaseInsensitiveContains("no"))
        #expect(!w.localizedCaseInsensitiveContains("connection"))
        #expect(!w.localizedCaseInsensitiveContains("unavailable"))
    }

    @Test func zeroEventsTakesPrecedenceOverClientListWarning() {
        let w = outcome(found: 0, clientListWarning: "stale clients").warning
        #expect(w != "stale clients")
        #expect(w?.isEmpty == false)
    }

    @Test func withEventsTheClientListWarningPassesThrough() {
        #expect(outcome(found: 5, clientListWarning: "stale clients").warning == "stale clients")
        #expect(outcome(found: 5, clientListWarning: nil).warning == nil)
    }
}
