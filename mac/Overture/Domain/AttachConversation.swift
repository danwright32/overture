import Foundation

// #2715: link a Gmail conversation to a pitch Overture cannot watch, in ONE write.
//
// It stamps `gmailThreadId` AND runs `ReplyService` detection over the thread already in hand, together.
// That is the design rather than an optimisation. Everything the row can answer with is written by
// detection, not by the attach: `replyAudience`, `inboundReplyMessageId`, `replyFromAddress`,
// `lastReplyText`, `lastReplyId`. Between attaching and the next tick, up to thirty minutes later, the
// row would otherwise hold a conversation, no reply, an empty audience and no parent message, and
// answering in that window would send an unthreaded message straight past #2653's fix (L3, L12, L14).
// There is also no reason to stamp an id and then re-fetch a thread that is already in hand.
//
// It never stamps `gmailMessageId`: Overture has sent nothing here, and storing one would flip the row
// into "Overture emailed them" and put the follow-up and closing-note paths back in front of Dan on the
// one row they must never reach (#2717).
//
// WHAT THE ROW SAYS BETWEEN THE ATTACH AND THE NEXT TICK: nothing new, because there is no such window.
// That gap is exactly what running detection here closes. The row goes from "sent through their form,
// Overture cannot see a reply" to a fully answerable conversation in one step, and never sits in the
// half state that would let Dan answer with no parent message.
//
// IT DOES NOT COMMIT, and its caller does, on the `ContactRefusal.refuse` precedent (#2662): every
// SwiftData save invalidates the queue's @Query and rebuilds every card on the main thread, so a
// function that saves for itself makes one click pay for that twice. The caller is #2718's control.
//
// WHAT HAPPENS IF THIS LANDS MID-CHECK: `GmailReplyChecker.markReplies` computes `threadsToCheck` and
// then awaits its fetches, so an attach can run in between. The newly linked thread is not in the set
// that pass already fetched, so its own `fetchThread` answers nil for this row and detection there
// skips it, leaving what the attach wrote untouched; the pass's `context.save()` then commits both.
// Nothing is detected twice, because the attach has already recorded the reply id and detection is
// keyed on it. The one consequence worth naming is that a save failure in that pass covers this write
// too, which is why the caller checks its own save rather than assuming this one landed (L12).
// Pure sentences, deliberately NOT main-actor isolated: the reply panel is nonisolated and reads one of
// them, and a copy constant that can only be reached from one actor is a sentence half the app cannot
// say.
enum AttachConversationWriteCopy {
    // Every refusal is spoken by the function that DECIDES it, so a greyed control and the reason beside
    // it cannot disagree (L109). Each one names what is in the way and what Dan can do about it, because
    // advice that does not change the state he is stuck in leaves him exactly where he was (L111).
    static func struckAddress(_ address: String) -> String {
        "You struck \(address) off this show, so Overture won't link a conversation that would write it "
            + "back onto the contact. Add the address back on the card first if you want to use it."
    }

    // Its own sentence, not the one above with a URL in it. A strike made before this contact had any
    // address is recorded against the FORM, and saying "you struck https://... off this show, so
    // Overture won't write it back onto the contact" describes something that would not happen: what
    // would be written back is an address, not a link. Caught by reading the generated inventory cold,
    // which is the only thing that catches it.
    static let struckContact =
        "You struck this contact off the show, so Overture won't link a conversation to it. Add the "
            + "contact back on the card first if you want to use it."

    static let alreadyLinked =
        "This pitch already has a conversation linked. Detach that one first if you linked the wrong thread."

    static let notAHandSentPitch =
        "Overture only links a conversation to a pitch you sent through a form or a DM. It already watches "
            + "the ones it emailed itself."

    static let noThread =
        "Overture couldn't tell which conversation to link, so it linked nothing."

    // #2715: what the reply panel says once a conversation was linked by hand, so the row does not read
    // as though Overture emailed them (L46). Its reader is `ReplyPanel.linkedByHandLine`.
    static let linkedByHand = "You linked this conversation. Overture didn't email them."
}

@MainActor
enum AttachConversation {

    enum Outcome: Equatable {
        case refused(reason: String)
        // `repliesDetected` is what detection ACTUALLY found on the thread, not a claim that a reply
        // exists: a thread Dan links that carries only his own messages attaches fine and detects none.
        case attached(repliesDetected: Int, alreadyAnswered: Bool)
    }

