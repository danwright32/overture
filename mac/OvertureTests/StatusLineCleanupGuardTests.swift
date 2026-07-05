import Testing
import Foundation

// Epic #356 Phase 3 (#345, #346, #353): status-line cleanup, narrowly scoped to just the scout
// summary and the redundant prep-started message. View-only with no separate behavioral surface,
// held in place with source guards, matching this project's existing convention.
@Suite("Status line cleanup (#345, #346, #353)")
struct StatusLineCleanupGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var rootView: String { source("Overture/App/RootView.swift") }

    // #353: the button's own "Prepping…" state (and QueueView's masthead count) already say a
    // prep run is in progress; the separate center message restated the same thing.
    @Test func prepStartedMessageIsGone() {
        #expect(!rootView.isEmpty)
        #expect(!rootView.contains("Prep started for"))
    }

    // #346: the scout outcome gets its OWN state, not the shared statusMessage bus, so it can be
    // anchored next to the Scout control instead of the unrelated center status slot.
    @Test func scoutOutcomeHasItsOwnState() {
        #expect(rootView.contains("scoutSummary"))
        #expect(!rootView.contains("statusMessage = parts.joined"))
    }

    // #346: declared between the merged Scout/Prep control and Gmail, so it renders adjacent to
    // the button that produced it rather than in the unrelated center status slot.
    @Test func scoutSummaryRendersBetweenScoutAndPrepAndGmail() {
        let scoutRange = rootView.range(of: "ToolbarHoverLabel(title: \"Scout & Prep\"")
        let summaryRange = rootView.range(of: "Text(scoutSummary)")
        let gmailRange = rootView.range(of: "connectGmail()")
        #expect(scoutRange != nil)
        #expect(summaryRange != nil)
        #expect(gmailRange != nil)
        if let scoutRange, let summaryRange, let gmailRange {
            #expect(scoutRange.lowerBound < summaryRange.lowerBound)
            #expect(summaryRange.lowerBound < gmailRange.lowerBound)
        }
    }

    // #345: symmetric horizontal padding so the text doesn't crowd the pill's edge.
    @Test func scoutSummaryHasHorizontalPadding() {
        guard let summaryRange = rootView.range(of: "Text(scoutSummary)") else {
            Issue.record("Text(scoutSummary) not found")
            return
        }
        let after = rootView[summaryRange.upperBound...].prefix(200)
        #expect(after.contains(".padding(.horizontal"))
    }
}
