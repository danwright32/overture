import Testing
import Foundation
@testable import Overture

// The live Gmail connect binds a loopback listener on a throwaway port and opens the browser to Google,
// which redirects back to http://127.0.0.1:<port>. The old flow called cancelInFlight() at the TOP of
// every connect(), which tore down any prior attempt's listener. A single Connect tap can fire the
// SwiftUI toolbar action twice (and other surfaces call connect() too), so a second call cancelled the
// FIRST attempt's listener on the very port Google was about to redirect to, producing "Safari can't
// connect to 127.0.0.1" even when the user completed consent in seconds. The re-entrancy guard refuses a
// second attempt while one is in flight, so the live listener survives to catch the redirect.
@MainActor
@Suite("Gmail connect refuses a second attempt while one is in flight")
struct GmailConnectReentrancyTests {
    @Test func aSecondAttemptIsRefusedWhileOneIsInFlight() {
        let manager = GmailAuthManager()

        // The first attempt claims the flow.
        #expect(manager.beginConnectAttempt() == true)
        // A second trigger while it is in flight is refused, so it can't cancel the live listener.
        #expect(manager.beginConnectAttempt() == false)
        #expect(manager.beginConnectAttempt() == false)
    }

    @Test func aRetryProceedsOnceThePriorAttemptEnds() {
        let manager = GmailAuthManager()

        #expect(manager.beginConnectAttempt() == true)
        manager.endConnectAttempt()   // the prior attempt finished (succeeded, failed, or timed out)
        // Now a genuine retry is allowed again.
        #expect(manager.beginConnectAttempt() == true)
    }
}
