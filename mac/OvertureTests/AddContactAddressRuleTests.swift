import Testing
import Foundation
import SwiftData

// #2023, second half. Add contact in Review had the same hole as the manual-prep editor: its only gate was
// that the text contained an "@", so pasting "a@x.org, b@y.org" created ONE contact whose identity was
// that whole string. Same defect, same consequence (a reply from either person can never be matched), so
// it is closed in the same change rather than left as the next instance of a class already fixed once.
//
// This control adds ONE person at a time, and its banner names one. So the rule here is exactly one
// address, refused by name otherwise, rather than the several the prep editor now takes.
@MainActor
@Suite("Adding a contact by hand takes one address (#2023)")
struct AddContactAddressRuleTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Bargemusic", discipline: "classical",
                         venue: "Boathouse", performanceDate: "2026-11-14", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "booked", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 9, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .drafted)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @Test func oneAddressIsAddedAsBefore() throws {
        let ctx = try context()
        let p = show(ctx)

        ProspectMutations.addRecipientManually(QueueItem(p), email: "olga@bargemusic.org", name: "Olga",
                                               prospects: [p], context: ctx, feedback: ActionFeedback())

        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.id == "olga@bargemusic.org")
    }

    // The paste this issue is about. Refused rather than quietly stored as one contact identified by both.
    @Test func twoAddressesAtOnceAreRefusedAndNothingIsAdded() throws {
        let ctx = try context()
        let p = show(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.addRecipientManually(QueueItem(p), email: "a@x.org, b@y.org", name: nil,
                                               prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.isEmpty)
        #expect(feedback.message == ActionAck.contactOneAtATime)
    }

    @Test func aStringThatIsNotAnAddressIsRefusedByName() throws {
        let ctx = try context()
        let p = show(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.addRecipientManually(QueueItem(p), email: "ring them", name: nil,
                                               prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.isEmpty)
        // #2629: the refusal names what the control ACCEPTS, which is a route now, not only an address.
        #expect(feedback.message == ActionAck.contactBadRoute("ring them"))
    }

    @Test func anEmptyFieldSaysWhatIsMissing() throws {
        let ctx = try context()
        let p = show(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.addRecipientManually(QueueItem(p), email: "   ", name: nil,
                                               prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.isEmpty)
        #expect(feedback.message == ActionAck.contactNeedsRoute)
    }

    // A stray separator in front of one address is a typo, not a second person. Saying "one at a time"
    // here would name a mistake he did not make.
    @Test func aStraySeparatorSaysTheAddressIsBlankRatherThanClaimingHeTypedTwo() throws {
        let ctx = try context()
        let p = show(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.addRecipientManually(QueueItem(p), email: ",,olga@bargemusic.org", name: nil,
                                               prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.isEmpty)
        #expect(feedback.message == ActionAck.contactBlankAddress)
    }

    // The button and the refusal are one rule, the same way the prep editor's Save is: a control that
    // looks enabled can never be refused, and a refusal can never name something the control did not gate
    // on. `single` is what the button asks.
    @Test func whatTheAddButtonAllowsIsExactlyWhatTheMutationAccepts() {
        #expect(EmailAddressList.single("olga@bargemusic.org") == "olga@bargemusic.org")
        #expect(EmailAddressList.single("Olga <olga@bargemusic.org>") == "olga@bargemusic.org")
        #expect(EmailAddressList.single("a@x.org, b@y.org") == nil)
        #expect(EmailAddressList.single("ring them") == nil)
        #expect(EmailAddressList.single("") == nil)
        // The same address twice is still one person, so the control need not refuse it.
        #expect(EmailAddressList.single("a@x.org, A@X.ORG") == "a@x.org")
    }
}
