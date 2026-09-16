import Testing
import Foundation

// #3603: the order a show's contacts are listed and sent in, stated once.
//
// Contacts used to reach every list sorted by `sendOrderRank` with the RECIPIENT ID as the tie-break,
// and the id is `Recipient.makeId`'s output: the canonical address when there is one, the literal
// "form:" plus the URL when there is not. On a self-produced show every performer shares rank 0, so
// the id alone decided, and "form:" precedes any address from g to z. Measured on the live store
// 2026-08-30: four performer contacts, three ids beginning "form:" and one address beginning "s", so
// all three contacts that CANNOT receive the email sorted above the one that can, for no reason
// anybody chose.
@Suite("Contact send order")
struct SendOrderTests {
    private func contact(_ id: String, email: String? = nil,
                         provenance: RecipientProvenance = .performer) -> Recipient {
        Recipient(id: id, email: email, provenance: provenance)
    }

    // The measured shape, and the id spelling is the point: "someone@…" sorts AFTER "form:…"
    // alphabetically, so an order that came out right here could not have come from the id.
    @Test func aContactWhoCanReceiveTheEmailPrecedesOneWhoCannot() {
        let form = contact("form:https://example.com/contact")
        let addressed = contact("someone@example.com", email: "someone@example.com")
        #expect(Recipient.inSendOrder([form, addressed]).map(\.id) == [addressed.id, form.id])
        // Asked the other way round too, so the answer is the rule rather than the input order.
        #expect(Recipient.inSendOrder([addressed, form]).map(\.id) == [addressed.id, form.id])
    }

    // The same rule where the id ordering already agreed with it, so the fix is not merely the old
    // accident reversed.
    @Test func theRuleHoldsWhereTheIdOrderingAlreadyAgreed() {
        let form = contact("form:https://example.com/contact")
        let addressed = contact("aaa@example.com", email: "aaa@example.com")
        #expect(Recipient.inSendOrder([form, addressed]).map(\.id) == [addressed.id, form.id])
    }

    // Receivability breaks a TIE; it does not outrank the ladder. The #366/#368 order (target the act
    // or performer, the presenter only after) is untouched, so a performer with no address still
    // precedes a presenter who has one.
    @Test func theProvenanceLadderStillDecidesFirst() {
        let performerForm = contact("form:https://example.com/contact", provenance: .performer)
        let presenter = contact("presenter@example.com", email: "presenter@example.com",
                                provenance: .presenter)
        #expect(Recipient.inSendOrder([presenter, performerForm]).map(\.id)
                == [performerForm.id, presenter.id])
    }

    // The last key, stated rather than emergent: two contacts that can both receive it are ordered by
    // id, which is the canonical address, so the list is stable run to run (SwiftData to-many is
    // unordered, so something has to decide).
    @Test func twoContactsThatCanBothReceiveAreOrderedByAddress() {
        let a = contact("aaa@example.com", email: "aaa@example.com")
        let z = contact("zzz@example.com", email: "zzz@example.com")
        #expect(Recipient.inSendOrder([z, a]).map(\.id) == [a.id, z.id])
    }

    // An empty string is not an address. Without this the receivability key would answer yes for a
    // contact holding `""`, which is exactly the value every other reachability predicate here is
    // careful to reject (`hasUnguardedAddress`, `offersSendModeChoice`).
    @Test func anEmptyAddressIsNotAnAddress() {
        let blank = contact("form:https://example.com/contact", email: "")
        let addressed = contact("someone@example.com", email: "someone@example.com")
        #expect(Recipient.inSendOrder([blank, addressed]).map(\.id) == [addressed.id, blank.id])
    }

    // The class, not the instance. The comparator was written out at SIX call sites (the queue card's
    // contact list, SendService, three in SendGroup, one in FormOutreach), which is six things to drift
    // and six places a change to the order has to be remembered (L263, L370). It lives in one place
    // now, and this is what keeps it there.
    @Test func nothingReimplementsTheComparator() {
        let files = AppSourceWalk.appFiles()
        // Names rather than whole files, so a failure names the offenders instead of printing the
        // source of every one of them (L351: the first line of a failure is the part that survives).
        let inlined = files.filter { file in
            guard file.name != "Recipient.swift" else { return false }
            return SwiftSource.scannableLines(in: file.text).contains { $0.code.contains("sendOrderRank") }
        }.map(\.name).sorted()
        #expect(inlined.isEmpty, Comment(rawValue:
            "these files read sendOrderRank themselves instead of asking Recipient.inSendOrder, so "
            + "the send order now has \(inlined.count + 1) definitions that can drift apart: "
            + inlined.joined(separator: ", ")))
    }
}
