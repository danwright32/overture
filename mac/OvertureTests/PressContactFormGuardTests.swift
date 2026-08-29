import Testing
import Foundation
import SwiftData

// #1636, the sibling of #1629. That one closed the VENUE half: a contact form on the host room's own
// domain is no longer offered as a way through. PressContactGuard (#722) has the identical shape and had
// the identical gap: it reads a contact's email local part and their stated role and nothing else, so a
// form URL was never examined, and a check returning a press or media page produced a card reading
// "Contact form only" that sends Dan to a press office. The runbook's hard press/media disqualify rule
// (#635) exists precisely to prevent that.
//
// The live example, already in the store on a Bryant Park show:
//   group  Carnegie Hall Citywide: Avery Wilson
//   form   https://www.carnegiehall.org/About/Press/Ticket-and-Media-Guidelines
// Note the venue guard cannot catch this one: the form is on carnegiehall.org while the show's venue is
// Bryant Park, so it is not the ROOM's own form, it is a third party's press office. Only a press rule
// catches it.
//
// WHY THE PATH AND NOT THE WHOLE URL. The email rule matches the LOCAL PART only and ignores the domain,
// so "press@carnegiehall.org" is a press contact while "booking@pressplayrecords.com" is not. The
// faithful analogue for a link is its PATH. Matching the whole URL as a substring, which is what the
// email rule's own `contains` check would do if pointed at one, is actively dangerous: "espresso"
// contains "press" and "multimedia" contains "media".
//
// LIVE-STORE-CLAIM verified=2026-07-27 measure="stored contact form URLs, and how many are a press or media page"
// Measured against every stored contact form on 2026-07-27: 14 forms, of which exactly 1 is a press page.
// The rule below flags that one and leaves the other 13 alone.
@MainActor
@Suite("A press page is not a contact form (#1636)")
struct PressContactFormGuardTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, venue: String = "Bryant Park") -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Carnegie Hall Citywide: Avery Wilson",
                         discipline: "music", venue: venue, performanceDate: "2026-09-18",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "neutral", coverage: "unknown", fitScore: 5,
                         tier: "mid", fitReason: "", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        ctx.insert(p)
        return p
    }

    private func formContact(_ url: String) -> Recipient {
        let r = Recipient(id: url, email: nil, name: "Contact", provenance: .act)
        r.contactFormURL = url
        r.contactMethodRaw = "form_or_dm"
        return r
    }

    // The live row, verbatim.
    @Test func theCarnegiePressPageIsRecognised() {
        #expect(PressContactGuard.looksLikePressContact(
            formURL: "https://www.carnegiehall.org/About/Press/Ticket-and-Media-Guidelines"))
    }

    @Test func aMediaSegmentAloneIsEnough() {
        #expect(PressContactGuard.looksLikePressContact(formURL: "https://example.org/media/enquiries"))
    }

    @Test func aPublicRelationsSegmentIsEnough() {
        #expect(PressContactGuard.looksLikePressContact(
            formURL: "https://example.org/about/public-relations"))
    }

    // Every other form in the live store, which must all stay usable. Without these the rule could pass
    // by flagging everything.
    @Test func theOtherStoredFormsAreLeftAlone() {
        for url in ["https://sorrelmanemagic.com/contact",
                    "https://shop.copeland.band/pages/contact",
                    "https://www.french-american-piano.org/mailing-list",
                    "https://www.goldenclassicalmusicawards.com/contact-us",
                    "https://www.marcribler.com/contact",
                    "https://www.virgileroche.com/"] {
            #expect(!PressContactGuard.looksLikePressContact(formURL: url), "\(url) is a real way through")
        }
    }

    // The brake that makes this safe to ship, and the reason it matches whole path SEGMENTS rather than
    // running the email rule's substring check over the URL.
    @Test func aWordMerelyCONTAININGAKeywordIsNotAPressPage() {
        #expect(!PressContactGuard.looksLikePressContact(formURL: "https://example.com/espresso-bar"))
        #expect(!PressContactGuard.looksLikePressContact(formURL: "https://example.com/multimedia"))
        #expect(!PressContactGuard.looksLikePressContact(formURL: "https://example.com/impressum"))
    }

    // Faithful to the email rule, which reads the local part and ignores the domain: "press@example.org"
    // is a press contact, "booking@pressplayrecords.com" is not.
    @Test func theHostIsIgnoredJustAsTheEmailRuleIgnoresTheDomain() {
        #expect(!PressContactGuard.looksLikePressContact(formURL: "https://pressplayrecords.com/contact"))
    }

    @Test func aFormWithNoPathIsNotAPressPage() {
        #expect(!PressContactGuard.looksLikePressContact(formURL: "https://www.virgileroche.com/"))
    }

    // The behaviour Dan sees: a show whose only route is a press page has no way through to the act.
    @Test func aShowWhoseOnlyFormIsAPressPageReadsAsNoEmailFound() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.setRecipients([formContact("https://www.carnegiehall.org/About/Press/Ticket-and-Media-Guidelines")])

        #expect(p.usableContactFormURLs.isEmpty)
        #expect(p.reachabilityResultFromRecipients == .noEmailFound)
    }

    // #1626 must keep working, and a press page alongside a real one must not take the real one with it.
    @Test func theActsOwnFormSurvivesAlongsideAPressPage() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.setRecipients([formContact("https://www.carnegiehall.org/About/Press/Ticket-and-Media-Guidelines"),
                         formContact("https://www.marcribler.com/contact")])

        #expect(p.usableContactFormURLs == ["https://www.marcribler.com/contact"])
        #expect(p.reachabilityResultFromRecipients == .contactFormOnly)
    }

    // Both readers again (#1629's lesson): the stored verdict and the card have to agree, or the row
    // reads "No email found" while still offering the press page as a link underneath it.
    @Test func theCardDoesNotOfferAPressPageAsALink() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.setRecipients([formContact("https://www.carnegiehall.org/About/Press/Ticket-and-Media-Guidelines")])

        #expect(QueueItem(p).displayedContactForms.isEmpty)
    }
}
