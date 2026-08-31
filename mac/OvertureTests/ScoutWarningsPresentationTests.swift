import Testing
import Foundation

// #1027: WHERE a finished scout's warnings go is a decision, not a view detail, so it lives in a pure
// function a test can pin (#863: logic that sat in a view drifted twice under a green suite). A manual
// run Dan started gets the branded popup; an unattended scheduled run leaves only a quiet masthead line
// and never pops a modal at him; a clean run shows nothing.
@Suite("Where a finished scout's warnings go (#1027)")
struct ScoutWarningsPresentationTests {
    private func warnings(saveFailed: Bool = false) -> ScoutWarnings {
        ScoutWarnings(saveFailed: saveFailed, extractLaunchFailure: nil, extractRunFinishedEmpty: nil,
                      failedSources: [], unqueuedIds: [], silentlyEmptySources: [], clientListWarning: nil)
    }

    @Test func aCleanRunShowsNothing() {
        #expect(ScoutWarningsPresentation.decide(warnings(), auto: false) == .nothing)
        #expect(ScoutWarningsPresentation.decide(warnings(), auto: true) == .nothing)
    }

    @Test func aManualRunGetsThePopup() {
        let w = warnings(saveFailed: true)
        #expect(ScoutWarningsPresentation.decide(w, auto: false) == .popup(w))
    }

    @Test func anUnattendedRunGetsOnlyAQuietLine() {
        let w = warnings(saveFailed: true)
        #expect(ScoutWarningsPresentation.decide(w, auto: true)
                == .quietLine("The scout couldn't save its results. Run it again."))
    }
}
