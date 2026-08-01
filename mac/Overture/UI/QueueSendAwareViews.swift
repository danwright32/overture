import SwiftUI

// #1922: the two views that READ what a send is doing, so QueueView does not.
//
// QueueView's body derives the entire store on its first line, so any read of the send's transient state
// from there means a send re-derives all 724 prospects to animate one card. Both views below exist purely
// to move that read below the derivation: each takes the state object (never a value read at the call
// site, which would be the same dependency by another route, #1916) and hands finished values into a
// content closure it runs itself.

// The queue's date list, with the just-sent cards spliced back in.
//
// A fully sent show leaves the store's answer at once, so the card playing the leaving delight is a
// snapshot of a row the queue no longer offers, and something has to put it back. Doing that inside the
// derivation is what made a send expensive; doing it here, over groups already built, costs one pass over
// rows that are already in memory.
//
// The content closure is a closure rather than a built view for the reason QueueScrollHolder's is (#1774):
// a view built at the call site would be assembled inside QueueView's body on every send.
// It owns the LazyVStack rather than sitting inside QueueView's, and that is load bearing: a custom view
// between a lazy stack and its ForEach is a single child to that stack, so every card in the queue would
// be realized at once. That would trade a per-send cost for a per-render one several times worse.
// `.scrollTargetLayout()` rides on the stack here for the same reason, so the date groups stay the scroll
// targets QueueScrollHolder pins across a rebuild (#976).
struct QueueDateGroups<Header: View, Content: View>: View {
    let groups: [QueueModel.DateGroup]
    let sendState: SendProgressState
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: (QueueModel.DateGroup, Set<String>) -> Content

    var body: some View {
        // Read once, here. Every splice decision below is made from this one value, and the keys travel
        // down as a plain set so nothing further down reads the object again.
        let departing = sendState.departing
        LazyVStack(alignment: .leading, spacing: OVSpacing.xl) {
            header()
            ForEach(QueueModel.groups(groups, withDeparting: departing)) { group in
                content(group, Set(departing.keys))
            }
        }
        .scrollTargetLayout()
    }
}

// One card, and the three things about it that a send changes: whether it is the show a jump is marking,
// when its own send started, and when a reply to one of its contacts started.
//
// The reply lookup travels as a closure deliberately: it is read inside the contact's own row, so a reply
// going out redraws that contact rather than the whole card.
struct QueueSendAwareRow<Content: View>: View {
    let key: String
    let sendState: SendProgressState
    @ViewBuilder let content: (_ highlightedKey: String?,
                               _ sendingSince: Date?,
                               _ replySince: @escaping (String) -> Date?) -> Content

    var body: some View {
        content(sendState.highlighted,
                sendState.sendingSince(key),
                { recipientId in sendState.replySendingSince(recipientId) })
    }
}
