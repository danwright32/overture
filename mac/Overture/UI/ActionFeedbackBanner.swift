import SwiftUI

// #285: the shared acknowledgment surface. Overlays a brief, auto-dismissing pill at the bottom of
// whatever it's attached to, reading the window-scoped ActionFeedback. Applied to the main queue and
// to each sheet (sheets are separate windows on macOS, so an overlay on the main view can't cover
// them) — all reading the one inherited ActionFeedback object.
private struct ActionFeedbackBanner: ViewModifier {
    @Environment(ActionFeedback.self) private var feedback

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message = feedback.message {
                    Text(message)
                        .font(OVType.meta)
                        .foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.lg)
                        .padding(.vertical, OVSpacing.sm)
                        .background(
                            Capsule().fill(feedback.tone == .warning ? OVColor.rust : OVColor.forest)
                        )
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                        .padding(.bottom, OVSpacing.lg)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: feedback.revision) {
                            try? await Task.sleep(nanoseconds: 3_200_000_000)
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
