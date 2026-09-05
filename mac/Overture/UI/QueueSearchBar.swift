import SwiftUI

// #1926: the persistent search bar above the Queue, and the only owner of what Dan has typed into it.
//
// The text lived on RootView, the same view that builds the Queue. @State invalidates the view that
// declares it, so every keystroke re-ran RootView's body, rebuilt QueueView (five non-Equatable closure
// arguments, so SwiftUI cannot skip it) and re-ran QueueView's body, whose first line derives the whole
// store: QueueModel.items over every prospect in the store, AgentInputs.from, the StageNavigation sweeps, the fan-out
// scan and the grouping. Typing a ten character show name dragged every prospect through the CPU roughly
// twenty times, to filter a list of at most eight rows.
//
// Holding the query here is the entire fix, and it is the same shape as #1774's scroll position: state
// belongs to the view that declares it and cannot invalidate a parent, so typing now re-runs this bar and
// nothing above it.
//
// The two scopes arrive as closures rather than built arrays for the second half of the cost (#1916's
// lesson): each is a sweep of every prospect, and as arguments they were worked out on every RootView
// render pass, empty box included. Nothing calls them until Dan types.
struct QueueSearchBar: View {
    // The shows a stage will render, which is what this bar may find (#1580).
    let items: () -> [QueueItem]
    // Everything Overture has ever tracked, counted (never listed) so an empty result can say the show is
    // in Archive and offer the jump.
    let archiveItems: () -> [QueueItem]
    let onSelect: (QueueItem) -> Void
    let onSearchArchive: (String) -> Void

    @State private var query: String = ""

    var body: some View {
        ShowSearchField(query: $query, allItems: items,
                        placeholder: "Search the queue",
                        onSelect: onSelect,
                        archiveItems: archiveItems,
                        onSearchArchive: onSearchArchive)
    }
}
