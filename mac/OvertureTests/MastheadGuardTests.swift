import Testing
import Foundation

// First-use QA polish (#329, #330, #336): the header was carrying meaningless ornament
// and a redundant app name. These are view-only edits with no behavioral surface, so the
// change is held in place with a source guard rather than a runtime assertion: the removed
// copy/ornament must stay gone, and the title-bar de-duplication must stay applied.
@Suite("Masthead header is free of the QA-flagged clutter")
struct MastheadGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    @Test func subheadingCopyIsGone() {  // #330
        let queueView = source("Overture/UI/QueueView.swift")
        #expect(!queueView.isEmpty)
        #expect(!queueView.contains("Performances worth pitching"))
    }

    @Test func decorativeWordmarkDotIsGone() {  // #329, hardened #569
        // The removed amber masthead dot lived inside the masthead view's own body, so scoping
        // this check there (rather than a magic "width: 7, height: 7" string anywhere in a
        // 700+ line file) can't false-positive on an unrelated circle elsewhere, and can't be
        // fooled by a resized reintroduction of the same dot.
        let queueView = source("Overture/UI/QueueView.swift")
        #expect(!queueView.isEmpty)
        let mastheadBody = SourceGuardHelper.propertyBody("private var masthead: some View {", in: queueView)
        #expect(mastheadBody != nil)
        #expect(mastheadBody?.contains("Circle()") == false)
    }

    @Test func windowTitleBarTextIsSuppressed() {  // #336
        let app = source("Overture/App/OvertureApp.swift")
        #expect(!app.isEmpty)
        #expect(app.contains(".windowStyle(.hiddenTitleBar)"))
    }

    // #377: a live app and a Debug build can be open side by side showing different data; the
    // masthead must carry a marker that only compiles into Debug builds, so it can never leak
    // into what Dan sees running live.
    @Test func debugMarkerIsGatedOnDebugFlag() {  // #377
        let queueView = source("Overture/UI/QueueView.swift")
        #expect(!queueView.isEmpty)
        #expect(queueView.contains("#if DEBUG"))
        #expect(queueView.contains("\"Debug\""))
    }

    // #339: the status line listed "last prep" before "Scouted", reversing the order Dan
    // actually reads events in (scout finds them, then prep works the ones he kept).
    @Test func statusLineShowsScoutedBeforePrepped() {  // #339
        let queueView = source("Overture/UI/QueueView.swift")
        #expect(!queueView.isEmpty)
        let scoutedRange = queueView.range(of: "ScoutStatus(lastScoutedAt: ScoutService.lastScoutedAt())")
        let prepRange = queueView.range(of: "prepStatus.summary(now: Date())")
        #expect(scoutedRange != nil)
        #expect(prepRange != nil)
        if let scoutedRange, let prepRange {
            #expect(scoutedRange.lowerBound < prepRange.lowerBound)
        }
    }
}
