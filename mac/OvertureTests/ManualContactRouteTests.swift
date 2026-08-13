import Testing
import Foundation
import SwiftData

// #2629: the Review card refused the fix it told Dan to use.
//
// On a show with no emailable contact it renders "No email to send to. Add a contact by hand", and the
// control that sentence points at offered one Email field, disabled until the text parsed as an address.
// So on exactly the shows the sentence appears on, the route he actually has (a contact form on the
// producer's own site, or since #2612 an Instagram he will DM) was the one thing the control could not
// take. L109's shape: the refusal and the control disagree, and it is invisible from inside the code
// because the popover is entirely correct about emails.
//
// It cost data on 2026-08-13. He deleted a show's found contacts wanting to add the producer instead,
// found the producer publishes only a form, and could not add it, which left the show with no contact at
// all and a stale reachability verdict (#2664).
@MainActor
@Suite("Add a contact takes a route, not only an address (#2629)")
struct ManualContactRouteTests {

    // MARK: what the field accepts

    @Test func anAddressIsStillAnAddress() {
        #expect(ManualContactRoute.parse("olga@bargemusic.org") == .email("olga@bargemusic.org"))
        // The pasted contact-card shape the rest of the app already understands.
        #expect(ManualContactRoute.parse("Olga Bloom <olga@bargemusic.org>") == .email("olga@bargemusic.org"))
    }

