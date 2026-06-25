import Testing
@testable import Overture

// #77: a manual scout failure is a modal Dan expects after clicking; an automatic
// (scheduled) scout failure should be quiet — a status line, not a surprise dialog on
// launch he didn't trigger.
@Suite("Scout failure presentation")
struct ScoutFailureTests {
    // A scout error always comes from the calendar feed fetch (the only throwing step), so
    // the manual modal should explain it as a connection/feed problem (not a quiet week) and
    // still keep the technical detail. #126.
    @Test func manualFailureExplainsFeedReachAndKeepsDetails() {
        let p = ScoutFailure.presentation(auto: false, message: "badResponse")
        #expect(p.status == nil)
        let alert = p.alert ?? ""
        #expect(alert.localizedCaseInsensitiveContains("feed"))
        #expect(alert.localizedCaseInsensitiveContains("connection"))
        #expect(alert.contains("badResponse"))
    }

    @Test func automaticFailureStaysQuietButNamesTheFeed() {
        let p = ScoutFailure.presentation(auto: true, message: "badResponse")
        #expect(p.alert == nil)
        #expect((p.status ?? "").localizedCaseInsensitiveContains("feed"))
    }
}
