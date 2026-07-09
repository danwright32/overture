import SwiftUI

// The shared "pick a contact's conversation state" control (#111/#652), extracted from
// FollowUpsView.setStateMenu and DraftReviewView.stateMenu, which each independently rendered
// this same Menu (#662), so the two can never drift apart again.
struct ConversationStateMenu: View {
    let currentState: ConversationState?
    let label: String
    let onSet: (ConversationState) -> Void

    var body: some View {
        Menu(label) {
            ForEach(ConversationState.allCases, id: \.self) { s in
                Button {
                    onSet(s)
                } label: {
                    if s == currentState { Label(s.label, systemImage: "checkmark") }
                    else { Text(s.label) }
                }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .font(OVType.meta)
    }
}

// The shared "where does this conversation stand" control (#652), extracted from
// DraftReviewView.stateControl and QueueView's lightweight reached-out row, which each
// independently rendered this same Confirm/Change branching (#661): an unconfirmed AI-suggested
// state offers Confirm (accept it) or Change; everything else just offers Set a state/Change.
struct ConversationStateControl: View {
    let currentState: ConversationState?
    let stateSource: OutcomeSource?
    let onSet: (ConversationState) -> Void
    let onConfirm: () -> Void

    var body: some View {
        if let currentState, stateSource == .auto {
            HStack(spacing: 4) {
                Text("Looks like \(currentState.label.lowercased())").foregroundStyle(OVColor.inkSoft)
                Button("Confirm", action: onConfirm)
                    .buttonStyle(.plain).foregroundStyle(OVColor.forest)
                ConversationStateMenu(currentState: currentState, label: "Change", onSet: onSet)
            }
            .font(OVType.meta)
        } else {
            ConversationStateMenu(currentState: currentState,
                                  label: currentState == nil ? "Set a state" : "Change", onSet: onSet)
        }
    }
}
