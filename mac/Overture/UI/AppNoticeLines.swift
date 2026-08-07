import SwiftUI

// #2204: the app's own messages, on the queue where Dan reads, instead of in a toolbar slot macOS hides
// in an overflow chevron at his ordinary window width.
//
// Its own view rather than a @ViewBuilder property of QueueView, for the #1923 reason: a property is
// inlined into its parent's body, so a status write would repaint the whole masthead and re-derive the
// store behind it. Held here, a new message repaints these lines.
//
// It wraps rather than truncates, which is the point of moving: a line that fits the window is a line
// Dan can read at any width, and #1411's rule (never clip the one thing he can act on) survives the move
// without needing a capsule to grow.
struct AppNoticeLines: View {
    let notices: [AppNotice]
    // #2250: performs whatever a notice names. Handed in, because starting a sync (or any other remedy)
    // belongs to the view that owns the app's run state, not to the lines that report on it.
    var perform: (AppNoticeAction) -> Void = { _ in }

    var body: some View {
        // Nothing to say draws nothing at all, so a quiet app adds no rows here.
        ForEach(notices) { line($0) }
    }

    // The tooltip is applied only where there IS one. `.help("")` is not a no-op: it hangs an empty
    // string on the view, which renders as a blank line beside the sentence.
    @ViewBuilder private func line(_ notice: AppNotice) -> some View {
        // #2250: the control sits at the end of the sentence that explains it, in the same wrapping row,
        // so a narrow window can never separate a fault from its remedy.
        HStack(alignment: .firstTextBaseline, spacing: OVSpacing.xs) {
            let text = Text(notice.text)
                .font(.system(size: 11))
                .foregroundStyle(notice.tone == .warning ? OVColor.rust : OVColor.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
            if let help = notice.help {
                text.help(help)
            } else {
                text
            }
            if let action = notice.action {
                Button(action.title) { perform(action) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OVColor.forest)
            }
            Spacer(minLength: 0)
        }
    }
}
