import Testing
import Foundation

// #1163: a failed Gmail connect must not vanish into the shared generic "Something went wrong / OK" alert.
// It gets its OWN alert that leads with a one-click Try again, because a broken handoff is the connect
// error Dan recovers from by simply retrying. RootView presenting an alert is view-only wiring with no
// runtime seam a unit test can drive (like the other view invariants guarded from source in this repo), so
// the wiring is pinned from source and paired here with a behavioral check of the message it actually shows.
@MainActor
@Suite("A failed Gmail connect gets its own actionable, retryable alert")
struct GmailConnectFailureAlertTests {
    // Behavioral: the message the alert shows for the health-check failure is specific and actionable, not a
    // bare "something went wrong". It names Gmail and tells Dan the browser was never opened.
    @Test func theUnreachableListenerErrorIsSpecificAndActionable() {
        let message = GmailAuthManager.AuthError.listenerUnreachable.errorDescription ?? ""
        #expect(!message.isEmpty)
        #expect(message.contains("Gmail"))
        #expect(message.contains("browser"))
    }

    // Source guard: a connect failure routes to the dedicated Gmail alert state (not the shared errorMessage),
    // and that alert offers a Try again that clears the error and re-runs the connect.
    @Test func rootViewSurfacesAFailedConnectViaTheGmailRetryAlert() {
        let src = SourceGuardHelper.source("Overture/App/RootView.swift")
        // The failure lands in the Gmail-specific state, so it can drive its own retry alert. #2202: via
        // the one raiser, which closes whatever is presented first, because an alert raised into a window
        // already showing a sheet queues behind it and is never seen.
        #expect(src.contains("reportGmailConnectError(error.localizedDescription)"))
        #expect(SourceGuardHelper.propertyBody("private func reportGmailConnectError(_ message: String) {", in: src)?
            .contains("modals.raise { gmailConnectError = message }") == true)
        // A dedicated alert, titled for the Gmail connect, with a one-click Try again that reruns connect.
        #expect(src.contains(#".alert("Couldn't connect Gmail""#))
        #expect(src.contains(#"Button("Try again")"#))
        #expect(src.contains("gmailConnectError = nil; connectGmail()"))
    }
}
