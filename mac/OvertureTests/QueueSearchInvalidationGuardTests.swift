import Testing
import Foundation
@testable import Overture

// #1926: what a keystroke in the search box is allowed to cost.
//
// The typed query was @State on RootView, the view that also builds the Queue, and @State invalidates the
// view that declares it. So every keystroke re-ran RootView's body, rebuilt QueueView (whose five closure
// arguments are not Equatable, so SwiftUI cannot skip it) and re-ran QueueView's body, whose first line
// derives the entire store. Ten characters typed swept 724 prospects roughly twenty times to filter a
// list of at most eight rows.
//
// As with #1774, none of that has an observable output a unit test can assert on: RootView's body cannot
// be evaluated without a live container, and a re-render is not a value anything returns. What can rot,
// silently and with every other test green, is the shape, so the shape is what this pins. The behavioral
// half of the fix (the scopes not being built for an empty box) is exercised for real in
// SearchScopeIsLazyTests.
@Suite("A keystroke cannot reach the queue's derivation (#1926)")
struct QueueSearchInvalidationGuardTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }
    private var searchBar: String { SourceGuardHelper.source("Overture/UI/QueueSearchBar.swift") }
    private var field: String { SourceGuardHelper.source("Overture/UI/ShowSearchField.swift") }

    // The whole fix in one assertion: the query is not state on the view that builds the Queue. Asserted
    // over the whole file rather than over the body, because a re-declaration anywhere in RootView puts
    // the cost straight back (L30 applied to the guard itself, as in QueueInvalidationGuardTests).
    @Test func theTypedQueryIsNotStateOnTheViewThatBuildsTheQueue() {
        #expect(!rootView.isEmpty)
        #expect(!rootView.contains("@State private var searchQuery"))
    }

    // And it lives on the bar instead, which is what makes a keystroke invalidate only the bar.
    @Test func theBarOwnsTheTypedQuery() {
        #expect(!searchBar.isEmpty)
        #expect(searchBar.contains("@State private var query: String = \"\""))
    }

    // The bar sits in the window body above the Queue, not in a ToolbarItem: a native NSToolbar item
    // cannot anchor the results popover at all (confirmed against the running app, #1580).
    @Test func theBarIsInTheBodyAboveTheQueueAndNotInTheToolbar() {
        // #1930: over the whole body, and asserting the ORDER, rather than over its first 1200 characters.
        // The character budget was a proxy for "above the queue" that any unrelated line added at the top
        // of the body could break, which is exactly what happened when the render trace landed there.
        guard let body = SourceGuardHelper.propertyBody("var body: some View {", in: rootView),
              let bar = body.range(of: "QueueSearchBar("),
              let queue = body.range(of: "queueContent") else {
            Issue.record("expected the body to hold both the search bar and the queue")
            return
        }
        #expect(bar.lowerBound < queue.lowerBound)

        guard let toolbarStart = rootView.range(of: ".toolbar {")?.lowerBound else {
            Issue.record("no .toolbar block found")
            return
        }
        #expect(!rootView[toolbarStart...].contains("QueueSearchBar("))
    }

    // Both scopes are handed over as work to do, never as work already done. A built array here is the
    // #1916 shape: the argument evaluates at the call site, so the sweep runs on every render pass of a
    // view that renders for a dozen unrelated reasons, with the box sitting empty.
    @Test func bothScopesArriveAsClosuresNotBuiltLists() {
        #expect(rootView.contains("QueueSearchBar(items: { searchableItems }"))
        #expect(rootView.contains("archiveItems: { allItems }"))
        #expect(searchBar.contains("let items: () -> [QueueItem]"))
        #expect(searchBar.contains("let archiveItems: () -> [QueueItem]"))
        #expect(field.contains("let allItems: () -> [QueueItem]"))
        #expect(field.contains("var archiveItems: () -> [QueueItem]"))
    }

    // The field asks the tested helpers rather than filtering inline. Inline, the blank-query guard would
    // sit behind an already-built list again and the laziness would be undone without a test noticing.
    @Test func theFieldSearchesThroughTheLazyHelpers() {
        #expect(field.contains("ShowSearch.results(in: allItems()"))
        #expect(field.contains("ShowSearch.matchCount(in: archiveItems()"))
        #expect(!field.contains(".filter { ShowSearch.matches("),
                "matching inline here would mean the list was built before anything could decide it was not needed")
    }
}
