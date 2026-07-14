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
    // #805: keep the title up even when the pointer is elsewhere, for a button that is reporting something
    // rather than merely naming itself. A count Dan can only see by hovering over the right icon is not a
    // symptom, and the failure this exists for (a source that quietly half works) has no other one.
    //
    // Words, and not color alone: a tint on a toolbar BUTTON's label is at the mercy of whatever macOS
    // decides to do with it, so the sentence has to survive the tint being ignored entirely.
    var showsTitle: Bool = false
    @State private var isHovering = false

    private var titleIsVisible: Bool { isHovering || showsTitle }

    var body: some View {
        HStack(spacing: titleIsVisible ? 5 : 0) {
            Image(systemName: systemImage)
            if titleIsVisible {
                Text(title)
                    .fixedSize()
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: titleIsVisible)
        .onHover { isHovering = $0 }
    }
}
