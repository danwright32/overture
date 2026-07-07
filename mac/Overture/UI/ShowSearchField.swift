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
        HStack(spacing: OVSpacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(OVColor.inkFaint)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(OVColor.inkFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, OVSpacing.sm).padding(.vertical, 6)
        .background(Capsule().fill(OVColor.surfaceSunk))
        .overlay(Capsule().strokeBorder(OVColor.line, lineWidth: 1))
        .frame(maxWidth: 280)
        .popover(isPresented: $showDropdown, arrowEdge: .bottom) {
            Group {
                if matches.isEmpty {
                    Text("No matches for \"\(trimmedQuery)\"")
                        .font(OVType.body).foregroundStyle(OVColor.inkFaint)
                        .padding(.horizontal, OVSpacing.sm).padding(.vertical, OVSpacing.sm)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { result in
                            Button {
                                onSelect(result)
                                query = ""
                                isFocused = false
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
                            if result.id != matches.last?.id { Divider() }
                        }
                    }
                    .padding(.vertical, OVSpacing.xs)
                }
            }
            .frame(minWidth: 280, maxWidth: 320)
        }
        .onChange(of: isFocused) { _, focused in showDropdown = focused && !trimmedQuery.isEmpty }
        .onChange(of: query) { _, _ in showDropdown = isFocused && !trimmedQuery.isEmpty }
    }
}
