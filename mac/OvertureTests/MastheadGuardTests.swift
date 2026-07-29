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
        // The locator is the function's real signature, so a change to it fails this LOUDLY (a nil body)
        // rather than quietly scoping the check to nothing and passing. #1694 changed the signature and
        // this is how that was noticed.
        let mastheadBody = SourceGuardHelper.propertyBody("func masthead(visible: [QueueItem], items: [QueueItem], fanOutLine: String?) -> some View {", in: queueView)
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

    // #1131: the masthead status line now shows ONLY "Scouted X ago". The prep/review/approved counts and
    // "last prep" timing (prepStatus.summary) were dropped because the Prep/Review/Send pill row below
    // duplicates them; "Scouted X ago" is not shown anywhere else, so it stays. (Supersedes #339's
    // scouted-before-prepped ordering guard, which no longer has two halves to order.)
    @Test func statusLineShowsScoutedAndNoLongerPrepCounts() {  // #1131 (was #339)
        let queueView = source("Overture/UI/QueueView.swift")
        #expect(!queueView.isEmpty)
        #expect(queueView.contains("ScoutStatus(lastScoutedAt: ScoutService.lastScoutedAt())"))
        #expect(!queueView.contains("prepStatus.summary(now: Date())"))
    }
}
