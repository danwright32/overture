import SwiftUI

// #2112 / #2224: the control that ENDS a pitch, on the row Dan stands on.
//
// Its own view rather than an inline Menu, for the reason `ConversationStateControl` is: the reached-out
// row's trailing column is governed by a stated ceiling (#2167, `ReachedOutRowSlots`), and that rule is
// enforced by counting the view-producing constructs in the column. A Menu spelled out inline puts its
// items' own `Button`s in that column, so the count would read four controls where a person sees one.
// One named view is one slot, which is both what a person sees and what the guard counts.
//
// #1139: deliberately NOT the conversation-state menu's twin. That one says where a live conversation
// stands; this one says the pitch is over. Two identical-looking dropdowns setting genuinely different
// things is the defect that rule exists for, so this carries the outcome icon and the outcome accent.
struct CloseOutMenu: View {
    var onChoose: (ReachedOutClose.Outcome) -> Void

    var body: some View {
        Menu {
            ForEach(ReachedOutClose.Outcome.allCases, id: \.self) { outcome in
                Button(outcome.label) { onChoose(outcome) }
            }
        } label: {
            Label(ReachedOutClose.menuLabel, systemImage: ContactRowControls.Kind.outcome.icon)
                .font(OVType.meta)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tint(ContactRowControls.Kind.outcome.accent.color)
    }
}
