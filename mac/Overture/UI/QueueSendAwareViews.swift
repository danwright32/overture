import SwiftUI

// #1922: the two views that READ what a send is doing, so QueueView does not.
//
// QueueView's body derives the entire store on its first line, so any read of the send's transient state
// from there means a send re-derives every prospect in the store to animate one card. Both views below exist purely
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
    @ViewBuilder let content: (QueueModel.DateGroup, [String: DepartureReason]) -> Content

    var body: some View {
        // Read once, here. Every splice decision below is made from this one value, and the keys travel
        // down as a plain dictionary so nothing further down reads the object again.
        let departing = sendState.departing
        // #2417: one dictionary holds the snapshot and its reason together, so this is a plain projection
        // rather than a fold reconciling two sources that could disagree about which rows are leaving.
        let departureReasons = sendState.departures.mapValues { $0.reason }
        LazyVStack(alignment: .leading, spacing: OVSpacing.xl) {
            header()
            ForEach(QueueModel.groups(groups, withDeparting: departing)) { group in
                content(group, departureReasons)
            }
        }
        .scrollTargetLayout()
    }
}

// #2417/#2644: one row on the Reached Out list, and the two transient things that change what it draws:
// a send of its own in flight, and whether it is on its way out.
//
// This list needs its own view because it is NOT the date-grouped list. The two are alternatives in
// QueueView's body, never both on screen, and only the date-grouped one goes through QueueDateGroups.
// Wiring the close-out control into that splice therefore did nothing on the stage the control actually
// lives on, which is the whole reason this exists.
//
// It needs no splice of its own, and that is the useful difference. A send has already dropped its row
// from the store's answer by the time it departs, so the date-grouped list must put a snapshot back. A
// close-out marks the departure BEFORE the write, so the row is still in this list and only has to be
// DRAWN differently. It leaves on its own when the rebuild lands.
//
// BOTH facts are handed down by this ONE view, deliberately, rather than by nesting a departure reader
// inside a send reader. They are read from the same object, for the same row, to decide the same
// question (what this row draws this second), and two wrappers would be two readers to keep in step
// where one will do. It is not QueueSendAwareRow because that one is used INSIDE the card body on the
// date-grouped list, which is below the departure decision, so a departure handed there could never be
// acted on.
//
// It reads sendState here and hands finished values into a closure, rather than taking a built view,
// for the same reason QueueDateGroups does: a view built at the call site is assembled inside QueueView's
// body, which is the cost that arrangement exists to remove.
struct ReachedOutSendAwareRow<Content: View>: View {
    let sendState: SendProgressState
    let key: String
    @ViewBuilder let content: (_ sendingSince: Date?, _ departure: Departure?) -> Content

    var body: some View {
        // The pairing itself lives on SendProgressState, where a test can reach it: putting the snapshot
        // and the reason in step is a rule, and a rule decided in a view body is one only a source-text
        // guard can watch, which is a guard that passes on the words rather than the behaviour.
        content(sendState.sendingSince(key), sendState.departure(key))
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
