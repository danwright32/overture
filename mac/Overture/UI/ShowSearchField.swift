import SwiftUI

// The shared search UI for finding any show Overture has ever tracked, whether it is still
// in the Queue's date window or has since gone past, booked, closed, or dismissed. Used both as
// the persistent bar in the main window and inside Archive's own narrowing field, so the matching
// behavior and the dropdown look identical everywhere Dan searches.
struct ShowSearchField: View {
    @Binding var query: String
    let allItems: [QueueItem]
    var placeholder: String = "Search shows, venues, contacts"
    var onSelect: (QueueItem) -> Void = { _ in }
    @FocusState private var isFocused: Bool

    private var matches: [QueueItem] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return Array(
            allItems
                .filter { ShowSearch.matches($0, query: query) }
                .sorted { ($0.performanceDate ?? "") > ($1.performanceDate ?? "") }
                .prefix(8)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            if isFocused, !matches.isEmpty {
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
                        Divider()
                    }
                }
                .background(OVColor.surface)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(OVColor.line, lineWidth: 1))
                .frame(maxWidth: 320)
            }
        }
    }
}
