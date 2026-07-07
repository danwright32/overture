import SwiftUI

// The pill shaped toggle Archive's status filter row uses, matching the Queue's existing
// discipline chip look without touching QueueFilterBar's already reviewed, working code.
struct FilterChip: View {
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(OVType.tag)
                .foregroundStyle(active ? OVColor.onForest : OVColor.inkSoft)
                .padding(.horizontal, OVSpacing.sm).padding(.vertical, 6)
                .background(Capsule().fill(active ? OVColor.forest : Color.clear))
        }
        .buttonStyle(.plain)
    }
}
