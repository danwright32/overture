import Testing
import Foundation
import SwiftData

// #2958. `QueueItem.reachableContactCount` counted a contact as reachable whenever the card would offer
// its link, and after #2938 that includes a social profile the run itself marked NAME MATCH ONLY. So a
// guess counted toward the "N found, M reachable" promise while the pill directly above it said the
// profile was not confirmed.
//
// THE DECISION THIS FOLLOWS ALREADY EXISTS, so this is applying a rule rather than making one. #2912
// settled it for `Prospect.socialRouteURLs`, in that property's own words: such a list "is what makes
// the show read as reachable (the stored verdict, the fit score, the organisation ledger, and whether
// Dan can record a DM he sent by hand), and every one of those is Overture ASSERTING that a way in
// exists. An account carrying the right name and nothing tying it to this show cannot support that
// claim. The CARD still shows the handle, marked, because looking at it costs Dan seconds."
//
// A COUNT is exactly such an assertion: it is a promise about what the rows hold (L16). So it follows
// the same rule, and the handle stays on the card, marked, exactly as before.
//
// LIVE-STORE-CLAIM verified=2026-09-01 measure="recipients flagged nameMatchOnly, how many carry a URL and no address, and how many of those sit on a social host"
// Measured 2026-09-01 against a WAL inclusive copy: 22 recipients are flagged `nameMatchOnly`, all 22
// carry a URL and no address, and 19 of those sit on a social host. So 19 rows were being counted as a
// way in by a number whose own app already refuses them as a route.
@MainActor
@Suite("An unconfirmed handle is not a reachable contact (#2958)")
struct UnconfirmedHandleIsNotAReachableContactTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func item(_ ctx: ModelContext, _ recipients: [Recipient]) -> QueueItem {
        let p = Prospect(naturalKey: "k", groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-04-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "neutral",
                         coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        p.setRecipients(recipients)
        return QueueItem(p)
    }

    private func contact(_ id: String, email: String? = nil, form: String? = nil,
                         nameMatchOnly: Bool = false) -> Recipient {
        let r = Recipient(id: id, email: email, name: "Kestrel Quartet", provenance: .act)
        r.contactFormURL = form
        r.nameMatchOnly = nameMatchOnly
        return r
    }

    // The defect exactly, in the shape 19 live rows hold.
    @Test func aNameMatchOnlyProfileIsNotCountedAsAWayIn() throws {
        let ctx = ModelContext(try container())
        let q = item(ctx, [contact("a", form: "https://instagram.com/kestrelquartet", nameMatchOnly: true)])

        #expect(q.contacts.count == 1, "the handle is still ON the card")
        #expect(q.reachableContactCount == 0, "and is not counted as a way in")
    }

    // A confirmed profile still counts, or the fix would remove the whole route rather than the guess.
    @Test func aConfirmedProfileStillCounts() throws {
        let ctx = ModelContext(try container())
        let q = item(ctx, [contact("a", form: "https://instagram.com/kestrelquartet")])
        #expect(q.reachableContactCount == 1)
    }

    // An ADDRESS is a different route, so a name-match-only flag does not withdraw it. The flag says the
    // run could not tie the PROFILE to this show; it says nothing about an address it also found.
    @Test func anAddressStillCountsEvenWhenTheProfileIsAGuess() throws {
        let ctx = ModelContext(try container())
        let q = item(ctx, [contact("a", email: "booking@kestrelquartet.example",
                                   form: "https://instagram.com/kestrelquartet", nameMatchOnly: true)])
        #expect(q.reachableContactCount == 1)
    }

    // The count agrees with the VERDICT, which is the invariant this is really protecting: the badge and
    // the number must answer from one list (L16). A show whose only contact is an unconfirmed handle
    // reads as no way in on both.
    @Test func theCountAndTheVerdictAgreeOnAnUnconfirmedHandle() throws {
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k2", groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-04-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "neutral",
                         coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        p.setRecipients([contact("a", form: "https://instagram.com/kestrelquartet", nameMatchOnly: true)])

        #expect(p.reachabilityResultFromRecipients == .noEmailFound, "the verdict already refuses it")
        #expect(QueueItem(p).reachableContactCount == 0, "and now the count does too")
    }

    // A NON-social form carrying the flag is deliberately still counted, and this pins that rather than
    // leaving it to be discovered. `Prospect.usableContactFormURLs` does not test `nameMatchOnly`, so
    // such a row reads as `contactFormOnly` and its card offers the form: excluding it from the count
    // alone would make the number contradict the badge, which is the defect being fixed pointing the
    // other way. Whether that list should test the flag too is a separate question about the VERDICT.
    @Test func aNonSocialFormWithTheFlagStillCountsAndSaysWhy() throws {
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k3", groupName: "Kestrel Quartet", discipline: "music",
                         venue: "Rowan Hall", performanceDate: "2027-04-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "neutral",
                         coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        p.setRecipients([contact("a", form: "https://kestrelquartet.example/contact", nameMatchOnly: true)])

        #expect(p.reachabilityResultFromRecipients == .contactFormOnly)
        #expect(QueueItem(p).reachableContactCount == 1, "so the count and the badge still agree")
    }
}
