import Testing
import Foundation
import SwiftData

// #1629: #1626 made a contact form on the act's own site count as a way through. The check that keeps a
// ROOM's own details out of that was missing.
//
// VenueContactGuard compares an EMAIL's domain against the venue, and has since #388, because "a room's
// own address is never a real contact, not even a named booking person" is the oldest standing rule in
// the product (#368). Nothing did the equivalent for a form URL: usableContactFormURLs excluded only
// login-walled social hosts. So a check that returned the host venue's own booking form produced a card
// reading "Contact form only" pointing Dan straight at the room.
//
// A hole rather than a live defect: in the 2026-07-27 run all of the upgraded rows pointed at the act's
// own domain (jakebergmagic.com, shop.copeland.band, marcribler.com) and none matched its venue. The run
// that would expose it is the next one at a room with a decent website.
//
// The comparison is SHARED with the email guard rather than copied, so one rule decides "is this the
// room's own contact" for both kinds of route and the two cannot drift apart.
@MainActor
@Suite("A room's own contact form is not a way through (#1629)")
struct VenueContactFormGuardTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, venue: String) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "A Recital", discipline: "music",
                         venue: venue, performanceDate: "2026-09-18", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "unknown",
                         profile: "neutral", coverage: "unknown", fitScore: 5, tier: "mid",
                         fitReason: "", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        ctx.insert(p)
        return p
    }

    private func formContact(_ url: String) -> Recipient {
        let r = Recipient(id: url, email: nil, name: "Booking", provenance: .act)
        r.contactFormURL = url
        r.contactMethodRaw = "form_or_dm"
        return r
    }

    // The rule itself, on the same footing as the email version.
    @Test func theGuardRecognisesTheRoomsOwnDomainInAFormURL() {
        #expect(VenueContactGuard.looksLikeVenue(formURL: "https://www.carnegiehall.org/contact",
                                                 venue: "Carnegie Hall"))
    }

    @Test func theGuardLeavesTheActsOwnDomainAlone() {
        #expect(!VenueContactGuard.looksLikeVenue(formURL: "https://marcribler.com/contact",
                                                  venue: "The Cutting Room"))
    }

    // Both routes must agree about the same domain, which is the whole reason the comparison is shared.
    @Test func theFormAndEmailRoutesAgreeAboutOneDomain() {
        let venue = "Carnegie Hall"
        #expect(VenueContactGuard.looksLikeVenue(email: "boxoffice@carnegiehall.org", venue: venue)
                == VenueContactGuard.looksLikeVenue(formURL: "https://carnegiehall.org/contact", venue: venue))
    }

    // The parent building counts too, exactly as it does for an address (#388 resolves the hall to its
    // parent through VenueDisplay): a form on Carnegie's site is the room's whether the show is billed
    // in Weill Recital Hall or on the main stage.
    @Test func theParentBuildingsDomainCountsAsTheRoomsOwn() {
        #expect(VenueContactGuard.looksLikeVenue(formURL: "https://www.carnegiehall.org/contact",
                                                 venue: "Weill Recital Hall, Carnegie Hall"))
    }

    // The same false-positive brake the email guard has: an exact match on the second level domain and a
    // minimum slug length, so a short or generic room name cannot swallow an unrelated act's site.
    @Test func aShortVenueNameDoesNotSwallowAnUnrelatedSite() {
        #expect(!VenueContactGuard.looksLikeVenue(formURL: "https://theq.com/contact", venue: "The Q"))
    }

    @Test func aPartialDomainMatchIsNotTheRoom() {
        #expect(!VenueContactGuard.looksLikeVenue(formURL: "https://carnegiehallmusicians.org/contact",
                                                  venue: "Carnegie Hall"))
    }

    // The behaviour Dan sees. A show whose only route is the room's own form has no way through to the
    // act, so it reads as no email found, which is what he would get if the check had returned the
    // room's email address, and it never points him at the room.
    @Test func aShowWhoseOnlyFormIsTheRoomsReadsAsNoEmailFound() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, venue: "Carnegie Hall")
        p.setRecipients([formContact("https://www.carnegiehall.org/contact")])

        #expect(p.usableContactFormURLs.isEmpty)
        #expect(p.reachabilityResultFromRecipients == .noEmailFound)
    }

    // #1626 must keep working: the act's own form is still a way through. Without this the fix could
    // pass by excluding every form.
    @Test func theActsOwnFormIsStillAWayThrough() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, venue: "The Cutting Room")
        p.setRecipients([formContact("https://marcribler.com/contact")])

        #expect(p.usableContactFormURLs == ["https://marcribler.com/contact"])
        #expect(p.reachabilityResultFromRecipients == .contactFormOnly)
    }

    // Both kinds on one show: the room's is dropped, the act's survives, and the show is still reachable.
    @Test func theActsFormSurvivesAlongsideTheRooms() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, venue: "Carnegie Hall")
        p.setRecipients([formContact("https://www.carnegiehall.org/contact"),
                         formContact("https://marcribler.com/contact")])

        #expect(p.usableContactFormURLs == ["https://marcribler.com/contact"])
        #expect(p.reachabilityResultFromRecipients == .contactFormOnly)
    }

    // The card and the stored verdict have to agree, or the row says "no email found" while still
    // offering the room's form as a link. Two readers, one rule.
    @Test func theCardDoesNotOfferTheRoomsFormAsALink() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, venue: "Carnegie Hall")
        p.setRecipients([formContact("https://www.carnegiehall.org/contact")])

        #expect(QueueItem(p).displayedContactForms.isEmpty)
    }

    @Test func theCardStillOffersTheActsForm() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, venue: "The Cutting Room")
        p.setRecipients([formContact("https://marcribler.com/contact")])

        #expect(QueueItem(p).displayedContactForms.map(\.absoluteString)
                == ["https://marcribler.com/contact"])
    }

    // A show with no venue recorded cannot be compared against one, and must not lose its form on a
    // guess. 145 of 575 untriaged rows carry no listing page at all, so an incomplete row is normal.
    @Test func aShowWithNoVenueKeepsItsForm() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, venue: "")
        p.setRecipients([formContact("https://marcribler.com/contact")])

        #expect(p.usableContactFormURLs == ["https://marcribler.com/contact"])
    }
}
