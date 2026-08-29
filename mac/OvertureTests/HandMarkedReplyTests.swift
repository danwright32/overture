import Testing
import Foundation
import SwiftData

// #2711: a pitch sent as a social DM (#2612) can be answered inside Instagram, and that answer will never
// exist in Gmail. Until now the product offered nothing to do about it: Dan could record that a show
// ENDED (`ReachedOutClose`) but not that a conversation had STARTED, so everything between the pitch and
// the ending was unrecordable, and the funnel filed a show that really got an answer as "no response"
// (L90).
//
// The mark writes the same fields a DETECTED reply writes, through the same path rather than a second
// one, so every downstream reader behaves identically: the pause that stops Overture emailing the rest of
// the show's contacts underneath a live conversation, the unhandled-reply badge, the decide clock, and
// #16's outcome reporting.
//
// What it must NOT do is pretend to be a detected reply. There are no words, no message id and no thread,
// so anything that would show the reply's text has to say what actually happened instead of rendering an
// empty message box (L10, L11).
@MainActor
@Suite("Hand-marked reply")
struct HandMarkedReplyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A show reachable only through the act's Instagram, pitched as a DM and recorded by hand. No
    // address, no thread, no message id: the channel Overture cannot watch.
    private func dmPitched(_ ctx: ModelContext, route: String = "https://instagram.com/auroraquartet")
    -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "Aurora|2026-09-01", groupName: "Aurora Quartet", discipline: "music",
                         venue: "Jalopy", performanceDate: "2026-09-01", sourceListingURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        p.draftSubject = "Photographing Aurora Quartet at Jalopy."
        p.draftBody = "Hello,"
        ctx.insert(p)
        let r = Recipient(id: Recipient.makeId(email: nil, formURL: route)!, email: nil,
                          name: "Aurora Quartet", provenance: .act,
                          contactMethodRaw: ContactMethod.formOrDM.rawValue, contactFormURL: route)
        p.setRecipients([r])
        p.recordFormOutreach(r, now: now.addingTimeInterval(-10 * 86_400), formURL: route)
        return (p, r)
    }

    // MARK: who may be marked

    // Only where Overture genuinely cannot watch. An emailed contact has a thread and reply detection
    // already answers this question, so a hand mark there would be a second writer racing the first.
    @Test func theMarkIsOfferedOnlyWhereOvertureCannotWatch() throws {
        let ctx = ModelContext(try container())
        let (_, dm) = dmPitched(ctx)

        #expect(HandMarkedReply.isOffered(dm))
        // Attach a conversation (#2715) and Overture can watch it, so the hand mark steps aside.
        dm.gmailThreadId = "thread-abc"
        #expect(!HandMarkedReply.isOffered(dm))
    }

    // Nothing to record a reply to. A contact that was never pitched cannot have answered.
    //
    // #3069: the unpitched state is BUILT here rather than reached by undoing a pitch. This used to call
    // `Prospect.undoFormOutreach`, which was a convenient way to get there and is gone: it belonged to a
    // "take back a recorded form pitch" direction no screen could reach, and Dan's call (2026-08-22) was
    // that a recorded form pitch is final. What the test is about is the state, not the route to it.
    @Test func anUnpitchedContactCannotBeMarked() throws {
        let ctx = ModelContext(try container())
        let (_, r) = dmPitched(ctx)
        r.formOutreachRecordedAt = nil
        r.outreachChannelRaw = nil
        r.sendState = .pending
        r.sentAt = nil

        #expect(!HandMarkedReply.isOffered(r))
    }

    // And it is not offered twice. A row already carrying a reply, hand-marked or detected, has nothing
    // left for this control to do, and a control that keeps offering itself after being pressed reads as
    // broken (L44).
    @Test func aContactThatAlreadyRepliedIsNotOfferedTheMarkAgain() throws {
        let ctx = ModelContext(try container())
        let (p, r) = dmPitched(ctx)

        #expect(HandMarkedReply.mark(r, in: p, now: now))
        #expect(!HandMarkedReply.isOffered(r))
    }

    // MARK: what the mark writes

    // The whole point: the same fields a detected reply writes, so every reader downstream behaves the
    // same. Asserted against the fields rather than against a second code path, because the two agreeing
    // is the requirement.
    @Test func theMarkWritesWhatADetectedReplyWrites() throws {
        let ctx = ModelContext(try container())
        let (p, r) = dmPitched(ctx)

        #expect(HandMarkedReply.mark(r, in: p, now: now))

        #expect(r.replied)
        #expect(r.repliedAt == now)
        #expect(r.replyArrivedAt == now)
        #expect(r.hasUnhandledReply)
        // And it says it was made by hand, so a marked reply is never mistaken for one Overture read.
        #expect(r.replyMarkedByHandAt == now)
    }

    // It deliberately writes NOTHING that would claim a message exists. A fabricated id or an empty
    // string in place of the words would be a claim no check ever measured (L11), and `lastReplyId` in
    // particular is what detection compares a NEWER message against.
    @Test func theMarkInventsNoMessage() throws {
        let ctx = ModelContext(try container())
        let (p, r) = dmPitched(ctx)

        #expect(HandMarkedReply.mark(r, in: p, now: now))

        #expect(r.lastReplyText == nil)
        #expect(r.lastReplyId == nil)
        #expect(r.inboundReplyMessageId == nil)
        #expect(r.replyFromAddress == nil)
        #expect(r.replyAudience == nil)
        #expect(r.gmailThreadId == nil)
    }

    // The reason this matters beyond tidiness. `ReplyService` pauses a show's still-unsent contacts on a
    // reply so Overture does not go on pitching the rest of them underneath a conversation Dan is already
    // having. A DM reply triggered none of that, so the colleagues kept getting cold pitches.
    @Test func theMarkPausesTheShowsOtherContacts() throws {
        let ctx = ModelContext(try container())
        let (p, r) = dmPitched(ctx)
        let colleague = Recipient(id: "boxoffice@jalopy.example", email: "boxoffice@jalopy.example",
                                  provenance: .presenter)
        p.addRecipient(colleague)
        #expect(colleague.isSendablePending)

        #expect(HandMarkedReply.mark(r, in: p, now: now))

        #expect(colleague.pausedByReply)
        #expect(!colleague.isSendablePending)
    }

    // A contact Dan stood down who then writes back is back in play, exactly as `reopenOnReply` already
    // decides for a detected reply. Through that one function rather than by assigning the fields here,
    // because the rule has to hold wherever a reply is recorded (#1840).
    @Test func theMarkReopensAStoodDownContact() throws {
        let ctx = ModelContext(try container())
        let (p, r) = dmPitched(ctx)
        r.resolution = .stoodDown

        #expect(HandMarkedReply.mark(r, in: p, now: now))

        #expect(r.resolution == nil)
        // Recorded, because the undo has to put it back and nothing else remembers it (L5).
        #expect(r.replyMarkClearedStandDown)
    }

    // Assume it runs twice. A second press must not move the recorded date, which is what the decide
    // clock counts from and what #16 attributes an outcome to.
    @Test func markingTwiceDoesNotMoveTheDate() throws {
        let ctx = ModelContext(try container())
        let (p, r) = dmPitched(ctx)

        #expect(HandMarkedReply.mark(r, in: p, now: now))
        #expect(!HandMarkedReply.mark(r, in: p, now: now.addingTimeInterval(3_600)))
        #expect(r.repliedAt == now)
    }

    // MARK: the undo

    // A misclick has to be reversible, and reversible EXACTLY: a compensating operation over the
    // enumerated list of what the mark did, not a guess at an inverse (L5, L38).
    @Test func theUndoPutsBackEverythingTheMarkTouched() throws {
        let ctx = ModelContext(try container())
        let (p, r) = dmPitched(ctx)
        let colleague = Recipient(id: "boxoffice@jalopy.example", email: "boxoffice@jalopy.example",
                                  provenance: .presenter)
        p.addRecipient(colleague)
        r.resolution = .stoodDown

        #expect(HandMarkedReply.mark(r, in: p, now: now))
        #expect(HandMarkedReply.undo(r, in: p))

        #expect(!r.replied)
        #expect(r.repliedAt == nil)
        #expect(r.replyMarkedByHandAt == nil)
        #expect(!r.replyMarkClearedStandDown)
        #expect(r.resolution == .stoodDown)      // put back, not guessed at
        #expect(!colleague.pausedByReply)
        #expect(colleague.isSendablePending)
    }

    // The one thing the undo must NOT do: lift a pause that a DIFFERENT reply is still owed. Resuming
    // everything would put Overture back to cold-pitching a colleague underneath a live conversation
    // somebody else on the show is having, which is the exact defect the pause exists to prevent.
    @Test func theUndoLeavesAPauseAnotherReplyIsStillOwed() throws {
        let ctx = ModelContext(try container())
        let (p, r) = dmPitched(ctx)
        let colleague = Recipient(id: "boxoffice@jalopy.example", email: "boxoffice@jalopy.example",
                                  provenance: .presenter)
        p.addRecipient(colleague)
        let other = Recipient(id: "artistic@jalopy.example", email: "artistic@jalopy.example",
                              provenance: .presenter)
        other.sendState = SendState.sent
        other.sentAt = now.addingTimeInterval(-5 * 86_400)
        other.gmailMessageId = "<ours@mail.gmail.com>"
        other.gmailThreadId = "thread-real"
        p.addRecipient(other)

        #expect(HandMarkedReply.mark(r, in: p, now: now))
        // A real reply lands on the other contact while the hand mark is standing.
        other.reopenOnReply(at: now.addingTimeInterval(60))
        #expect(HandMarkedReply.undo(r, in: p))

        #expect(!r.replied)                 // the mark is undone
        #expect(colleague.pausedByReply)    // and the pause the OTHER reply owns survives
    }

    // Refused once Dan has answered on this contact, because the answer is the thing the undo cannot take
    // back. Refusing is honest; a partial undo claiming to be exact is not (L38).
    @Test func theUndoRefusesOnceDanHasAnswered() throws {
        let ctx = ModelContext(try container())
        let (p, r) = dmPitched(ctx)

        #expect(HandMarkedReply.mark(r, in: p, now: now))
        r.replyHandledAt = now.addingTimeInterval(3_600)

        #expect(!HandMarkedReply.undo(r, in: p))
        #expect(r.replied)                                 // nothing half-done
        #expect(r.replyMarkedByHandAt == now)
        // And the refusal carries its reason, from the same function that applies it (L109).
        #expect(HandMarkedReply.undoRefusal(r) == HandMarkedReplyCopy.cannotUndoAfterAnswering)
    }

    // A DETECTED reply is not this control's to undo. Nothing marked it by hand, and dismissing a wrong
    // detection is a different act with its own control (`dismissAutoReply`, #219).
    @Test func theUndoRefusesAReplyOvertureDetected() throws {
        let ctx = ModelContext(try container())
        let (p, r) = dmPitched(ctx)
        r.reopenOnReply(at: now)          // as detection would

        #expect(!HandMarkedReply.undo(r, in: p))
        #expect(r.replied)
    }

    // MARK: what the surfaces say

    // The row's own account of the channel. Once marked, the half of that sentence saying no reply can be
    // seen has stopped being true, and leaving it up would have the card contradict the badge beside it
    // (L118, #843).
    @Test func theCardSaysAReplyWasRecordedByHand() {
        let dm = "https://instagram.com/auroraquartet"
        #expect(FormOutreachCopy.channelLine(formURL: dm, hasWatchableConversation: false,
                                             replyMarkedByHand: false) == FormOutreachCopy.sentLineSocial)
        #expect(FormOutreachCopy.channelLine(formURL: dm, hasWatchableConversation: false,
                                             replyMarkedByHand: true) == FormOutreachCopy.markedLineSocial)
        let form = "https://auroraquartet.example/contact"
        #expect(FormOutreachCopy.channelLine(formURL: form, hasWatchableConversation: false,
                                             replyMarkedByHand: true) == FormOutreachCopy.markedLine)
        // An attached conversation still wins: Overture really is watching one, and that is the more
        // useful fact.
        #expect(FormOutreachCopy.channelLine(formURL: form, hasWatchableConversation: true,
                                             replyMarkedByHand: true) == FormOutreachCopy.watchedLine)
    }

    // The reply panel already has three sentences for "no words", and every one of them would be a lie
    // here: two claim a message exists in Gmail, and the third is the inquiry case that says nothing at
    // all. A hand-marked reply is a fourth state and gets a fourth sentence (L10, L11).
    @Test func theReplyPanelSaysWhyThereAreNoWordsToShow() throws {
        let ctx = ModelContext(try container())
        let (p, r) = dmPitched(ctx)
        r.email = "hello@auroraquartet.example"     // so the panel is reachable at all

        #expect(HandMarkedReply.mark(r, in: p, now: now))

        #expect(ReplyPanel.theirWords(r) == nil)
        #expect(ReplyPanel.missingWordsReason(r) == ReplyPanelCopy.markedByHandHasNoWords)
    }

    // And the Answer control is not offered where there is no address to answer at. A DM reply is
    // answered inside Instagram; a button here would open a compose box that can never send (L109).
    @Test func theAnswerControlIsNotOfferedWithNoAddressToAnswerAt() throws {
        let ctx = ModelContext(try container())
        let (p, r) = dmPitched(ctx)

        #expect(HandMarkedReply.mark(r, in: p, now: now))

        #expect(r.hasUnhandledReply)                  // it IS a live conversation...
        #expect(!ReplyPanel.isOffered(for: r, in: p)) // ...just not one Overture can answer
    }

    // The other half, so the gate above is not a gate on everything: a contact that does have an address
    // is still offered the answer.
    @Test func theAnswerControlIsStillOfferedWhereThereIsAnAddress() throws {
        let ctx = ModelContext(try container())
        let (p, r) = dmPitched(ctx)
        r.email = "hello@auroraquartet.example"

        #expect(HandMarkedReply.mark(r, in: p, now: now))

        #expect(ReplyPanel.isOffered(for: r, in: p))
    }
}
