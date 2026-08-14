import SwiftUI

// #2711: recording a reply that arrived somewhere Overture cannot see, from the row Dan stands on.
//
// Its own view for the same reason `CloseOutMenu` is (#2112/#2224): to a person this is ONE control on
// the row, and spelling its three states inline would make it three constructs to `ReachedOutRowSlots`'
// guard, which counts what the trailing column draws. One control, one slot, one decision about what the
// row may show at once (#2167).
//
// Three states rather than a button that changes meaning: it is offered, it has been pressed and can be
// taken back, or it has been pressed and cannot. The middle and last are what stop a control that keeps
// offering itself after being pressed (L44), and the last carries its reason rather than simply vanishing
// (L109).
struct HandMarkedReplyControl: View {
    let recipient: Recipient
    let prospect: Prospect
    let onMark: () -> Void
    let onUndo: () -> Void

    var body: some View {
        if HandMarkedReply.isOffered(recipient) {
            Button(HandMarkedReplyCopy.mark, action: onMark)
                .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forestText)
        } else if recipient.replyMarkedByHandAt != nil {
            if let refusal = HandMarkedReply.undoRefusal(recipient) {
                Text(refusal).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button(HandMarkedReplyCopy.undo, action: onUndo)
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            }
        }
    }
}
