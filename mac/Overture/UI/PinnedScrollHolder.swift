import SwiftUI

// #3437/#3431: one place that holds a list's scroll position, so a scroll cannot rebuild the store.
//
// `.scrollPosition(id:)` is a READ-WRITE binding, and SwiftUI writes it every time a row crosses the top.
// Bound to a view's own `@State`, each of those writes invalidates that view, and where its body derives
// the whole store, turning the wheel rebuilds every card. Measured on the real Archive, 2026-09-03:
// scrolling built 120 cards over a 120 row store, one per row, per scroll
// (`ArchiveScrollDoesNotRebuildTests`). On the live store that is 1,139 (#3437's own profile puts
// `ArchiveView.items` at 65% of the main thread while typing).
//
// The fix, which #1774 found for the queue and this generalises: the position lives HERE, and the content
// arrives as a CLOSURE that this view runs. A scroll then writes THIS view's state and re-runs only the
// closure, never the enclosing body, so whatever the body derived is captured once and rendered again
// rather than derived again.
//
// WHY THE CONTENT IS HANDED A PROXY AND A BINDING. A deliberate jump has to cooperate with the restore
// rather than race it: #976 records that the Archive points the persisted position at its target BEFORE
// scrolling there, and #1573 records the queue's version of the same collision, where clearing and then
// scrolling meant the two mechanisms fought and the row jump was silently dropped. So a caller that
// reveals a row needs to write the position SYNCHRONOUSLY, in order, and then scroll. Handing the binding
// down is what lets it, and it is why the position is not merely driven from an input value: an
// `onChange` would land the write after the scroll, which is the race itself.
//
// A caller with no jump ignores both parameters, which is what Follow-ups does.
struct PinnedScrollHolder<ID: Hashable, Content: View>: View {
    // The row at the top of the scroll. THIS view's state, which is the whole point: SwiftUI's writes
    // land here and invalidate this view alone.
    @State private var pinned: ID?

    @ViewBuilder let content: (ScrollViewProxy, Binding<ID?>) -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content(proxy, $pinned) }
                .scrollPosition(id: $pinned, anchor: .top)
        }
    }
}
