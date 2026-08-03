import Testing
import Foundation

// #2023: what a typed "Send to" field means when it holds more than one person.
//
// The reason this is a parser with its own tests rather than a split() at each call site: the string Dan
// types decides a Recipient's IDENTITY, and every downstream rule (reply detection, follow-ups, bounce
// handling, the booking match) keys off it. A field holding "a@x.org, b@y.org" that becomes ONE contact
// whose id is that whole string looks like it worked, sends, and can never match a reply from either
// person.
@Suite("Reading a typed list of addresses (#2023)")
struct EmailAddressListTests {

    // MARK: - What it accepts

    @Test func oneAddressIsOneAddress() {
        #expect(EmailAddressList.parse("olga@bargemusic.org") == .addresses(["olga@bargemusic.org"]))
    }

    @Test func twoAddressesSeparatedByACommaAreBoth() {
        #expect(EmailAddressList.parse("olga@bargemusic.org, mark@bargemusic.org")
                == .addresses(["olga@bargemusic.org", "mark@bargemusic.org"]))
    }

    // Order is the order he typed them, because the first contact is the one the send path offers first.
    @Test func theOrderTypedIsKept() {
        #expect(EmailAddressList.parse("b@x.org, a@x.org") == .addresses(["b@x.org", "a@x.org"]))
    }

    // Outlook and Apple Mail both hand you semicolons when you copy a row of recipients.
    @Test func semicolonsSeparateToo() {
        #expect(EmailAddressList.parse("a@x.org; b@y.org") == .addresses(["a@x.org", "b@y.org"]))
    }

    @Test func aTrailingSeparatorIsForgiven() {
        #expect(EmailAddressList.parse("a@x.org, b@y.org,") == .addresses(["a@x.org", "b@y.org"]))
    }

    @Test func strayWhitespaceAndNewlinesAreTrimmed() {
        #expect(EmailAddressList.parse("  a@x.org ,\n b@y.org  ") == .addresses(["a@x.org", "b@y.org"]))
    }

    // A pasted contact card carries the display name. ReplyDetection already reads this shape when it
    // reads a From header, so refusing it here would refuse something the rest of the app understands.
    @Test func aNameInAngleBracketsYieldsTheAddressInside() {
        #expect(EmailAddressList.parse("Olga Bloom <olga@bargemusic.org>")
                == .addresses(["olga@bargemusic.org"]))
    }

    // The same person twice is one email, not two. Two Recipients cannot both hold that identity anyway,
    // so collapsing here is what stops the second silently vanishing later with no explanation.
    @Test func theSameAddressTwiceCollapsesToOne() {
        #expect(EmailAddressList.parse("a@x.org, A@X.ORG") == .addresses(["a@x.org"]))
    }

    // MARK: - What it refuses, and it must name WHICH piece

    @Test func nothingTypedIsEmptyRatherThanInvalid() {
        #expect(EmailAddressList.parse("   \n ") == .empty)
    }

    @Test func aStringWithNoAtSignIsRefusedByName() {
        #expect(EmailAddressList.parse("call the box office") == .invalid(piece: "call the box office"))
    }

    // The case the issue was filed for: one good address is not a licence to accept the rest.
    @Test func oneGoodAddressAndOneBadRefusesAndNamesTheBadOne() {
        #expect(EmailAddressList.parse("olga@bargemusic.org, mark-at-bargemusic")
                == .invalid(piece: "mark-at-bargemusic"))
    }

    @Test func twoAtSignsInOnePieceIsRefused() {
        #expect(EmailAddressList.parse("a@@x.org") == .invalid(piece: "a@@x.org"))
    }

    @Test func anAddressMissingItsDomainIsRefused() {
        #expect(EmailAddressList.parse("olga@") == .invalid(piece: "olga@"))
    }

    @Test func anAddressMissingItsNameIsRefused() {
        #expect(EmailAddressList.parse("@bargemusic.org") == .invalid(piece: "@bargemusic.org"))
    }

    // Two addresses pasted with a space and no separator at all. Splitting only on commas would let this
    // through as one piece, which is exactly the identity defect in a different disguise.
    @Test func twoAddressesWithNoSeparatorAreRefusedRatherThanTreatedAsOne() {
        #expect(EmailAddressList.parse("a@x.org b@y.org") == .invalid(piece: "a@x.org b@y.org"))
    }

    // A separator with nothing between it and the next one is a typo, not an address.
    @Test func anEmptyPieceBetweenSeparatorsIsRefused() {
        #expect(EmailAddressList.parse("a@x.org,,b@y.org") == .invalid(piece: ""))
    }
}