    // `threadJSON` is the metadata thread (From, Subject, Message-ID); `fullThreadJSON` carries the
    // bodies and is optional, exactly as it is for `ReplyService.detectReplies`, so the words are
    // captured when they are available and the attach still works when they are not.
    @discardableResult
    static func attach(threadId: String,
                       threadJSON: Data,
                       fullThreadJSON: Data? = nil,
                       subject: String?,
                       fromAddress: String?,
                       to r: Recipient,
                       on p: Prospect,
                       ledger: ContactRefusal.Ledger,
                       selfEmail: String,
                       now: Date) -> Outcome {
        let thread = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thread.isEmpty else { return .refused(reason: AttachConversationWriteCopy.noThread) }
        // Assume it runs twice. A second attach is refused rather than quietly overwriting the first,
        // because the field holds ONE conversation and replacing it would strand everything detection
        // wrote about the other one.
        guard !r.hasWatchableConversation else {
            return .refused(reason: AttachConversationWriteCopy.alreadyLinked)
        }
        // Dan's scope: only a pitch Overture could neither send nor watch. A pitch it emailed itself
        // already holds a conversation and is watched by the ordinary reply checker.
        guard r.formOutreachRecordedAt != nil else {
            return .refused(reason: AttachConversationWriteCopy.notAHandSentPitch)
        }

        let address = fromAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = address.map { ReplyDetection.email(from: $0) }.flatMap { $0.isEmpty ? nil : $0 }

        // The refusal ledger, asked under BOTH handles this contact can be recorded under.
        //
        // `Recipient.makeId` is the canonical address when there is one and `form:<url>` otherwise, so
        // giving this contact an address CHANGES the key a strike would be looked up by. Asking only the
        // new one would let a strike made against the form contact, before any address existed, slip
        // through in silence, which is L92: a removal recorded against an identifier the item does not
        // yet carry. A protective control that does not fail closed is L42.
        // Derived exactly as `PrepImporter` derives it, so a strike made at the organisation level is
        // looked up under the same key it was written under and cannot be missed by one of the two
        // asking differently (L83).
        let orgKey = p.presenter.flatMap { OrgKey.stored(for: $0) }
        if ledger.isRefused(email: nil, formURL: r.contactFormURL,
                            showKey: p.naturalKey, orgKey: orgKey) {
            return .refused(reason: AttachConversationWriteCopy.struckContact)
        }
        if let canonical, ledger.isRefused(email: canonical, showKey: p.naturalKey, orgKey: orgKey) {
            return .refused(reason: AttachConversationWriteCopy.struckAddress(canonical))
        }

        // Everything the detach will need, captured BEFORE detection runs, because `reopenOnReply`
        // clears a `.stoodDown` resolution and nulls the three draft-baseline fields and nothing else in
        // the app remembers any of them (L5).
        r.attachPriorResolutionRaw = r.resolutionRaw
        r.attachPriorOriginalReplyDraftBody = r.originalReplyDraftBody
        r.attachPriorReplyDraftWrittenByDan = r.replyDraftWrittenByDan
        r.attachPriorReplyDraftEditedByDan = r.replyDraftEditedByDan
        // Which contacts were ALREADY frozen, so the ones this attach freezes can be told apart from
        // the ones it merely found frozen. A detach that cleared every pause it saw would unfreeze rows
        // that were never its to touch.
        let pausedBefore = Set(p.recipients.filter(\.pausedByReply).map(\.id))

        // The link itself. `id` is deliberately NOT re-keyed: the form is still how Dan reached them and
        // how a later run matches them, and the address is an additional fact about the contact rather
        // than a new identity for it. The consequence is named rather than left to be discovered: the
        // handle `ContactRefusal` computes for this contact changes from `form:<url>` to the address, so
        // a strike made from here on is recorded under the address. That is consistent, because the
        // check above refuses an attach onto a contact struck under either spelling, so no strike can be
        // stranded by the change.
        r.gmailThreadId = thread
        r.conversationAttachedAt = now
        if let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty {
            r.attachedThreadSubject = subject
        }
        if let canonical, (r.email ?? "").isEmpty { r.email = canonical }

        // Detection, over the thread already in hand, in this same write.
        let detected = ReplyService.detectReplies(in: [p], selfEmail: selfEmail, now: now,
                                                  fetchThread: { $0 == thread ? threadJSON : nil },
                                                  fetchFullThread: { $0 == thread ? fullThreadJSON : nil })

        r.attachPausedRecipientIds = p.recipients
            .filter { $0.pausedByReply && !pausedBefore.contains($0.id) }
            .map(\.id)
            .sorted()

        // Dan found this reply in Gmail, and the ordinary thing to do there is answer it. Detection
        // cannot notice that, because `latestReplyMessage` skips his own messages, so the row would
        // assert somebody is waiting on him for ever and OmniFocus would grow a task for it.
        let alreadyAnswered = ReplyDetection.newestMessageIsSelf(threadJSON: threadJSON,
                                                                 selfEmail: selfEmail)
        if alreadyAnswered, r.replied, r.replyHandledAt == nil { r.replyHandledAt = now }

        return .attached(repliesDetected: detected, alreadyAnswered: alreadyAnswered)
    }
}
