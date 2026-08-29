import Testing
import Foundation
import SwiftData

// #2623: the queue card printed the addresses a check found and nothing else, so it could not tell Dan
// that the address he is looking at belongs to somebody other than the act.
//
// The mechanism, measured on a live card: a show billed to one performer read "Unverified email found"
// over a bare address belonging to that performer's musical director. The row held the contact's `name`
// and `role`, both written by the check that found the address, and neither reached the screen. The
// names and the address below are invented; the shape they stand for was measured.
//
// LIVE-STORE-CLAIM verified=2026-08-13 measure="stored contacts on shows at reachabilityResult = email_found"
// Of the 29 shows at `email_found`, a hand grouping of the stored names and roles finds the billed artist
// on some, somebody else on the show on others, and a manager or booking agency on six. Six of the 29 hold
// an address with NO name at all, so the nameless case is common enough that the layout has to read
// correctly without one rather than treating a name as guaranteed.
@MainActor
@Suite("The card says whose address it is printing (#2623)")
struct CardNamesWhoseAddressItIsTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Rosalind Verrier", discipline: "music",
                         venue: "The Green Room 42", performanceDate: "2026-08-17", sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                         fitReason: "", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        ctx.insert(p)
        return p
    }

    private func item(_ ctx: ModelContext, _ recipients: [Recipient]) -> QueueItem {
        let p = show(ctx)
        for r in recipients { p.addRecipient(r) }
        try? ctx.save()
        return QueueItem(p)
    }

    // MARK: what the card carries

    @Test func theAddressCarriesTheNameAndRoleOfWhoeverItBelongsTo() throws {
        let ctx = try context()
        let r = Recipient(id: "marionalcottmusic@example.com", email: "marionalcottmusic@example.com",
                          name: "Marion Alcott", provenance: .performer)
        r.role = "Musical Director"

        let shown = item(ctx, [r]).displayedContactAddresses

        #expect(shown.count == 1)
        #expect(shown.first?.email == "marionalcottmusic@example.com")
        #expect(shown.first?.attribution == "Marion Alcott, Musical Director")
    }

    // Six of the 29 measured shows hold an address with no name. That is not a defect to paper over with
    // a placeholder: the card simply prints the address, exactly as it did before this issue.
    @Test func anamelessAddressCarriesNoAttribution() throws {
        let ctx = try context()
        let r = Recipient(id: "info@thegreenroom42.com", email: "info@thegreenroom42.com",
                          name: nil, provenance: .presenter)

        #expect(item(ctx, [r]).displayedContactAddresses.first?.attribution == nil)
    }

    // The third rendering case: an address printed from the ORGANISATION ledger has no Recipient on this
    // show behind it, so there is no name to show and claiming one would name somebody no check on this
    // show ever found (L75).
    @Test func aninheritedAddressCarriesNoAttribution() throws {
        let ctx = try context()
        let p = show(ctx)
        try? ctx.save()
        var i = QueueItem(p)
        i.inheritedReachability = OrgAnswerLedger.Inherited(result: .emailFound,
                                                            probedAt: Date(timeIntervalSince1970: 1_780_000_000),
                                                            organisation: "Vivace Arts Collective",
                                                            emails: ["hello@vivace.example"])

        let shown = i.displayedContactAddresses

        #expect(shown.map(\.email) == ["hello@vivace.example"])
        #expect(shown.first?.recipientId == nil)
        #expect(shown.first?.attribution == nil)
    }

    // MARK: how the two fields compose

    @Test func aroleIsAppendedToTheNameAndEitherHalfStandsAlone() {
        #expect(QueueItem.DisplayedAddress.attribution(name: "Marion Alcott", role: "Musical Director")
                == "Marion Alcott, Musical Director")
        #expect(QueueItem.DisplayedAddress.attribution(name: "Marion Alcott", role: nil) == "Marion Alcott")
        // A role with no name still answers the question the line exists to answer: whose address is this.
        #expect(QueueItem.DisplayedAddress.attribution(name: nil, role: "Booking Agent") == "Booking Agent")
        #expect(QueueItem.DisplayedAddress.attribution(name: nil, role: nil) == nil)
    }

    // Failure path: a stored blank (the run writing "" or a stray space rather than omitting the field)
    // must read as absent, never as an empty line or a stray comma on the card.
    @Test func awhitespaceOnlyNameOrRoleReadsAsAbsent() {
        #expect(QueueItem.DisplayedAddress.attribution(name: "  ", role: "  ") == nil)
        #expect(QueueItem.DisplayedAddress.attribution(name: "Marion Alcott", role: "   ") == "Marion Alcott")
        #expect(QueueItem.DisplayedAddress.attribution(name: " ", role: "Musical Director") == "Musical Director")
    }

    // The addresses the card prints and the strings it prints them as must stay one list, so a name can
    // never appear beside an address the card is not showing.
    @Test func theplainEmailListStillMatchesTheAttributedOne() throws {
        let ctx = try context()
        let a = Recipient(id: "a@x.example", email: "a@x.example", name: "Ana", provenance: .act)
        let b = Recipient(id: "b@x.example", email: "b@x.example", name: nil, provenance: .act)

        let i = item(ctx, [a, b])

        #expect(i.displayedContactEmails == i.displayedContactAddresses.map(\.email))
        #expect(i.displayedContactAddresses.map(\.attribution) == ["Ana", nil])
    }
}
