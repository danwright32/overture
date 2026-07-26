import SwiftUI

// The shared search UI for finding a show, over whatever set of shows the surface hosting it hands
// over. That scope is the caller's to choose and the two callers choose differently (#1580): the
// persistent bar above the Queue searches only the shows a stage will render, so a pick can only land
// on a row Dan can see, while Archive's own field searches everything Overture has ever tracked,
// because that is the screen whose job is everything else. The matching behavior and the dropdown look
// identical everywhere Dan searches. The results list
// renders as a popover, not an inline row beneath the field, because a real macOS NSToolbar clips
// or refuses to host any content taller than its own fixed strip: an inline VStack dropdown never
// appeared at all when this field lived in the toolbar (confirmed against the running app), even
// though the search bar itself rendered fine there. A popover is its own floating window layer, so
// it is not bound by the parent toolbar's height either way.
struct ShowSearchField: View {
    @Binding var query: String
    let allItems: [QueueItem]
    var placeholder: String = "Search shows, venues, contacts"
    // Declared ahead of the #1580 pair below so a call site's trailing closure still binds HERE. Swift's
    // forward scan matches a trailing closure to the first closure-typed parameter it reaches, so moving
    // this down silently handed Archive's `{ result in reveal(result.id) }` to onSearchArchive instead.
    var onSelect: (QueueItem) -> Void = { _ in }
    // #1580: the shows OUTSIDE this field's scope, counted (never listed) so an empty result can tell
    // Dan whether the show is missing or merely somewhere else, and hand him the jump. Both are empty on
    // Archive's own field, which already searches everything and has nowhere to send him.
    var archiveItems: [QueueItem] = []
    var onSearchArchive: ((String) -> Void)?
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
                    emptyState
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

    // #1580. Which of the two things happened is ShowSearch.emptyState's call, not this view's; all that
    // is decided here is that the jump is a real button (it is the next step, and Dan clicks it) rather
    // than a sentence telling him to go and search again himself.
    private var emptyState: some View {
        let state = ShowSearch.emptyState(query: trimmedQuery, archiveMatches: archiveMatchCount)
        return VStack(alignment: .leading, spacing: OVSpacing.xs) {
            Text(state.note).font(OVType.body).foregroundStyle(OVColor.inkFaint)
            if state.offersArchive, let onSearchArchive {
                Button(state.archiveAction) {
                    let carried = trimmedQuery
                    query = ""
                    selection.clear()
                    isFocused = false
                    onSearchArchive(carried)
                }
                .buttonStyle(.link)
                .font(OVType.body)
            }
        }
        .padding(.horizontal, OVSpacing.sm).padding(.vertical, OVSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Counted, never listed: the popover's job here is to say the show is elsewhere, not to become a
    // second Archive. Skipped entirely when there is nowhere to send him, so Archive's own field does
    // no matching work it will never use.
    private var archiveMatchCount: Int {
        guard onSearchArchive != nil, !trimmedQuery.isEmpty else { return 0 }
        return archiveItems.filter { ShowSearch.matches($0, query: trimmedQuery) }.count
    }

    private func pick(_ result: QueueItem) {
        onSelect(result)
        query = ""
        selection.clear()
        isFocused = false
    }
}
