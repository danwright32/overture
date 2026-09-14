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
// #2395: the list comes from `ShowOutcome.menu(wasPitched:)`, the one place that decision is made, rather
// than from a vocabulary of this control's own. Passed in rather than looked up here, so the row's own send
// record decides what Dan is offered and this view cannot quietly disagree with the write path about which
// endings are possible.
// #3707: the reply link rides in here rather than on the row. Dan's call, 2026-09-08: most reached-out
// rows will never need it, so it belongs behind a menu he already opens rather than beside the endings at
// rest. It is a parameter and not a predicate read here, so this view never decides who may be asked: the
// row passes nil where the question does not apply, exactly as `outcomes` is passed rather than looked up.
//
// The label above is unchanged, Dan's call in the same session, asked with the alternative in front of
// him: the menu goes on saying "Close this out" and the link sits under a separator beneath the endings.
struct CloseOutMenu: View {
    var outcomes: [ShowOutcome]
    var onLinkReply: (() -> Void)?
    var onChoose: (ShowOutcome) -> Void

    var body: some View {
        Menu {
            ForEach(outcomes, id: \.self) { outcome in
                Button(outcome.label) { onChoose(outcome) }
            }
            // Under a separator, because it is not an ending: everything above closes the pitch and this
            // one says it is still alive. Without the rule the eye reads it as a fifth outcome.
            if let onLinkReply {
                Divider()
                Button(LinkReplyFromAnotherThread.menuLabel) { onLinkReply() }
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
