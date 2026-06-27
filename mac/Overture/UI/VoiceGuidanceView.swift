import SwiftUI

// The in-app voice-guidance editor (#250 / #119). Opens overture-voice-guidance.md so Dan can read
// and edit how Overture drafts in his voice, instead of hunting for a file in Application Support.
// His notes section is authoritative and protected (#251); the observed tendencies are learned from
// his edits each Prep run. Opened as a sheet from the toolbar, like DismissedView.
struct VoiceGuidanceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var loaded = false

    private let url = VoiceGuidanceStore.defaultURL

    var body: some View {
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
