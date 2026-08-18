import SwiftUI

// #2816: the way back to the show's own page, on the stages that draw a ROW rather than a card.
//
// Dan, reading a Reached out row: "I'll need to add a source link to this page so I can see the source on
// demand." What to do about an open pitch turns on the show itself (what it is, how long it runs, who else
// is on the bill, whether the listing has changed since the pitch went out), and once the pitch was sent
// the show was a title with no way back. The only web address the row carried was the contact ROUTE, which
// is the one place he does not need to go back to.
//
// ONE view rather than the same six lines in each row that needs it: three surfaces work an open pitch
// (Reached out, and both of the Follow-ups rows), and a second copy is how the colour override below comes
// to be present on two of them and missing on the third.
//
// The LISTING only, never the group website. The card's strip (`ProspectRowView.links`) carries both
// because it is a card with room for them; the argument for this one is getting back to THE SHOW, and a
// second link on a lightweight row is one more than the row can carry.
struct RowSourceLink: View {
    let listingURL: String?
    /// The sources this show was actually found on, so the label below is decided against their calendars
    /// and never against a source the show was never on (#1825).
    let sourceIds: [String]
    /// The watchlist's sourceId-to-calendar table, built once by the list and handed down (#1121).
    let calendars: [String: String]

    var body: some View {
        // The empty branch is the whole of what a show with no listing URL draws: nothing. No heading over
        // an absence, no reserved gap, no dead control (L45, #1547). A source can and does leave a show
        // without one.
        if let link = QueueModel.rowListingLink(listingURL: listingURL, sourceIds: sourceIds,
                                                calendars: calendars) {
            // #1680's label rides along: a link that only reaches the source's own calendar says so, which
            // matters more here than on triage. A link labelled as this show's page that lands on a
            // calendar of forty other shows answers none of the questions an open pitch turns on.
            Link(link.label, destination: link.url)
                // #358: `.tint` does not recolor a Link's own text on macOS (it affects control accents),
                // so without this the link ships in bright system blue against the forest and gold
                // palette, reading as more important than a secondary reference link is.
                .font(OVType.tag)
                .foregroundStyle(OVColor.forestText)
        }
    }
}
