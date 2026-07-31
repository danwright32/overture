import Testing
import Foundation
import SwiftData
@testable import Overture

// #1798: a card that reads "No email found" in rust while printing an address directly underneath it.
//
// LIVE-STORE-CLAIM verified=2026-07-31 measure="prospects whose stored reachability result is no_email_found while holding a recipient with a real address, and which guard is holding each one"
// Measured 2026-07-31: exactly one row, Raging of the Shrews at Under St Marks, verdict
// `no_email_found`, recipient `office@frigid.nyc`, with looksLikeVenue 0, looksLikePressContact 0 and
// looksLikeDuplicateContact 1, undismissed.
//
// Three guards can hold an address back from sending (`Recipient.isSendablePending`): the venue guard, the
// press guard, and the duplicate guard. The verdict knew about two of them, so an address held by the
// third was neither sendable nor weak and fell all the way through to "no address at all". #1324 added
// `weakContactOnly` because saying "no email found" over an address claims more than the check measured
// (L11); the duplicate guard, added around the same time, was never added to the set.
//
// The SENTENCE cannot simply be reused, and the measurement above is why: the venue and press guards did
// not fire on this row. `office@frigid.nyc` is FRIGID's own office address, a real presenter contact, held
// only because the same address is already in play on another show at that venue within a few days. A card
// saying "only a venue or press address, not the presenter's own" would be flatly untrue there. So the
// verdict is shared and the sentence varies, which is #1722's pattern and the reason it exists.
@MainActor
@Suite("An address that is held is not an address that is missing (#1798)")
struct HeldAddressIsNotNoAddressTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Raging of the Shrews", performanceDate: "2026-08-14",
                                          venue: "Under St Marks")
        let p = Prospect(naturalKey: key, groupName: "Raging of the Shrews", discipline: "theatre",
                         venue: "Under St Marks", performanceDate: "2026-08-14", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "unknown",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .new)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @discardableResult
    private func addAddress(_ ctx: ModelContext, to p: Prospect, email: String = "office@frigid.nyc",
                            venue: Bool = false, press: Bool = false, duplicate: Bool = false,
                            duplicateDismissed: Bool = false) -> Recipient {
        let r = Recipient(id: email, email: email, name: "FRIGID New York", role: nil,
                          provenance: .presenter, contactMethodRaw: "generic_inbox",
                          contactConfidenceRaw: "medium", contactFormURL: nil, contactSourceURL: nil)
        r.looksLikeVenue = venue
        r.looksLikePressContact = press
        r.looksLikeDuplicateContact = duplicate
        r.looksLikeDuplicateContactDismissed = duplicateDismissed
        p.addRecipient(r)
        try? ctx.save()
        return r
    }

    // THE BUG, on the stored verdict every other surface reads.
    @Test func anAddressHeldOnlyAsADuplicateIsNotReportedAsNoAddress() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        addAddress(ctx, to: p, duplicate: true)

        #expect(p.reachabilityResultFromRecipients != .noEmailFound)
        #expect(p.reachabilityResultFromRecipients == .weakContactOnly)
    }

    // And on the card, which derives its own answer. Two copies of one rule is how the two came to
    // disagree with `isSendablePending` in the same way at the same time, so both go through one
    // definition now.
    @Test func theCardAlsoSeesTheHeldAddress() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        addAddress(ctx, to: p, duplicate: true)

        let items = QueueModel.items(from: [p], now: Date())
        #expect(items.first?.hasWeakContactEmail == true)
    }

    // The sentence Dan reads has to be true of the row that produced it. On the measured row neither the
    // venue nor the press guard fired, so the wording written for those two would be a false claim.
    @Test func theSentenceDoesNotClaimAGuardThatNeverFired() {
        let duplicate = ReachabilityCopy.weakContactHelp(reason: .duplicate).lowercased()
        // The claim that must not appear is about WHAT THE ADDRESS IS. Naming the venue as the place the
        // other show sits is fine and is the point of the sentence, so this asserts the description of the
        // address rather than the mere presence of the word: a cruder check failed this sentence for
        // saying "at this venue", which is where the clash is, not what the address belongs to.
        #expect(!duplicate.contains("press"))
        #expect(!duplicate.contains("venue address"))
        #expect(!duplicate.contains("venue or press"))
        #expect(!duplicate.contains("not the presenter's own"))
        // It says what actually happened, and it is a different sentence from the venue/press one.
        #expect(duplicate != ReachabilityCopy.weakContactHelp(reason: .venueOrPress))
    }

    // The badge word has to be true of the row too: a real presenter address that is merely held is not a
    // weak contact, and a badge saying so would contradict the sentence directly under it.
    @Test func theBadgeDoesNotCallAHeldPresenterAddressWeak() {
        #expect(ReachabilityCopy.weakContactBadge(reason: .duplicate)
                != ReachabilityCopy.weakContactBadge(reason: .venueOrPress))
        #expect(!ReachabilityCopy.weakContactBadge(reason: .duplicate).lowercased().contains("weak"))
    }

    // The wording for the guards that DID have a sentence is untouched, so this is an addition rather than
    // a rewrite of copy Dan already reads.
    @Test func theVenueAndPressWordingIsUnchanged() {
        #expect(ReachabilityCopy.weakContactHelp(reason: .venueOrPress)
                == ReachabilityCopy.weakContactOnlyHelp)
        #expect(ReachabilityCopy.weakContactBadge(reason: .venueOrPress)
                == ReachabilityCopy.weakContactOnlyBadge)
    }

    // FAILURE DIRECTION: dismissing the duplicate flag hands the address back. It was always a real
    // address; the guard was a question, and Dan answering it must not leave the row reading weak.
    @Test func dismissingTheDuplicateFlagMakesTheAddressCountAgain() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        addAddress(ctx, to: p, duplicate: true, duplicateDismissed: true)

        #expect(p.reachabilityResultFromRecipients == .emailFound)
    }

    // FAILURE DIRECTION: a show with no address at all still reports exactly that. The fix must not turn
    // "nothing found" into "something weak", which would be the same overclaim pointing the other way.
    @Test func aShowWithNoAddressStillReportsNoAddress() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)

        #expect(p.reachabilityResultFromRecipients == .noEmailFound)
    }

    // And the venue guard keeps working exactly as it did, so this is one set with three members rather
    // than a replacement of the two that were there.
    @Test func aVenueHeldAddressIsStillWeak() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        addAddress(ctx, to: p, email: "boxoffice@understmarks.example", venue: true)

        #expect(p.reachabilityResultFromRecipients == .weakContactOnly)
    }
}
