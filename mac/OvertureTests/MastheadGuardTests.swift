import Testing
import Foundation

// First-use QA polish (#329, #330, #336): the header was carrying meaningless ornament
// and a redundant app name. These are view-only edits with no behavioral surface, so the
// change is held in place with a source guard rather than a runtime assertion: the removed
// copy/ornament must stay gone, and the title-bar de-duplication must stay applied.
@Suite("Masthead header is free of the QA-flagged clutter")
struct MastheadGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        // #filePath -> .../mac/OvertureTests/MastheadGuardTests.swift; climb to mac/.
        let mac = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
        let url = mac.appendingPathComponent(relativeFromMac)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test func subheadingCopyIsGone() {  // #330
        let queueView = source("Overture/UI/QueueView.swift")
        #expect(!queueView.isEmpty)
        #expect(!queueView.contains("Performances worth pitching"))
    }

    @Test func decorativeWordmarkDotIsGone() {  // #329
        // The amber masthead dot is the only 7x7 circle; every other dot is 6x6.
        let queueView = source("Overture/UI/QueueView.swift")
        #expect(!queueView.isEmpty)
        #expect(!queueView.contains("width: 7, height: 7"))
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
}
