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
        // this is how that was noticed. #1771 added an agentInputs: argument, so the anchor is the last
        // line of the signature rather than the whole of it (the same shape QueueRenderDataGuardTests
        // uses for AgentInputs.from).
        let mastheadBody = SourceGuardHelper.propertyBody("agentInputs: AgentInputs) -> some View {", in: queueView)
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
    //
    // #2726: the two halves are asserted TOGETHER, inside the same region, which is the only form of this
    // claim that means anything. The file-wide version asked whether `#if DEBUG` appears anywhere and
    // whether `"Debug"` appears anywhere, and `QueueView.swift` carries three unrelated `#if DEBUG`
    // blocks, so the marker could sit entirely OUTSIDE any of them and both assertions would still pass
    // (L135). That is the leak this guard exists to prevent, and the guard could not see it.
    @Test func debugMarkerIsGatedOnDebugFlag() throws {  // #377
        let queueView = source("Overture/UI/QueueView.swift")
        #expect(!queueView.isEmpty)

        // The masthead's own gate, found from the wordmark beside it rather than from whichever
        // `#if DEBUG` comes first in the file.
        let masthead = try #require(SourceGuardHelper.between("Text(\"Overture\").font(OVType.wordmark)",
                                                              and: "#endif", in: queueView),
                                    "expected to find the masthead's wordmark and the gate under it")
        #expect(masthead.contains("#if DEBUG"),
                "the Debug marker must sit under a compile-time gate, or it ships in the build Dan runs")
        #expect(masthead.contains("Text(\"Debug\")"),
                "and the marker itself must be inside that gate, which is the whole claim")
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

    // #2051: the strip carries the pills and nothing above them. The line that used to sit there counted
    // how many PILLS were lit, while every other number on that screen counts shows, so "1 needs you" sat
    // one line above a pill reading "464 to triage" and the two meant different things. It named no pill,
    // went nowhere, and each pill already carries its own state and count, which is the #843 duplicate-copy
    // shape. Dan's call, 2026-08-03: "the answer is just to remove that line entirely. I don't need words to
    // show me what the glowing badge and their count tells me."
    //
    // A source guard rather than a rendered assertion for the same reason as the rest of this suite, and one
    // specific to this line: it is assembled from interpolated fragments, so it never appeared in
    // docs/copy-inventory.md and its removal leaves no trace in that diff. Nothing else would notice it
    // coming back.
    @Test func theRollUpLineAboveThePillsIsGone() {  // #2051
        let queueView = source("Overture/UI/QueueView.swift")
        #expect(!queueView.isEmpty)
        // Scoped to the strip's own body, so a match elsewhere in a 900-line file cannot answer for it. The
        // locator is the real signature: a change to it fails this loudly with a nil body rather than
        // quietly scoping the check to nothing.
        let strip = SourceGuardHelper.propertyBody("private func agentStrip(_ inputs: AgentInputs) -> some View {",
                                                   in: queueView)
        #expect(strip != nil)
        #expect(strip?.contains("needsYou") == false)

        // And the roster offers no sentence to put back there, nor the pill-counting number behind it, which
        // nothing else reads once the line is gone.
        let roster = source("Overture/Domain/AgentRoster.swift")
        #expect(!roster.isEmpty)
        #expect(!roster.contains("needsYou"))
    }
}
