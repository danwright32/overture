import Testing
import Foundation

// Regression guard: confirmed against the running app that a native NSToolbar item cannot host a
// working ShowSearchField at all, since a SwiftUI .popover attached to toolbar-hosted content
// never anchors or appears (the identical field embedded in Archive's own body works correctly).
// The global search field must live in the window body, not inside any ToolbarItem, or the
// results dropdown silently stops working for anyone typing into it.
@Suite("RootView's search field lives in the body, not the toolbar")
struct RootViewSearchFieldGuardTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    @Test func searchFieldIsNotInsideAnyToolbarItem() {
        #expect(!rootView.isEmpty)
        guard let toolbarStart = rootView.range(of: ".toolbar {")?.lowerBound else {
            Issue.record("no .toolbar block found")
            return
        }
        let toolbarSection = rootView[toolbarStart...]
        #expect(!toolbarSection.contains("ShowSearchField"),
                "ShowSearchField must not be placed inside a ToolbarItem: a native NSToolbar item cannot host its results popover.")
    }

    @Test func searchFieldIsWiredIntoTheBodyAboveQueueContent() {
        guard let bodyRange = rootView.range(of: "var body: some View {") else {
            Issue.record("body not found")
            return
        }
        let body = rootView[bodyRange.lowerBound...].prefix(1200)
        #expect(body.contains("ShowSearchField(query: $searchQuery, allItems: searchableItems"))
        #expect(body.contains("queueContent"))
    }
}
