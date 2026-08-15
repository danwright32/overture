import Testing
import Foundation
import SwiftData

// #2718: put the proposal in front of Dan as DUE WORK he can answer on the row.
//
// His call, 2026-08-14: a quiet question would sit unanswered until the show had been and gone. So it
// joins `DueWork.Counts` rather than sitting silently on a card, because a pill's number is a promise
// about rows and a proposal that appears in Reached out without joining the count gives a number that
// excludes rows the list shows (L16).
//
// A SwiftUI row cannot make a Gmail call, so everything the question needs is stored on the contact.
//
// Every test injects `now` (L130).
@MainActor
@Suite("Asking Dan whether a proposed conversation is theirs (#2718)")
struct ProposedConversationTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        RefusedContactAddress.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let route = "https://www.caseengaines.com/contact"

    private func show(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "54 Sings Shuffle Along", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-09-01", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func formPitch(_ ctx: ModelContext, on p: Prospect) -> Recipient {
        let r = Recipient(id: "form:\(route)", email: nil, name: "Caseen Gaines", provenance: .act)
        r.contactFormURL = route
        r.formOutreachURL = route
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = now.addingTimeInterval(-3 * 86_400)
        r.sentAt = now.addingTimeInterval(-3 * 86_400)
        r.sendState = .sent
        p.addRecipient(r)
        return r
    }

    private func candidate(_ id: String, score: Int = 9,
                           from: String = "caseen.gaines@gmail.com",
                           name: String? = "Caseen Gaines",
                           subject: String = "Re: the anniversary show",
                           thread: String? = nil) -> ProposedConversation.Candidate {
        ProposedConversation.Candidate(messageId: id, threadId: thread ?? "t-\(id)",
                                       fromAddress: from, fromName: name, subject: subject,
                                       sentAt: now.addingTimeInterval(-3600), score: score)
    }

    // MARK: storing a proposal

    @Test("a proposal is stored on the contact, so the row can ask without calling Gmail")
    func aProposalIsStored() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        ProposedConversation.propose(candidate("m1"), on: r, now: now)

        let stored = try #require(ProposedConversation.stored(on: r))
        #expect(stored.messageId == "m1")
        #expect(stored.threadId == "t-m1")
        #expect(stored.fromAddress == "caseen.gaines@gmail.com")
        #expect(stored.fromName == "Caseen Gaines")
        #expect(stored.subject == "Re: the anniversary show")
        #expect(stored.score == 9)
        #expect(r.replyProposedAt == now)
    }

    // WHICH candidate the stored proposal holds, decided rather than left to whichever tick ran last.
    //
    // The FIRST one proposed, held until Dan answers it. The alternative (the highest-scoring one this
    // tick) changes the question under him between reading it and pressing Yes, and what he approves has
    // to be exactly what happens (L64). A better candidate arriving later does not silently replace the
    // one he is looking at.
    @Test("a later, higher-scoring candidate does not replace the proposal Dan is looking at")
    func theFirstProposalIsHeld() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        ProposedConversation.propose(candidate("m1", score: 5), on: r, now: now)

        ProposedConversation.propose(candidate("m2", score: 99), on: r, now: now.addingTimeInterval(1800))

        #expect(ProposedConversation.stored(on: r)?.messageId == "m1")
        #expect(r.replyProposedAt == now, "the question has not changed, so neither has when it was asked")
    }

    // MARK: declines are a set, keyed on the CONVERSATION

    // Keyed on the THREAD, not the message. A decline keyed on the message id re-proposes the same
    // conversation the moment that sender writes again, which on a live conversation is what happens
    // next (L92, L15).
    @Test("declining a proposal declines the whole conversation, not one message on it")
    func decliningDeclinesTheConversation() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        ProposedConversation.propose(candidate("m1", thread: "t1"), on: r, now: now)

        ProposedConversation.decline(on: r)

        #expect(ProposedConversation.stored(on: r) == nil)
        // A NEWER message on the same thread must not come back as a fresh question.
        ProposedConversation.propose(candidate("m2", thread: "t1"), on: r, now: now.addingTimeInterval(60))
        #expect(ProposedConversation.stored(on: r) == nil)
    }

    // A SET, not a slot. `Recipient.dismissedReplyId` is a single slot and that is sufficient there,
    // because an emailed contact has exactly ONE watched thread. Here the search returns many candidates
    // over time, so a slot would let Dan decline A, be offered B, decline B, and meet A again next tick
    // (L131).
    @Test("declining two different conversations keeps both declined")
    func declinesAccumulate() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        ProposedConversation.propose(candidate("a", thread: "t-a"), on: r, now: now)
        ProposedConversation.decline(on: r)
        ProposedConversation.propose(candidate("b", thread: "t-b"), on: r, now: now.addingTimeInterval(60))
        ProposedConversation.decline(on: r)

        ProposedConversation.propose(candidate("a2", thread: "t-a"), on: r, now: now.addingTimeInterval(120))

        #expect(ProposedConversation.stored(on: r) == nil, "the first conversation came back")
    }

    @Test("a conversation Dan has not declined is still proposed")
    func anUndeclinedConversationIsStillProposed() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        ProposedConversation.propose(candidate("a", thread: "t-a"), on: r, now: now)
        ProposedConversation.decline(on: r)

        ProposedConversation.propose(candidate("b", thread: "t-b"), on: r, now: now.addingTimeInterval(60))

        #expect(ProposedConversation.stored(on: r)?.threadId == "t-b")
    }

    // MARK: the three states each get a view

    @Test("a contact with a live proposal is in the proposed state")
    func aLiveProposalHasItsOwnState() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        ProposedConversation.propose(candidate("m1"), on: r, now: now)

        guard case .proposed(let c) = ProposedConversation.state(of: r, now: now) else {
            Issue.record("expected a proposal, got \(ProposedConversation.state(of: r, now: now))"); return
        }
        #expect(c.messageId == "m1")
    }

    @Test("a contact whose candidates were all declined has its own state")
    func allDeclinedHasItsOwnState() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        ProposedConversation.propose(candidate("m1"), on: r, now: now)
        ProposedConversation.decline(on: r)
        r.replyCandidateSearchedAt = now

        #expect(ProposedConversation.state(of: r, now: now) == .allDeclined)
    }

    @Test("a contact attached but not yet answered has its own state")
    func attachedAwaitingAnswerHasItsOwnState() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        r.gmailThreadId = "t1"
        r.conversationAttachedAt = now
        r.replied = true
        r.repliedAt = now

        #expect(ProposedConversation.state(of: r, now: now) == .attachedAwaitingAnswer)
    }

    // L98 on the row: a mailbox read that found nothing and a mailbox never read are different things,
    // and only the first is Overture telling Dan something.
    @Test("read for and nothing found is not the same state as never read for")
    func nothingFoundIsNotNeverSearched() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        #expect(ProposedConversation.state(of: r, now: now) == .none(searched: false))
        r.replyCandidateSearchedAt = now
        #expect(ProposedConversation.state(of: r, now: now) == .none(searched: true))
    }

    // Past the horizon Overture stops READING for new candidates, and the row must stop saying it is
    // looking. Its own state rather than folded into "found nothing yet", because only one of the two
    // means the manual route is now the only way in.
    @Test("past the horizon the row says Overture has stopped looking")
    func pastTheHorizonItSaysSo() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        r.replyCandidateSearchedAt = now
        let wayLater = now.addingTimeInterval(Double(ReplySearchScope.horizonDays + 5) * 86_400)

        #expect(ProposedConversation.state(of: r, now: wayLater) == .stoppedLooking)
    }

    // A question Dan has not answered survives the horizon. Overture stops looking for NEW candidates;
    // it does not withdraw one it already put in front of him.
    @Test("a standing question is not withdrawn when the horizon passes")
    func aStandingQuestionSurvivesTheHorizon() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        ProposedConversation.propose(candidate("m1"), on: r, now: now)
        let wayLater = now.addingTimeInterval(Double(ReplySearchScope.horizonDays + 5) * 86_400)

        guard case .proposed = ProposedConversation.state(of: r, now: wayLater) else {
            Issue.record("the standing question was withdrawn"); return
        }
    }

    // #843, caught by reading the generated inventory cold: the row already says "You told Overture they
    // replied" on the line above, so a second line saying it is still reading the inbox says one thing
    // twice. The manual link stays, because a Gmail thread may still turn up.
    @Test("a pitch Dan has already hand-marked as replied says nothing more about the search")
    func aHandMarkedReplySuppressesTheSearchLine() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        r.replyMarkedByHandAt = now

        #expect(ProposedConversation.state(of: r, now: now) == .notApplicable)
        #expect(ProposedConversation.offersManualLink(r), "linking a Gmail thread is still worth offering")
    }

    @Test("a pitch Overture emailed itself is never asked about")
    func anEmailedPitchIsNotAsked() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = Recipient(id: "them@act.com", email: "them@act.com", provenance: .act)
        r.gmailThreadId = "t1"
        r.gmailMessageId = "<ours@mail.gmail.com>"
        r.sendState = .sent
        p.addRecipient(r)

        #expect(ProposedConversation.state(of: r, now: now) == .notApplicable)
    }

    // MARK: it counts as due work

    // `DueWork.Counts` has exactly two members, both derived from stored state. A proposal that appeared
    // in Reached out WITHOUT joining this would give a pill whose number excludes rows the list shows,
    // which is the promise-about-rows defect that file exists to prevent (L16).
    @Test("a live proposal counts toward the Due pill")
    func aProposalCountsAsDue() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        let before = DueWork.counts(prospects: [p], now: now)
        ProposedConversation.propose(candidate("m1"), on: r, now: now)

        let after = DueWork.counts(prospects: [p], now: now)

        #expect(after.conversationsToConfirm == before.conversationsToConfirm + 1)
        #expect(after.total == before.total + 1)
    }

    @Test("a declined proposal stops counting toward the Due pill")
    func aDeclinedProposalStopsCounting() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        ProposedConversation.propose(candidate("m1"), on: r, now: now)

        ProposedConversation.decline(on: r)

        #expect(DueWork.counts(prospects: [p], now: now).conversationsToConfirm == 0)
    }

    // The count and the rows it promises come from ONE shared predicate, so the pill and the list it
    // opens can never state different numbers (L16).
    @Test("the count and the rows it promises come from the same predicate")
    func theCountAndTheRowsAgree() throws {
        let ctx = ModelContext(try container())
        let a = show(ctx, key: "a"), b = show(ctx, key: "b"), c = show(ctx, key: "c")
        ProposedConversation.propose(candidate("m1"), on: formPitch(ctx, on: a), now: now)
        ProposedConversation.propose(candidate("m2"), on: formPitch(ctx, on: b), now: now)
        formPitch(ctx, on: c)

        let rows = ProposedConversation.dueRecipients(from: [a, b, c])
        let count = DueWork.counts(prospects: [a, b, c], now: now).conversationsToConfirm

        #expect(rows.count == count)
        #expect(Set(rows.map(\.prospect.naturalKey)) == ["a", "b"])
    }

    // MARK: the manual route

    // Dan's explicit ask: "I'll also need a way to tell it about the email if there's a situation where
    // it doesn't propose but I got an email anyway."
    @Test("the manual link control is offered on any hand-sent pitch with no conversation")
    func theManualRouteIsOffered() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        #expect(ProposedConversation.offersManualLink(r))
    }

    @Test("the manual link control is not offered once a conversation is attached")
    func theManualRouteIsNotOfferedOnceLinked() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        r.gmailThreadId = "t1"
        r.conversationAttachedAt = now

        #expect(ProposedConversation.offersManualLink(r) == false)
    }

    @Test("the manual link control is not offered on a pitch Overture emailed")
    func theManualRouteIsNotOfferedOnAnEmailedPitch() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = Recipient(id: "them@act.com", email: "them@act.com", provenance: .act)
        r.sendState = .sent
        p.addRecipient(r)

        #expect(ProposedConversation.offersManualLink(r) == false)
    }

    // MARK: the manual picker still obeys the refusals

    private func inbound(_ id: String, from: String, subject: String,
                         listUnsubscribe: String? = nil) -> GmailReplySearch.InboundMessage {
        GmailReplySearch.InboundMessage(messageId: id, threadId: "t-\(id)",
                                        fromAddress: ReplyDetection.email(from: from),
                                        fromName: ReplyDetection.displayName(from: from),
                                        subject: subject, sentAt: now.addingTimeInterval(-3600),
                                        listUnsubscribe: listUnsubscribe)
    }

    // Picking by hand is Dan overriding the SCORE, a judgement about who is most likely. It is NOT him
    // overriding "never the room's own address" or "never a press desk", which the product has held
    // since #368 and #635. A hand route that skipped those would be a side door into the exact defect
    // those guards exist for.
    //
    // This test was written because a mutation deleting the refusal filter SURVIVED: the claim was in a
    // comment and in nothing else (L1).
    @Test("the manual picker never offers a sender the scorer would refuse")
    func theManualPickerObeysTheRefusals() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        let found = [
            inbound("real", from: "Caseen Gaines <caseen.gaines@gmail.com>", subject: "Re: the show"),
            inbound("room", from: "54 Below <hello@54below.com>", subject: "About your enquiry"),
            inbound("press", from: "press@somewhere.org", subject: "Media guidelines"),
            inbound("bulk", from: "News <news@elsewhere.com>", subject: "This week",
                    listUnsubscribe: "<https://elsewhere.com/u>"),
            inbound("bounce", from: "mailer-daemon@googlemail.com", subject: "Delivery Status"),
        ]

        let offered = ProposedConversation.pickable(found, for: r, on: p,
                                                    selfEmail: "dan@danwrightphotography.com")

        #expect(offered.map(\.messageId) == ["real"])
    }

    // It offers what the AUTOMATIC path would not, which is the whole reason it exists: a message that
    // scored below the floor is still shown, because Dan can recognise a sender the scorer cannot.
    @Test("the manual picker offers a message that scored too low to be proposed on its own")
    func theManualPickerOffersALowScorer() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        let weak = inbound("weak", from: "Sam <sam@somewhereelse.com>", subject: "About the show")

        let offered = ProposedConversation.pickable([weak], for: r, on: p,
                                                    selfEmail: "dan@danwrightphotography.com")

        #expect(offered.map(\.messageId) == ["weak"])
        #expect(ReplyCandidateMatch.judge([weak], for: r, on: p,
                                          selfEmail: "dan@danwrightphotography.com")
                == .nothingLooksLikeThem, "the automatic path would not have backed it")
    }

    @Test("the manual picker does not offer a conversation Dan already declined")
    func theManualPickerDropsDeclinedConversations() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        ProposedConversation.propose(candidate("m1", thread: "t-real"), on: r, now: now)
        ProposedConversation.decline(on: r)
        let found = [inbound("real", from: "Caseen Gaines <caseen.gaines@gmail.com>", subject: "Re: the show")]

        let offered = ProposedConversation.pickable(found, for: r, on: p,
                                                    selfEmail: "dan@danwrightphotography.com")

        #expect(offered.isEmpty, "asking again about one he has already said is not them")
    }

    // MARK: what confirming DOES

    // What Dan approves must be exactly what happens, including WHO it reaches (L64). Confirming does
    // more than link a thread: it writes that address onto the contact, and every future email on this
    // show goes there. A confirm sheet that said only "link this conversation" would be hiding the half
    // that matters.
    @Test("the confirmation says the address will be saved and used")
    func theConfirmationSaysWhatItDoes() {
        let line = ProposedConversationCopy.confirmDetail(address: "caseen.gaines@gmail.com")

        #expect(line.contains("caseen.gaines@gmail.com"))
        #expect(line.lowercased().contains("email"))
    }
}
