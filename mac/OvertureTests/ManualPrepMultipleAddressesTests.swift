import Testing
import Foundation
import SwiftData

// #2023: a hand-written email that needs to reach more than one person.
//
// The shape is one email per person, each on its own Gmail thread, so a reply matches back to whoever it
// came from. What this suite holds is that naming several people in the editor produces exactly that, and
// that a string which cannot be read as addresses is refused BEFORE anything is written rather than
// stored as a single contact whose identity is the whole string.
@MainActor
@Suite("Prepping by hand for several people (#2023)")
struct ManualPrepMultipleAddressesTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func kept(_ ctx: ModelContext, status: ReviewStatus = .queued) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Bargemusic", discipline: "classical",
                         venue: "Boathouse", performanceDate: "2026-11-14", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "booked", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 9, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: status)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // MARK: - Several people

    @Test func twoAddressesBecomeTwoContactsBothWaitingToBeSent() throws {
        let ctx = try context()
        let p = kept(ctx)

        ProspectMutations.prepManually(QueueItem(p),
                                       email: "olga@bargemusic.org, mark@bargemusic.org", name: nil,
                                       subject: "Your November dates",
                                       body: "Are the November dates set yet?",
                                       prospects: [p], context: ctx, feedback: ActionFeedback())

        #expect(p.status == .drafted)
        #expect(p.recipients.count == 2)
        #expect(Set(p.recipients.map(\.id)) == ["olga@bargemusic.org", "mark@bargemusic.org"])
        #expect(p.recipients.allSatisfy { $0.sendState == .pending })
        #expect(p.recipients.allSatisfy { $0.provenance == .manual })
    }

    // The words are written once and shared, which is what a person naming two people at one organisation
    // means. Only WHO it goes to multiplies.
    @Test func everyContactSharesTheOneDraftHeWrote() throws {
        let ctx = try context()
        let p = kept(ctx)

        ProspectMutations.prepManually(QueueItem(p), email: "a@x.org; b@y.org", name: nil,
                                       subject: "Your November dates", body: "One paragraph.",
                                       prospects: [p], context: ctx, feedback: ActionFeedback())

        #expect(p.draftSubject == "Your November dates")
        #expect(p.draftBody == "One paragraph.")
        #expect(p.draftWrittenByDan)
        #expect(p.recipients.count == 2)
    }

    // One of the two is already a live contact on this show. That one is left exactly as it is (the
    // existing rule), and the person beside it must still be created rather than lost with it.
    @Test func anAddressAlreadyOnTheShowDoesNotSwallowItsSibling() throws {
        let ctx = try context()
        let p = kept(ctx)
        p.addRecipient(Recipient(id: "olga@bargemusic.org", email: "olga@bargemusic.org", provenance: .act))
        try ctx.save()

        ProspectMutations.prepManually(QueueItem(p),
                                       email: "olga@bargemusic.org, mark@bargemusic.org", name: nil,
                                       subject: "s", body: "b",
                                       prospects: [p], context: ctx, feedback: ActionFeedback())

        #expect(p.recipients.count == 2)
        #expect(Set(p.recipients.map(\.id)) == ["olga@bargemusic.org", "mark@bargemusic.org"])
        // The one that was already there keeps the provenance it arrived with.
        #expect(p.recipients.first { $0.id == "olga@bargemusic.org" }?.provenance == .act)
        #expect(p.recipients.first { $0.id == "mark@bargemusic.org" }?.provenance == .manual)
        #expect(p.status == .drafted)
    }

    // MARK: - Failure paths: nothing written, and it says which piece is wrong

    @Test func aStringThatIsNotAnAddressIsRefusedAndNothingIsWritten() throws {
        let ctx = try context()
        let p = kept(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.prepManually(QueueItem(p), email: "call the box office", name: nil,
                                       subject: "s", body: "b",
                                       prospects: [p], context: ctx, feedback: feedback)

        #expect(p.status == .queued)
        #expect(p.recipients.isEmpty)
        #expect(p.draftBody == nil)
        #expect(!p.draftWrittenByDan)
        #expect(feedback.message == ActionAck.manualPrepBadAddress("call the box office"))
    }

    // The case this issue was filed for: one good address does not buy the bad one a pass, and the
    // refusal names the piece that is wrong rather than leaving him to guess which.
    @Test func oneGoodAddressAndOneBadWritesNothingAtAll() throws {
        let ctx = try context()
        let p = kept(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.prepManually(QueueItem(p),
                                       email: "olga@bargemusic.org, mark-at-bargemusic", name: nil,
                                       subject: "s", body: "b",
                                       prospects: [p], context: ctx, feedback: feedback)

        // Not one half-applied contact for the address that WAS good.
        #expect(p.recipients.isEmpty)
        #expect(p.status == .queued)
        #expect(p.draftBody == nil)
        #expect(feedback.message == ActionAck.manualPrepBadAddress("mark-at-bargemusic"))
    }

    // The defect itself, stated as a rule that cannot come back: whatever is typed, no contact may end up
    // identified by a string holding a separator. That identity is what reply detection, follow-ups,
    // bounce handling and the booking match all key off.
    @Test func noContactIsEverIdentifiedByAWholeTypedList() throws {
        let ctx = try context()
        for (index, typed) in ["a@x.org, b@y.org",
                               "a@x.org; b@y.org",
                               "a@x.org,b@y.org,c@z.org",
                               "Olga <olga@x.org>, Mark <mark@y.org>"].enumerated() {
            let p = kept(ctx)
            p.naturalKey = "k\(index)"
            ProspectMutations.prepManually(QueueItem(p), email: typed, name: nil,
                                           subject: "s", body: "b",
                                           prospects: [p], context: ctx, feedback: ActionFeedback())
            for recipient in p.recipients {
                #expect(!recipient.id.contains(","), "id from \(typed): \(recipient.id)")
                #expect(!recipient.id.contains(";"), "id from \(typed): \(recipient.id)")
                #expect(!recipient.id.contains(" "), "id from \(typed): \(recipient.id)")
                #expect(recipient.id.filter { $0 == "@" }.count == 1, "id from \(typed): \(recipient.id)")
            }
        }
    }

    // MARK: - The Save button and the refusal are one rule

    @Test func theSaveButtonIsGatedOnTheSameAddressRuleTheRefusalUses() {
        #expect(!ManualPrepEditing.canSave(email: "olga@bargemusic.org, nope", body: "b"))
        #expect(ManualPrepEditing.refusal(email: "olga@bargemusic.org, nope", body: "b")
                == ActionAck.manualPrepBadAddress("nope"))

        #expect(ManualPrepEditing.canSave(email: "olga@bargemusic.org, mark@bargemusic.org", body: "b"))
        #expect(ManualPrepEditing.refusal(email: "olga@bargemusic.org, mark@bargemusic.org", body: "b") == nil)
    }

    // An extra separator has no address in it to name, so it gets its own sentence rather than one
    // reading "  is not an email address".
    @Test func anExtraSeparatorSaysSoRatherThanNamingAnEmptyAddress() {
        #expect(ManualPrepEditing.refusal(email: "a@x.org,,b@y.org", body: "b")
                == ActionAck.manualPrepExtraSeparator)
        #expect(!ManualPrepEditing.canSave(email: "a@x.org,,b@y.org", body: "b"))
    }

    // MARK: - Saying what is about to happen (L64)

    // Dan, looking at the shipped sheet (2026-08-03): "wait I thought we just shipped the ability to email
    // multiple people?" It was there and working, and nothing on screen said so, which for a field that
    // looks exactly like a single-address box is the same as not having shipped it. So the line under the
    // field is never empty: it either INVITES the second address or CONFIRMS what the ones typed will do.
    @Test func theFieldAlwaysSaysSomething() {
        let hint = "Separate several addresses with commas to email more than one person."
        #expect(ManualPrepCopy.addressFieldNote(for: "") == hint)
        #expect(ManualPrepCopy.addressFieldNote(for: "olga@bargemusic.org") == hint)
        // Still the invitation while what he has typed cannot yet be read as addresses: the count note
        // would be a claim about contacts that are not going to be created.
        #expect(ManualPrepCopy.addressFieldNote(for: "olga@") == hint)
    }

    // Once there are two, the hint has done its job and the line says what will actually happen instead.
    // Showing both at once would be the #843 defect: the second line telling him what the first just did.
    @Test func theInvitationGivesWayToWhatWillHappen() {
        #expect(ManualPrepCopy.addressFieldNote(for: "a@x.org, b@y.org")
                == "This adds 2 contacts, and each one gets its own separate email.")
        #expect(ManualPrepCopy.addressFieldNote(for: "a@x.org, b@y.org, c@z.org")
                == "This adds 3 contacts, and each one gets its own separate email.")
    }

    @Test func theSheetSaysHowManyContactsItWillCreateOnlyWhenThereIsMoreThanOne() {
        #expect(ManualPrepCopy.recipientCountNote(for: "") == nil)
        #expect(ManualPrepCopy.recipientCountNote(for: "olga@bargemusic.org") == nil)
        #expect(ManualPrepCopy.recipientCountNote(for: "not an address") == nil)
        #expect(ManualPrepCopy.recipientCountNote(for: "a@x.org, b@y.org")
                == "This adds 2 contacts, and each one gets its own separate email.")
        #expect(ManualPrepCopy.recipientCountNote(for: "a@x.org, b@y.org, c@z.org")
                == "This adds 3 contacts, and each one gets its own separate email.")
    }
}
