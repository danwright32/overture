import SwiftUI

// #2417: the row a show shows while it leaves the queue because Dan recorded an ending.
//
// Its whole job is to appear INSTANTLY, in place of the row he just acted on, so the screen answers on
// the press rather than after the write. The write and the queue rebuild behind it take a quarter of a
// second at the store's present size (measured 2026-08-12: 273 ms for 888 rows) and grow with the store,
// and a control that does nothing visible for that long reads as broken and gets pressed again. The
// close-out menu is the one place an ending is recorded, so a second press lands on a row that has
// already moved (L44).
//
// Deliberately NOT SendDelightRow, which is what a SEND departs through. That row draws a gold seal and
// a gold line, and the endings recorded here are mostly "no response" and "they passed": the same
// celebration on those reads as the app congratulating him on a rejection. Gold is reserved for what he
// can act on, so this says only that the show is on its way out, in the same words the card used.
struct ClosedOutDepartureRow: View {
    let item: QueueItem

    var body: some View {
        HStack(alignment: .center, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.groupName).font(OVType.groupName).foregroundStyle(OVColor.inkSoft)
                if let venue = item.venue, !venue.isEmpty {
                    Text(venue).font(OVType.body).foregroundStyle(OVColor.inkSoft)
                }
            }
            Spacer(minLength: OVSpacing.md)
        }
        .padding(.vertical, OVSpacing.sm)
        // Dimmed rather than drawn attention to: this row is on its way out, and the eye belongs on
        // what is still in the queue.
        .opacity(0.55)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.groupName), closed out")
    }
}
