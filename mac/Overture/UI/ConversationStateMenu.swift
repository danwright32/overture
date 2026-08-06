import SwiftUI

// The shared "pick a contact's conversation state" control (#111/#652), extracted from
// FollowUpsView.setStateMenu and DraftReviewView.stateMenu, which each independently rendered
// this same Menu (#662), so the two can never drift apart again.
struct ConversationStateMenu: View {
    let currentState: ConversationState?
    let label: String
    // #1139: an optional icon + accent, so a caller that sits this control right next to another one
    // (the draft-review row's "Mark…" outcome menu) can make the two read as a deliberate, distinct pair
    // rather than two identical dropdowns. Both default to nil, so every other caller (Follow-ups, the
    // reached-out row) renders exactly as before: a plain borderless text menu on the system default.
    var systemImage: String? = nil
    var accent: Color? = nil
    let onSet: (ConversationState) -> Void

    var body: some View {
        Menu {
            ForEach(ConversationState.allCases, id: \.self) { s in
                Button {
                    onSet(s)
                } label: {
                    if s == currentState { Label(s.label, systemImage: "checkmark") }
                    else { Text(s.label) }
                }
            }
        } label: {
            menuLabel
        }
        .menuStyle(.borderlessButton).fixedSize()
        .font(OVType.meta)
    }

    @ViewBuilder private var menuLabel: some View {
        let base = Group {
            if let systemImage { Label(label, systemImage: systemImage) }
            else { Text(label) }
        }
        if let accent {
            base
                .foregroundStyle(accent)
                .padding(.horizontal, OVSpacing.sm).padding(.vertical, 4)
                .background(Capsule().strokeBorder(accent.opacity(0.4), lineWidth: 1))
        } else {
            base
        }
    }
}

// The shared "where does this conversation stand" control (#652), extracted from
// DraftReviewView.stateControl and QueueView's lightweight reached-out row, which each
// independently rendered this same Confirm/Change branching (#661): an unconfirmed AI-suggested
// state offers Confirm (accept it) or Change; everything else just offers Set a state/Change.
struct ConversationStateControl: View {
    let currentState: ConversationState?
    let stateSource: OutcomeSource?
    // #1139: threaded straight through to the underlying menu (see ConversationStateMenu); nil for
    // every caller except the draft-review row, which sets them so this control reads as clearly its
    // own kind next to the adjacent "Mark…" outcome menu.
    var systemImage: String? = nil
    var accent: Color? = nil
    // #2154: whether THIS surface may offer Confirm. Confirming writes Overture's guess in as fact, and
    // Dan can only rule on that with the message in front of him: "I can't confirm if they want to book
    // without reading the message first" (2026-08-05). The queue row carries not one word of what was
    // written, so it passes false and the guess reads as a statement there, with Confirm offered on the
    // reply screen that shows the message. Change stays either way: saying where a conversation stands is
    // his own assertion, not an endorsement of a reading.
    var offersConfirm: Bool = true
    let onSet: (ConversationState) -> Void
    let onConfirm: () -> Void

    var body: some View {
        if let currentState, stateSource == .auto {
            HStack(spacing: 4) {
                Text(ConversationState.looksLikeNote(currentState)).foregroundStyle(OVColor.inkSoft)
                if offersConfirm {
                    Button("Confirm", action: onConfirm)
                        .buttonStyle(.plain).foregroundStyle(OVColor.forest)
                }
                ConversationStateMenu(currentState: currentState, label: "Change",
                                      systemImage: systemImage, accent: accent, onSet: onSet)
            }
            .font(OVType.meta)
        } else {
            ConversationStateMenu(currentState: currentState,
                                  label: currentState == nil ? "Set a state" : "Change",
                                  systemImage: systemImage, accent: accent, onSet: onSet)
        }
    }
}
