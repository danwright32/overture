import SwiftUI

// The in-app voice-guidance editor (#250 / #119). Opens overture-voice-guidance.md so Dan can read
// and edit how Overture drafts in his voice, instead of hunting for a file in Application Support.
// His notes section is authoritative and protected (#251); the observed tendencies are learned from
// his edits each Prep run. Opened as a sheet from the toolbar, like DismissedView.
struct VoiceGuidanceView: View {
    // #3859: this sheet has a `StallSurface` case of its own now, so a stall recorded while it is on
    // screen is attributed to it. #3762's rule follows from that: the surface a stall is attributed to
    // has to count its own rebuilds, or the record reads `passes: 0`, and `0` there says the surface did
    // not rebuild rather than that nobody counted (L11).
    //
    // Read as an OPTIONAL, on the same footing as every other environment object here, so a missed
    // injection is a pass nobody counted rather than a crash.
    @Environment(FreezeWatch.self) private var freezeWatch: FreezeWatch?
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var loaded = false

    private let url = VoiceGuidanceStore.defaultURL

    var body: some View {
        // #3859: this surface counts its own rebuild. Bound to `_` rather than called as a statement
        // because `body` is a ViewBuilder, which takes a declaration and not a bare void expression.
        let _ = freezeWatch?.recordPass()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Voice guidance").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    _ = VoiceGuidanceStore.save(text, to: url)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(OVSpacing.lg)
            Divider()

            Text("How Overture drafts in your voice. Your notes are yours and are never auto-edited; the observed tendencies are learned from your edits after each Prep run.")
                .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, OVSpacing.lg)
                .padding(.top, OVSpacing.md)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 520, minHeight: 360)
                .padding(OVSpacing.lg)
        }
        .onAppear {
            guard !loaded else { return }
            text = VoiceGuidanceStore.load(from: url)
            loaded = true
        }
    }
}