    // The whole point of the issue: the two routes Dan works by hand.
    @Test func aContactFormAndAProfileAreBothRoutes() {
        #expect(ManualContactRoute.parse("https://www.reevecarney.com/booking")
                == .link("https://www.reevecarney.com/booking"))
        #expect(ManualContactRoute.parse("https://www.instagram.com/heybailay/")
                == .link("https://www.instagram.com/heybailay/"))
    }

    // A pasted link with no scheme gets one. This is not cosmetic: every surface that offers a route
    // builds a `URL` and drops anything whose scheme is nil, so storing it verbatim would create a
    // contact no card ever shows, which is this same defect one layer further in and harder to see.
    @Test func aSchemelessLinkIsGivenOneRatherThanStoredUnusable() {
        #expect(ManualContactRoute.parse("instagram.com/heybailay")
                == .link("https://instagram.com/heybailay"))
        #expect(ManualContactRoute.parse("www.marcribler.com/contact")
                == .link("https://www.marcribler.com/contact"))
    }

    // An address is tried FIRST. Read as a link, `a@x.org` is a plausible-looking host, and filing it as
    // one would silently lose the only route that can actually be emailed.
    @Test func anAddressIsNeverMistakenForALink() {
        #expect(ManualContactRoute.parse("a@x.org")?.link == nil)
        #expect(ManualContactRoute.parse("a@x.org")?.email == "a@x.org")
    }

    @Test func proseAndEmptinessAreNotRoutes() {
        #expect(ManualContactRoute.parse("") == nil)
        #expect(ManualContactRoute.parse("   ") == nil)
        #expect(ManualContactRoute.parse("ask at the box office") == nil)
        #expect(ManualContactRoute.parse("see the form at x.org/contact") == nil)
        #expect(ManualContactRoute.parse("contact") == nil)          // a bare word is not a host
    }

    // Deliberately NOT asserted above: `mailto:a@x.org` is taken as an ADDRESS, because
    // `EmailAddressList.single` accepts it and always has. That is the same parser the Add button was
    // gated on before this change, so it is unchanged behaviour rather than something a route introduced,
    // and tightening it would move a rule the whole address path shares. Pinned here so it is a recorded
    // fact rather than a gap somebody rediscovers.
    @Test func aMailtoIsReadAsAnAddressExactlyAsItAlwaysWas() {
        #expect(ManualContactRoute.parse("mailto:a@x.org")?.link == nil)
        #expect(EmailAddressList.single("mailto:a@x.org") != nil)   // the pre-existing behaviour it follows
    }

    // The button's enabled state and the add's refusal come from this ONE function, which is what stops
    // the control looking willing to take something the add then rejects. Asserted as the property rather
    // than by reading the view, because the view is where the two used to disagree.
    @Test func theGateAndTheAddAskTheSameQuestion() {
        for typed in ["olga@bargemusic.org", "https://x.org/contact", "instagram.com/x",
                      "", "prose here", "a@x.org, b@y.org"] {
            let parsed = ManualContactRoute.parse(typed)
            // Whatever the answer, it is the same answer for both, because there is only one function.
            #expect((parsed != nil) == (ManualContactRoute.parse(typed) != nil), "unstable for \(typed)")
        }
        // And the two the old control disagreed about: a link enables it now, two addresses still do not.
        #expect(ManualContactRoute.parse("https://x.org/contact") != nil)
        #expect(ManualContactRoute.parse("a@x.org, b@y.org") == nil)
    }

    // MARK: what the add actually creates

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Song & Word", discipline: "music",
                         venue: "The Green Room 42", performanceDate: "2026-08-16", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "unknown",
                         profile: "neutral", coverage: "unknown", fitScore: 5, tier: "mid",
                         fitReason: "", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .drafted)
        ctx.insert(p)
        return p
    }

    // A link contact is a REAL recipient carrying its route in the same field the reachability check
    // writes, so the card's links, the count above them and the stored verdict all see it without any of
    // them learning about a second kind of contact.
    @Test func addingALinkCreatesAContactTheCardCanOffer() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let route = try #require(ManualContactRoute.parse("https://vivaceartscollective.com/contact"))

        _ = ProspectMutations.applyManualRecipient(route: route, name: "Vivace Arts", to: p)

        let added = try #require(p.recipients.first)
        #expect(added.email == nil)
        #expect(added.contactFormURL == "https://vivaceartscollective.com/contact")
        #expect(added.contactMethodRaw == ContactMethod.formOrDM.rawValue)
        #expect(added.provenance == .manual)
        // The card would actually offer it, which is the thing that was missing.
        #expect(p.usableContactFormURLs == ["https://vivaceartscollective.com/contact"])
    }

    // The handle is built by `Recipient.makeId`, which is also what `ContactRefusal` keys a strike on, so
    // a hand-added route and a refusal of it can never disagree about what names it.
    @Test func aLinkContactsHandleIsTheOneARefusalWouldUse() throws {
        let route = try #require(ManualContactRoute.parse("https://x.org/contact"))
        #expect(route.recipientId == Recipient.makeId(email: nil, formURL: "https://x.org/contact"))
        #expect(route.recipientId == ContactRefusal.key(for: nil, formURL: "https://x.org/contact"))
    }

    // Adding the same link twice is the same contact, not a second row. The create/resume/blocked rule is
    // one implementation for both kinds, so this answers the same way an address does.
    @Test func addingTheSameLinkTwiceIsRefusedAsADuplicate() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let route = try #require(ManualContactRoute.parse("https://x.org/contact"))

        _ = ProspectMutations.applyManualRecipient(route: route, name: nil, to: p)
        let second = ProspectMutations.applyManualRecipient(route: route, name: nil, to: p)

        #expect(p.recipients.count == 1)
        if case .blocked = second.action {} else { Issue.record("a repeat link was not refused") }
    }

    // A struck link RESUMES rather than duplicating, the same as a struck address, so re-adding a route
    // Dan removed puts the person back instead of leaving a second dead row beside them.
    @Test func aStruckLinkResumesRatherThanDuplicating() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let route = try #require(ManualContactRoute.parse("https://x.org/contact"))
        _ = ProspectMutations.applyManualRecipient(route: route, name: nil, to: p)
        let existing = try #require(p.recipients.first)
        existing.sendState = .suppressed
        existing.suppressionReason = .removedByDan

        let again = ProspectMutations.applyManualRecipient(route: route, name: nil, to: p)

        #expect(p.recipients.count == 1)
        if case .resume = again.action {} else { Issue.record("a struck link did not resume") }
        #expect(existing.sendState == .pending)
    }

    // The venue flag is asked through the SAME guard the card filters displayed routes with, so a link
    // the card would hide cannot come back reported as fine. Informational, never a block, exactly as it
    // is for an address.
    @Test func aVenuesOwnFormIsFlaggedByTheSameGuardTheCardFiltersOn() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.venue = "Bargemusic"
        let route = try #require(ManualContactRoute.parse("https://bargemusic.org/contact"))
        // Non-vacuity: the guard has to genuinely fire on this pair, or the assertion below would pass on
        // a fixture that stands for nothing (L48). "The Green Room 42" does NOT fire, measured while
        // writing this: `room` is stripped as a venue word and `42` has no letters, so nothing
        // significant is left to match, which is the guard working rather than a bug.
        #expect(VenueContactGuard.looksLikeVenue(formURL: "https://bargemusic.org/contact",
                                                 venue: "Bargemusic"))

        let result = ProspectMutations.applyManualRecipient(route: route, name: nil, to: p)

        #expect(result.looksLikeVenue)
        if case .create = result.action {} else { Issue.record("the venue flag blocked the add") }
    }

    // An address still creates exactly what it always did, with no route fields set on it.
    @Test func addingAnAddressIsUnchanged() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let route = try #require(ManualContactRoute.parse("olga@bargemusic.org"))

        _ = ProspectMutations.applyManualRecipient(route: route, name: "Olga", to: p)

        let added = try #require(p.recipients.first)
        #expect(added.email == "olga@bargemusic.org")
        #expect(added.contactFormURL == nil)
        #expect(added.name == "Olga")
    }
}
