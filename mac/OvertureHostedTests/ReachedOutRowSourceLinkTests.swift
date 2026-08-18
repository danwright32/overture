import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import Overture

// #2816: the rendered half. `RowSourceListingLinkTests` decides what the link IS and pins that both
// surfaces name it in their source; this is the row on screen, in the branch that has a link and in the
// branch that has none.
//
// The empty branch is the one worth rendering. A source can leave a show with no listing URL at all, and
// the failure that ships from a populated-branch-only read is a heading over nothing, a gap, or a dead
// control (L45, and #1547 is this repo's worked example of exactly that).
@MainActor
@Suite("The source link on the reached-out row (#2816)")
struct ReachedOutRowSourceLinkTests {

    private func show(listing: String?) -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-08-01",
                         sourceListingURL: listing, websiteURL: "https://aurorastrings.example",
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sourceIds = ["hall"]
        let r = Recipient(id: "emma@example-hall.example", email: "emma@example-hall.example",
                          name: "Emma", provenance: .act)
        r.sendState = .sent
        r.sentAt = Date(timeIntervalSince1970: 1_000_000)
        p.setRecipients([r])
        p.sentAt = r.sentAt
        return (p, r)
    }

    private func row(listing: String?,
                     calendars: [String: String] = ["hall": "https://example-hall.example/whats-on"]) -> some View {
        let (p, r) = show(listing: listing)
        return QueueView(deepLinkedKey: .constant(nil), deepLinkedKeys: .constant(nil))
            .reachedOutRow((prospect: p, recipient: r, next: Date()), now: Date(), since: nil,
                           sourceCalendars: calendars)
    }

    private func texts(_ view: some View) -> [String] {
        ((try? view.inspect().findAll(ViewType.Text.self)) ?? []).compactMap { try? $0.string() }
    }

    private func links(_ view: some View) -> [ViewInspector.InspectableView<ViewType.Link>] {
        (try? view.inspect().findAll(ViewType.Link.self)) ?? []
    }

    // The defect: an open pitch was a title with no way back to the show's own page.
    @Test func aShowWithAListingOffersTheWayBackToIt() throws {
        let drawn = row(listing: "https://example-hall.example/events/aurora-strings")
        let link = try #require(links(drawn).first)
        #expect(try link.url().absoluteString == "https://example-hall.example/events/aurora-strings")
        #expect(texts(drawn).contains("Source listing"))
    }

    // Decision 1 of the issue's three: the LISTING only. The group website is a second link on a
    // lightweight row, and the whole argument for this one is getting back to THE SHOW.
    @Test func theRowCarriesTheListingAndNotTheGroupWebsite() {
        let drawn = row(listing: "https://example-hall.example/events/aurora-strings")
        #expect(links(drawn).count == 1)
        #expect(!texts(drawn).contains("Group website"))
    }

    // #1680's distinction, which matters more here than on triage: a link that only reaches the source's
    // own calendar says so, so Dan knows before clicking whether it takes him to this show.
    @Test func aListingThatIsOnlyTheSourcesCalendarSaysSoOnTheRow() {
        let drawn = row(listing: "https://example-hall.example/whats-on")
        #expect(texts(drawn).contains("Venue calendar"))
        #expect(!texts(drawn).contains("Source listing"))
    }

    // The branch with no link at all: no link, and no words about one either. Nothing here may draw a
    // heading over an absence.
    @Test func aShowWithNoListingDrawsNoLinkAndNoLabelForOne() {
        let drawn = row(listing: nil)
        #expect(links(drawn).isEmpty)
        #expect(!texts(drawn).contains("Source listing"))
        #expect(!texts(drawn).contains("Venue calendar"))
    }

    // And the row is otherwise the row he already reads, in both branches, so the link is an addition
    // rather than a replacement for anything.
    @Test func theRowStillNamesItsShowInBothBranches() {
        for listing in ["https://example-hall.example/events/aurora-strings", nil] {
            #expect(texts(row(listing: listing)).contains("Aurora Strings"))
        }
    }
}
