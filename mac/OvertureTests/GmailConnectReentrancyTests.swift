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

    // While Overture waits IN THE BACKGROUND (Safari is frontmost during consent) for the loopback
    // redirect, macOS App Nap can suspend it, which stops its main queue and silently kills the loopback
    // listener, so Google's redirect hits a dead port ("Safari can't connect to 127.0.0.1"). connect()
    // must hold an activity assertion for the whole flow to prevent that. This is system power-management
    // behaviour with no runtime seam a unit test can reach, so it is guarded at the source (the same way
    // the other view/flow-only invariants in this repo are).
    @Test func connectHoldsAnActivityAssertionToPreventAppNap() {
        let src = SourceGuardHelper.source("Overture/Integration/GmailAuthManager.swift")
        #expect(src.contains("ProcessInfo.processInfo.beginActivity"))
        #expect(src.contains("ProcessInfo.processInfo.endActivity"))
    }

    // The loopback catcher must run on a DEDICATED serial queue, not the app's main queue: a main-queue
    // NWListener can stop accepting when the main thread is throttled while Overture is in the background
    // during consent (the "Safari can't connect to 127.0.0.1" failure). The catcher CODE is correct (an
    // external client connects to a dedicated-queue listener; verified out of band), so the only thing to
    // pin is that it isn't bound to .main. No behavioural seam reaches this (a same-process connect gives
    // false negatives and the real symptom needs backgrounding), so it is source-guarded like the App Nap
    // assertion above.
    @Test func theLoopbackCatcherRunsOffTheMainQueue() {
        let src = SourceGuardHelper.source("Overture/Integration/GmailAuthManager.swift")
        #expect(src.contains("listenerQueue = DispatchQueue(label:"))
        #expect(src.contains("queue: Self.listenerQueue"))
        #expect(src.contains("conn.start(queue: Self.listenerQueue)"))
        #expect(!src.contains("LoopbackListener.start(queue: .main)"))
    }
}
