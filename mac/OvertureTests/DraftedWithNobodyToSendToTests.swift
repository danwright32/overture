import Testing
import Foundation
import SwiftData

// #2674: a show sitting at `drafted` with zero contacts is its own dead end, and nothing said so.
//
// Measured on the live Release store 2026-08-13: prospect 879, four days from its date, status
// `drafted`, contacts 0, draft body and subject both present. Dan had deleted the contacts by hand,
// wanting to add the producer instead (#2629), and the draft Prep wrote for the deleted people stayed.
//
// `drafted` is a promise that the next thing to do is review and send. That row cannot be sent to
// anybody, so it occupied a stage whose action is unavailable, and the stage's count included it. After
// #2664 the badge is honest about the missing route, which makes the contradiction SHARPER rather than
// softer: the card could say there is no way in while the show sat in the stage that exists to send one.
// That is L67 (a detection rendered as a label rather than blocking the action it appears in) and L45
// (a record matching a stage whose work cannot be done).
//
// DAN'S CALL, 2026-08-23: it STAYS at drafted, and the product says the stage cannot be worked. Nothing
// moves behind his back and no paid AI draft is thrown away; what changes is that the row and the
// stage's own number stop pretending the work is available. The two alternatives he was offered were
// falling back to kept with the draft kept, and falling back with it discarded.
@MainActor
@Suite("A drafted show with nobody to send to says so (#2674)")
struct DraftedWithNobodyToSendToTests {

    private func show(contacts: Int, status: ReviewStatus = .drafted, hasDraft: Bool = true) -> Prospect {
        let p = Prospect(naturalKey: "shuffle", groupName: "54 Sings Shuffle Along", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-12-01", sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: status)
        if hasDraft { p.draftBody = "Hello."; p.draftSubject = "Photography" }
        p.setRecipients((0..<contacts).map {
            Recipient(id: "c\($0)@example.com", email: "c\($0)@example.com", name: "C\($0)",
                      provenance: .act)
        })
        return p
    }

    // MARK: - The rule

    @Test func adraftedShowWithNoContactsIsADeadEnd() {
        #expect(DraftedDeadEnd.hasNobodyToSendTo(show(contacts: 0)))
    }

    @Test func adraftedShowWithAContactIsNot() {
        #expect(!DraftedDeadEnd.hasNobodyToSendTo(show(contacts: 1)))
    }

    // Only at `drafted`. A kept show with no contacts is waiting on a Prep run to find one, which is
    // that stage's ordinary state and not a dead end at all; saying it there would fire on the common
    // case and be ignored (L93).
    @Test func ashowAtAnEarlierStageWithNoContactsIsNotADeadEnd() {
        #expect(!DraftedDeadEnd.hasNobodyToSendTo(show(contacts: 0, status: .queued, hasDraft: false)))
        #expect(!DraftedDeadEnd.hasNobodyToSendTo(show(contacts: 0, status: .new, hasDraft: false)))
    }

    // #2674's third open question: is this the same rule as a show that never HAD a contact? It is, and
    // deliberately. What makes the row a dead end is where it sits and what it can do now, not how it got
    // there, and a rule that asked how would need a history the row does not carry.
    @Test func ashowThatNeverHadAContactIsTheSameDeadEnd() {
        #expect(DraftedDeadEnd.hasNobodyToSendTo(show(contacts: 0, hasDraft: false)))
    }

    // MARK: - The stage's own number

    // The count keeps the row, which is Dan's call, and says how many of its rows cannot be worked. A
    // number that quietly included them was the half of this defect nothing could see from a card.
    @Test func thereviewPillNamesHowManyCannotBeWorked() {
        let status = AgentRoster.statuses(
            AgentInputs(toTriage: 0, keptToPrep: 0, toReview: 3, readyToSend: 0, gmailConnected: true,
                        sendErrors: 0, followUpsDue: 0, reviewDeadEnds: 2)
        ).first { $0.name == "Review" }!

        #expect(status.count == 3, "the stage stopped counting a row Dan chose to leave in it")
        #expect(status.detail.contains("2"), "the pill says nothing about the rows it cannot work")
    }

    @Test func thereviewPillSaysNothingExtraWhenEveryRowCanBeWorked() {
        let status = AgentRoster.statuses(
            AgentInputs(toTriage: 0, keptToPrep: 0, toReview: 3, readyToSend: 0, gmailConnected: true,
                        sendErrors: 0, followUpsDue: 0, reviewDeadEnds: 0)
        ).first { $0.name == "Review" }!

        #expect(status.detail == "3 to review")
    }

    // MARK: - Built is not wired (L3)

    @Test func thecardSaysItAndTheRosterCountsIt() {
        let card = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        #expect(!card.isEmpty)
        #expect(card.contains("DraftedDeadEndCopy.line"),
                "a drafted show with nobody to send to renders nothing saying so (#2674)")
        // The CONDITION as well as the sentence. A constant inside a branch that can never be taken is
        // still in the file, so the assertion above stayed green with the condition replaced by `false`
        // (L135). Measured: mutate.sh said SURVIVED.
        #expect(SourceGuardHelper.containsCode(
            "if item.status == .drafted, item.contacts.isEmpty {", in: card),
                "the line is in the file and nothing can reach it (#2674, L3)")

        let roster = SourceGuardHelper.source("Overture/Domain/AgentRoster.swift")
        #expect(SourceGuardHelper.containsCode("reviewDeadEnds: ", in: roster),
                "the Review pill never counts the rows its stage cannot work")
    }
}
