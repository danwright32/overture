import SwiftUI

// #337: the toolbar's icon-only buttons had no visible name, only the small, easy-to-miss system
// `.help()` tooltip. On hover, expand the icon into a labeled pill so the toolbar is
// self-explanatory at a glance without relying on that tooltip. A plain SwiftUI `Label` doesn't
// work for this: macOS collapses a toolbar Label's text by default at this size, which is exactly
// the behavior being fixed, so the icon and text are drawn directly instead of going through
// `Label`'s automatic icon/text choice.
struct ToolbarHoverLabel: View {
    let title: String
    let systemImage: String
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: isHovering ? 5 : 0) {
            Image(systemName: systemImage)
            if isHovering {
                Text(title)
                    .fixedSize()
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
    }
}
