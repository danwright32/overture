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
