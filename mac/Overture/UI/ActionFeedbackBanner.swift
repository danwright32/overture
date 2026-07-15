import SwiftUI

// #285: the shared acknowledgment surface. Overlays a brief, auto-dismissing pill at the bottom of
// whatever it's attached to, reading the window-scoped ActionFeedback. Applied to the main queue and
// to each sheet (sheets are separate windows on macOS, so an overlay on the main view can't cover
// them), all reading the one inherited ActionFeedback object.
private struct ActionFeedbackBanner: ViewModifier {
    @Environment(ActionFeedback.self) private var feedback
    // #924: this surface's spot in the mount order, so only the topmost one draws (no double banner when a
    // sheet is open over the window). Registered on appear, released on disappear.
    @State private var token = 0

    func body(content: Content) -> some View {
        content
            .onAppear { token = feedback.registerBanner() }
            .onDisappear { feedback.releaseBanner(token) }
            .overlay(alignment: .bottom) {
                if let message = feedback.message, token == feedback.topBanner {
                    HStack(spacing: OVSpacing.sm) {
                        Text(message)
                            .font(OVType.meta)
                            .foregroundStyle(OVColor.onForest)
                        // #845: an acknowledgment Dan can take back, right where it tells him what
                        // happened. The banner's own life is stretched for one of these (see
                        // ActionFeedback.dismissAfter): an Undo that vanishes in three seconds is one he
                        // will miss, and a mis-click he notices a minute later is still a mis-click.
                        if let action = feedback.action {
                            Button(action.label) {
                                action.perform()
                            }
                            .buttonStyle(.plain)
                            .font(OVType.meta.weight(.semibold))
                            .foregroundStyle(OVColor.onForest)
                            .padding(.horizontal, OVSpacing.sm)
                            .padding(.vertical, 2)
                            .background(Capsule().strokeBorder(OVColor.onForest.opacity(0.6), lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, OVSpacing.lg)
                    .padding(.vertical, OVSpacing.sm)
                    .background(
                        Capsule().fill(feedback.tone == .warning ? OVColor.rust : OVColor.forest)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                    .padding(.bottom, OVSpacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: feedback.revision) {
                        let seconds = ActionFeedback.dismissAfter(hasAction: feedback.action != nil)
                        try? await Task.sleep(for: .seconds(seconds))
                        feedback.clear()
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: feedback.revision)
    }
}

extension View {
    // Attach the shared acknowledgment banner to a window or sheet root.
    func actionFeedbackBanner() -> some View { modifier(ActionFeedbackBanner()) }
}
