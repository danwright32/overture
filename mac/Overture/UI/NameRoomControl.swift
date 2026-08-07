import SwiftUI

// #1752: the card half of "say where this room is".
//
// Its own view, and its own state, for two reasons. The queue card's construction is already at the
// Swift type-checker's limit (#1700), so a whole inline editor added to that body is a compile-time
// risk for a feature that has nothing to do with the rest of it. And the editor genuinely owns state
// nobody else needs (is it open, what has been typed), which on the row itself would be bookkeeping
// living on the object that derives the expensive card (L59).
//
// The answer it collects is about the ROOM, not this card, so it reaches every show played there. That
// is stated in the copy rather than assumed: a control whose effect is wider than the thing it sits on
// has to say so.
struct NameRoomControl: View {
    let room: String
    let onSave: (String) -> Void

    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        if editing {
            HStack(spacing: OVSpacing.xs) {
                TextField(UnplacedRoomCopy.placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(OVType.meta.weight(.regular))
                    .frame(maxWidth: 180)
                    .onSubmit { commit() }
                OVCapsuleButton(label: UnplacedRoomCopy.save, tint: OVColor.forest) { commit() }
                OVCapsuleButton(label: UnplacedRoomCopy.cancel, tint: OVColor.inkSoft) {
                    editing = false
                }
            }
        } else {
            // Drawn as a control at rest, not only on hover: an interactive element styled like static
            // text ships as an invisible feature (L49).
            Button(UnplacedRoomCopy.add) {
                draft = ""
                editing = true
            }
            .buttonStyle(.plain)
            .font(OVType.meta.weight(.regular))
            .foregroundStyle(OVColor.forest)
            .underline()
            .accessibilityLabel(UnplacedRoomCopy.askOnCardAccessible(room: room))
        }
    }

    private func commit() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty box is a cancel, not a withdrawal: this control never had an answer to withdraw, and
        // treating blank as "delete the room's answer" would let a mis-tap undo a correct one.
        guard !typed.isEmpty else { editing = false; return }
        onSave(typed)
        editing = false
    }
}
