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
        // #1926: the field is wrapped in QueueSearchBar now, so both names are checked. Either one inside
        // a ToolbarItem breaks the popover exactly as before.
        #expect(!toolbarSection.contains("ShowSearchField"),
                "ShowSearchField must not be placed inside a ToolbarItem: a native NSToolbar item cannot host its results popover.")
        #expect(!toolbarSection.contains("QueueSearchBar"),
                "QueueSearchBar hosts that same field, so it cannot live in a ToolbarItem either.")
    }

    @Test func searchFieldIsWiredIntoTheBodyAboveQueueContent() {
        // #1930: the whole body, and the order, rather than its first 1200 characters. A budget counted in
        // characters makes any line added at the top of the body break a guard about where the search bar
        // sits, which says nothing about the search bar at all.
        // #1926: the bar owns the typed query, so the call site names it rather than a binding here.
        guard let body = SourceGuardHelper.propertyBody("var body: some View {", in: rootView),
              let bar = body.range(of: "QueueSearchBar(items: { searchableItems }"),
              let queue = body.range(of: "queueContent") else {
            Issue.record("expected the body to hold both the search bar and the queue")
            return
        }
        #expect(bar.lowerBound < queue.lowerBound)
    }
}
