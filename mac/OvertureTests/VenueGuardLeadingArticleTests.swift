import Testing
import Foundation

// #2743: the venue guard misses a room whose stored name begins with an article.
//
// `VenueContactGuard` compares the SLUGGED venue name against the domain's second-level label, exactly.
// Slugging keeps every letter and number and drops everything else, so "The Green Room 42" slugs to
// `thegreenroom42` while its own domain gives `greenroom42`. The two are unequal and the guard, which
// exists to keep a room's own address out of the product (#368, the oldest standing rule in it), does
// not fire.
//
// MEASURED on the live Release store 2026-08-14: 16 of 144 distinct venues begin with an article, and
// The Green Room 42 is the room behind FOUR of Dan's five open form pitches. So this is the common case,
// not an edge.
//
// It is also L144 in its own words: the guard's existing tests all pass, because every one of them was
// written with a venue whose name carries no article. Seeing a guard fail on a fixture you chose is not
// the same as it firing on the values it actually meets.
@MainActor
@Suite("The venue guard and a leading article (#2743)")
struct VenueGuardLeadingArticleTests {

    // MARK: the case this was filed for

    @Test("the room behind four of Dan's five open form pitches is caught")
    func theGreenRoom42IsCaught() {
        #expect(VenueContactGuard.looksLikeVenue(email: "hello@greenroom42.com",
                                                 venue: "The Green Room 42"))
    }

    @Test("and its own booking form is caught too, on the same comparison")
    func theGreenRoom42FormIsCaught() {
        #expect(VenueContactGuard.looksLikeVenue(formURL: "https://greenroom42.com/private-events",
                                                 venue: "The Green Room 42"))
    }

    // Every live venue name that begins with an article, taken from the store rather than invented, each
    // paired with the domain that room would plausibly own. The ones whose domain is NOT simply the name
    // minus the article are listed in the second table below, so this test says what it actually covers
    // rather than implying the change fixes every article venue.
    @Test("a room whose domain is its name without the article is caught")
    func liveArticleVenuesAreCaught() {
        let cases: [(venue: String, domain: String)] = [
            ("The Green Room 42", "greenroom42.com"),
            ("The Joyce Theater", "joycetheater.org"),
            ("The Players Theatre", "playerstheatre.com"),
            ("The Phillips Collection", "phillipscollection.org"),
            ("The Kosciuszko Foundation", "kosciuszkofoundation.org"),
            ("The Space at Irondale", "spaceatirondale.org"),
        ]
        for c in cases {
            #expect(VenueContactGuard.looksLikeVenue(email: "info@\(c.domain)", venue: c.venue),
                    "\(c.venue) against \(c.domain)")
        }
    }

    // MARK: what it still does NOT catch, said out loud

    // The change compares the name with its article removed. It does not, and must not, start matching
    // loosely: a room whose domain is a DIFFERENT string from its name is still missed, and that is the
    // deliberate limit rather than an oversight. The guard's exactness is what keeps it from swallowing
    // unrelated sites, which is written into the guard itself.
    @Test("a room whose domain is not simply its name minus the article is still missed")
    func theRemainingGapIsNamed() {
        // Measured from the live store: these are article venues whose real domains carry extra words.
        #expect(VenueContactGuard.looksLikeVenue(email: "info@thecuttingroomnyc.com",
                                                 venue: "The Cutting Room") == false)
        #expect(VenueContactGuard.looksLikeVenue(email: "info@thetanknyc.org",
                                                 venue: "The Tank") == false)
    }

    // The length floor still applies to the DERIVED name, not only the stored one. Without that, "The
    // Tank" would reduce to a four-letter word and start matching inside unrelated domains, which is
    // exactly what the floor exists to prevent.
    @Test("a short name behind an article does not become a loose match")
    func theLengthFloorSurvivesTheArticle() {
        #expect(VenueContactGuard.looksLikeVenue(email: "hello@tank.com", venue: "The Tank") == false)
        #expect(VenueContactGuard.looksLikeVenue(email: "hello@cell.org", venue: "the cell") == false)
    }

    // MARK: where the fix actually has teeth

    // MEASURED before shipping, which is the point of L144 and the reason this section exists: on the
    // live store, across all 93 recipients that have an address on a show with a venue, this guard fires
    // ZERO times both before and after the change. It has nothing to catch there, because the runbook's
    // own "never the venue" rule already keeps a room's address from becoming a stored contact.
    //
    // Where a room's own address CAN genuinely arrive is the inbound path #2714 added: a message in Dan's
    // mailbox, proposed as a possible reply. That is a stranger's mail rather than a scouted contact, so
    // nothing upstream has filtered it, and it is exactly the case #2714's own note said the venue guard
    // was failing to cover. This is the assertion that the fix reaches it.
    //
    // Note the message deliberately carries NO `List-Unsubscribe`: the bulk-mail refusal would catch a
    // newsletter anyway, so a test with one would pass whether this guard worked or not.
    @Test("a message from the room's own address is refused as a reply candidate, with no bulk header")
    func theRoomsOwnAddressIsRefusedInbound() {
        let m = GmailReplySearch.InboundMessage(
            messageId: "m", threadId: "t", fromAddress: "booking@greenroom42.com",
            fromName: "The Green Room 42", subject: "About your enquiry",
            sentAt: Date(timeIntervalSince1970: 1_786_000_000), listUnsubscribe: nil)

        #expect(ReplyCandidateMatch.refusal(for: m, venue: "The Green Room 42",
                                            selfEmail: "dan@danwrightphotography.com") == .theRoomsOwn)
    }

    // MARK: nothing that worked before stops working

    @Test("a room with no article is caught exactly as before")
    func aRoomWithNoArticleIsUnchanged() {
        #expect(VenueContactGuard.looksLikeVenue(email: "hello@bargemusic.org", venue: "Bargemusic"))
        #expect(VenueContactGuard.looksLikeVenue(email: "press@carnegiehall.org", venue: "Carnegie Hall"))
    }

    @Test("an unrelated address is still not the room's")
    func anUnrelatedAddressIsStillNotTheRoom() {
        #expect(VenueContactGuard.looksLikeVenue(email: "corin.hale@example.com",
                                                 venue: "The Green Room 42") == false)
        #expect(VenueContactGuard.looksLikeVenue(email: "perri@perrivale.example",
                                                 venue: "The Green Room 42") == false)
    }

    // The article is only stripped from the FRONT. A room whose name merely contains one is untouched,
    // or "Theatre for a New Audience" would start matching on a fragment of itself.
    @Test("an article inside the name is not stripped")
    func anInteriorArticleIsNotStripped() {
        #expect(VenueContactGuard.looksLikeVenue(email: "hello@atrenaudience.org",
                                                 venue: "Theatre for a New Audience") == false)
        #expect(VenueContactGuard.looksLikeVenue(email: "hello@theatreforanewaudience.org",
                                                 venue: "Theatre for a New Audience"))
    }

    // Only an ARTICLE is dropped, never just "the first word". A mutation that dropped the first word
    // whatever it was left every test green, because nothing asserted the difference, and the cost of
    // getting it wrong is a false positive rather than a miss: "Kaufman Music Center" would reduce to
    // "Music Center" and start flagging an unrelated organisation's address as the room's own, which
    // would hold back a real contact Dan could have pitched.
    @Test("the first word is dropped only when it is an article")
    func onlyAnArticleIsDropped() {
        #expect(VenueContactGuard.looksLikeVenue(email: "info@musiccenter.org",
                                                 venue: "Kaufman Music Center") == false)
        #expect(VenueContactGuard.looksLikeVenue(email: "info@concerthall.org",
                                                 venue: "Merkin Concert Hall") == false)
        // And the room's own full name still is.
        #expect(VenueContactGuard.looksLikeVenue(email: "info@kaufmanmusiccenter.org",
                                                 venue: "Kaufman Music Center"))
    }

    // "Theatre" begins with the letters of "the", and a guard that stripped a PREFIX rather than a WORD
    // would reduce it to "atre" and start matching on that. Slugging removes the spaces, so the word
    // boundary has to be taken from the name BEFORE it is slugged.
    @Test("a name that merely starts with those three letters is not cut")
    func aWordStartingWithTheIsNotCut() {
        #expect(VenueContactGuard.looksLikeVenue(email: "hello@atrerow.com", venue: "Theatre Row") == false)
        #expect(VenueContactGuard.looksLikeVenue(email: "hello@theatrerow.com", venue: "Theatre Row"))
    }
}
