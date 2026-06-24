import Testing
@testable import Overture

// #77: a manual scout failure is a modal Dan expects after clicking; an automatic
// (scheduled) scout failure should be quiet — a status line, not a surprise dialog on
// launch he didn't trigger.
@Suite("Scout failure presentation")
struct ScoutFailureTests {
    @Test func manualFailureShowsTheModal() {
        let p = ScoutFailure.presentation(auto: false, message: "extraction failed")
        #expect(p.alert == "extraction failed")
        #expect(p.status == nil)
    }

    @Test func automaticFailureIsQuietWithNoModal() {
        let p = ScoutFailure.presentation(auto: true, message: "extraction failed")
        #expect(p.alert == nil)
        #expect(p.status?.isEmpty == false)
    }
}
