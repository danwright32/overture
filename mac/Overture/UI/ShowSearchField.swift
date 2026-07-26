import SwiftUI

// The shared search UI for finding any show Overture has ever tracked, whether it is still
// in the Queue's date window or has since gone past, booked, closed, or dismissed. Used both as
// the persistent bar in the main window's toolbar and inside Archive's own narrowing field, so
// the matching behavior and the dropdown look identical everywhere Dan searches. The results list
// renders as a popover, not an inline row beneath the field, because a real macOS NSToolbar clips
// or refuses to host any content taller than its own fixed strip: an inline VStack dropdown never
// appeared at all when this field lived in the toolbar (confirmed against the running app), even
// though the search bar itself rendered fine there. A popover is its own floating window layer, so
// it is not bound by the parent toolbar's height either way.
struct ShowSearchField: View {
    @Binding var query: String
    let allItems: [QueueItem]
    var placeholder: String = "Search shows, venues, contacts"
    var onSelect: (QueueItem) -> Void = { _ in }
    @FocusState private var isFocused: Bool
    @State private var showDropdown = false
    // #1574: which result the arrow keys are sitting on. All the arithmetic is in ShowSearchSelection;
    // this view only turns key presses into moves and draws the highlight.
    @State private var selection = ShowSearchSelection()

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var matches: [QueueItem] {
        guard !trimmedQuery.isEmpty else { return [] }
        return Array(
            allItems
                .filter { ShowSearch.matches($0, query: query) }
                .sorted { ($0.performanceDate ?? "") > ($1.performanceDate ?? "") }
                .prefix(8)
        )
    }

    var body: some View {
        // #1432: the control itself is OVSearchField, shared with the Sources sheet's own field. Only the
        // behavior below (the results popover and what opens it) is this field's own.
        OVSearchField(query: $query, placeholder: placeholder, focused: $isFocused)
        .frame(maxWidth: 280)
        // #1574. The arrows are ignored (so the text field keeps its own caret movement) unless there
        // is actually a list of results on screen to move through.
        .onKeyPress(.downArrow) {
            guard showDropdown, !matches.isEmpty else { return .ignored }
            selection.moveDown(resultCount: matches.count)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard showDropdown, !matches.isEmpty else { return .ignored }
            selection.moveUp(resultCount: matches.count)
            return .handled
        }
        .onKeyPress(.escape) {
            guard showDropdown else { return .ignored }
            selection.clear()
            showDropdown = false
            return .handled
        }
        // Return opens whatever the arrows are sitting on, down the same path as a click. With nothing
        // highlighted, commitIndex is nil and this does nothing at all, which is the point: a query
        // typed and submitted by reflex must never open a show Dan has not looked at.
        .onSubmit {
            guard let position = selection.commitIndex(resultCount: matches.count) else { return }
            pick(matches[position])
        }
        .popover(isPresented: $showDropdown, arrowEdge: .bottom) {
            Group {
                if matches.isEmpty {
                    Text(ShowSearch.noMatchesNote(query: trimmedQuery))
                        .font(OVType.body).foregroundStyle(OVColor.inkFaint)
                        .padding(.horizontal, OVSpacing.sm).padding(.vertical, OVSpacing.sm)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { position, result in
                            Button {
                                pick(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.groupName).font(OVType.body).foregroundStyle(OVColor.ink)
                                    Text([result.venue, result.performanceDate].compactMap { $0 }.joined(separator: " "))
                                        .font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                                }
                                .padding(.horizontal, OVSpacing.sm).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            // The row Return would open, marked so the keyboard is never moving something
                            // invisible.
                            .background(selection.index == position ? OVColor.forest.opacity(0.14) : Color.clear)
                            if result.id != matches.last?.id { Divider() }
                        }
                    }
                    .padding(.vertical, OVSpacing.xs)
                }
            }
            .frame(minWidth: 280, maxWidth: 320)
        }
        .onChange(of: isFocused) { _, focused in
            showDropdown = focused && !trimmedQuery.isEmpty
            if !focused { selection.clear() }
        }
        // A new query means a new list, so the old highlight points at a row that is no longer there.
        .onChange(of: query) { _, _ in
            selection.clear()
            showDropdown = isFocused && !trimmedQuery.isEmpty
        }
    }

    private func pick(_ result: QueueItem) {
        onSelect(result)
        query = ""
        selection.clear()
        isFocused = false
    }
}
