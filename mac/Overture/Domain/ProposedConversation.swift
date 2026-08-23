import Foundation

// #2718: put the proposal in front of Dan as DUE WORK he can answer on the row.
//
// His call, 2026-08-14: a quiet question would sit unanswered until the show had been and gone. So it
// joins `DueWork.Counts` rather than sitting silently on a card. A pill's number is a promise about
// rows, and a proposal appearing in Reached out without joining the count would give a number that
// excludes rows the list shows (L16).
//
// Everything the question needs is STORED on the contact, because a SwiftUI row cannot make a Gmail
// call and a question Dan cannot answer without opening Gmail is the thing this milestone exists to
// remove.
enum ProposedConversationCopy {
    // #2967: the heading of the section in the Follow-ups sheet these rows now have. Beside the
    // question it heads rather than in the view, so the sheet and the Reached out row cannot come to
    // two wordings of one thing.
    static let section = "Conversations to confirm"
    // #2806: the durable account of an attach that captured a reply and left nothing waiting. Built from
    // the STORED facts, never from the attach's transient outcome, so it is still there tomorrow and
    // after a relaunch, which is what durable has to mean for a question Dan asked a minute later.
    //
    // It names the REPLY and the SAVED ADDRESS, and not the linking, because he pressed the link button
    // himself and already knows he did. The address is the consequence with the longest reach: every
    // email on this show from now on goes there, which `confirmDetail` promises BEFORE the click and
    // nothing confirmed after it.
    //
    // The address is passed rather than read off a flag, so a row whose flag says an address was saved
    // and carries none cannot render "and it goes to " with nothing after it (L67).
    //
    // The WORDS came from the cold read, against the line directly above this one on the same row
    // ("Sent through their form. Overture is watching the email conversation you linked."). A first
    // draft said "nothing is waiting on you", which is true and answers a question Dan did not ask. What
    // he asked was "did the link work, what did it do", so the line says what it DID: their reply landed
    // and his answer is already on it, which is precisely what `replyHandledAt` records and what no
    // surface said.
    static func linkedAndAnswered(wroteAddress: Bool, address: String?) -> String {
        guard wroteAddress, let address, !address.isEmpty else {
            return "Their reply is here and you've already answered it."
        }
        return "Their reply is here and you've already answered it. Email goes to \(address) from now on."
    }

    static let question = "Is this their reply?"

    // Names the sender the way a person is named: who, then where from, because the address alone is
    // what he would have had to open Gmail to see.
    static func sender(name: String?, address: String) -> String {
        guard let name, !name.isEmpty else { return address }
        return "\(name) (\(address))"
    }

    static func detail(subject: String, sentAt: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        let subject = subject.isEmpty ? "No subject" : subject
        return "\(subject), \(f.localizedString(for: sentAt, relativeTo: now))"
    }

    static let confirm = "Yes, link it"
    static let decline = "Not them"
    static let manualLink = "Link their reply"

    // What confirming DOES, beyond linking a thread. What Dan approves must be exactly what happens,
    // including WHO it reaches (L64): confirming writes this address onto the contact, and every future
    // email on this show goes there. A sheet saying only "link this conversation" would hide the half
    // that matters.
    static func confirmDetail(address: String) -> String {
        "Linking this saves \(address) on the contact. Overture will watch the conversation, and any "
            + "email it sends on this show from now on goes to that address."
    }

    // The three states each get their own sentence, or they sit in the data and vanish from the product
    // (L45). "Read for and found nothing" and "never read for" are deliberately different lines: only
    // the first is Overture telling him something (L98).
    static let allDeclined =
        "You've said none of the messages Overture found are them. It'll keep looking while this pitch "
            + "is open."
    static let searchedAndFoundNothing =
        "Overture is reading your inbox for a reply to this one and hasn't found a likely match yet."
    static let notSearchedYet =
        "Overture hasn't read your inbox for a reply to this one yet."
    // Past the horizon. It says the manual route is still there, because otherwise this reads as a door
    // closing rather than as one control replacing another (L111: advice has to change the state he is
    // stuck in).
    static let stoppedLooking =
        "Overture has stopped looking for a reply to this one. If they did write, link it by hand."
    static let attachedAwaitingAnswer =
        "You linked their reply. It's waiting on you."
    static let linked = "Linked. Overture is watching that conversation now."
    // Time-taking work says WORKING, not just spins: linking makes two Gmail calls, and a control that
    // looks identical whether it is progressing, hung or dead is a defect.
    static let linking = "Linking..."
    static let couldNotSaveLink =
        "Overture couldn't save the link. Try again; if this keeps happening, something's wrong with the "
            + "local store."
    static let pickTitle = "Which message is their reply?"
    // Its own sentence, distinct from `searchedAndFoundNothing`: that one is the row saying it is still
    // looking, this one is the picker saying it looked just now and has nothing to offer, which is what
    // Dan is standing there waiting to hear.
    static let reading = "Reading your inbox..."
    static let tryAgain = "Try again"
    static let close = "Close"
    static let notConnected =
        "Overture isn't connected to Gmail, so it can't read your inbox. Connect it in Settings and try again."
    static let pickNothingFound =
        "Overture read your inbox and found nothing from around this pitch that could be their reply."
}

// Deliberately NOT main-actor isolated, like `PostEventPrompt` and `FollowUp`, the other two members of
// `DueWork.Counts`: that count is computed from a nonisolated context, and a member that could only be
// counted from one actor would be a member the pill cannot include.
enum ProposedConversation {

    // One candidate, in the shape the row renders and the store holds. Deliberately the same six facts
    // `GmailReplySearch.InboundMessage` carries plus the score, rather than a reference to it, because
    // this is what SURVIVES in the store after the tick that found it has gone.
    struct Candidate: Equatable, Sendable {
        var messageId: String
        var threadId: String
        var fromAddress: String
        var fromName: String?
        var subject: String
        var sentAt: Date
        var score: Int
    }

    enum State: Equatable {
        case notApplicable
        case none(searched: Bool)
        // #2718: past the search horizon, so Overture is no longer reading for this one. Its own state
        // rather than folded into `.none`, because "hasn't found one yet" and "isn't looking any more"
        // are different things to tell Dan and only one of them means the manual route is now the only
        // way in.
        case stoppedLooking
        case proposed(Candidate)
        case allDeclined
        case attachedAwaitingAnswer
        // #2806: linked, the reply captured, and nothing waiting on him. It used to fall to
        // `.notApplicable`, which draws EmptyView, so the MORE completely the attach succeeded the less
        // the row said: the version that shows a badge is the one where he had not already answered,
        // which has less to report rather than more. Dan read the silence as the link not having worked.
        case attachedAndAnswered
    }

    // MARK: writing

    // Store a proposal, unless one is already standing.
    //
    // The FIRST candidate is held until Dan answers it. A better one arriving later does not silently
    // replace the question he is looking at (L64), and a declined conversation is never proposed again.
    static func propose(_ c: Candidate, on r: Recipient, now: Date) {
        guard isAskable(r) else { return }
        guard !declined(r).contains(c.threadId) else { return }
        guard stored(on: r) == nil else { return }
        r.replyProposedMessageId = c.messageId
        r.replyProposedThreadId = c.threadId
        r.replyProposedFromAddress = c.fromAddress
        r.replyProposedFromName = c.fromName
        r.replyProposedSubject = c.subject
        r.replyProposedSentAt = c.sentAt
        r.replyProposedScore = c.score
        r.replyProposedAt = now
    }

    // Dan says it is not them. Recorded against the CONVERSATION, so a newer message on the same thread
    // does not come straight back as a fresh question.
    static func decline(on r: Recipient) {
        guard let thread = r.replyProposedThreadId else { return }
        var ids = declined(r)
        ids.insert(thread)
        r.dismissedConversationIds = ids.sorted()
        clear(on: r)
    }

    // Take the standing question down without declining it, for when it has been answered by attaching.
    static func clear(on r: Recipient) {
        r.replyProposedMessageId = nil
        r.replyProposedThreadId = nil
        r.replyProposedFromAddress = nil
        r.replyProposedFromName = nil
        r.replyProposedSubject = nil
        r.replyProposedSentAt = nil
        r.replyProposedScore = 0
        r.replyProposedAt = nil
    }

    // MARK: reading

    static func stored(on r: Recipient) -> Candidate? {
        guard let messageId = r.replyProposedMessageId,
              let threadId = r.replyProposedThreadId,
              let from = r.replyProposedFromAddress,
              let sentAt = r.replyProposedSentAt else { return nil }
        return Candidate(messageId: messageId, threadId: threadId, fromAddress: from,
                         fromName: r.replyProposedFromName, subject: r.replyProposedSubject ?? "",
                         sentAt: sentAt, score: r.replyProposedScore)
    }

    static func declined(_ r: Recipient) -> Set<String> { Set(r.dismissedConversationIds ?? []) }

    // Is this a contact the question can even be asked about? The same scope the search uses: a pitch
    // sent by hand, with no conversation Overture is already watching.
    static func isAskable(_ r: Recipient) -> Bool {
        r.formOutreachRecordedAt != nil && !r.hasWatchableConversation
    }

    static func state(of r: Recipient, now: Date = Date()) -> State {
        if r.conversationAttachedAt != nil {
            // #2806: the second branch used to be `.notApplicable`. An attach that also stamped
            // `replyHandledAt` is the completely successful case and was the silent one.
            return r.hasUnhandledReply ? .attachedAwaitingAnswer : .attachedAndAnswered
        }
        guard isAskable(r) else { return .notApplicable }
        // #2711: he has already told Overture they replied on a channel it cannot watch. The row is
        // saying so on the line above ("You told Overture they replied"), so adding "Overture is reading
        // your inbox and hasn't found a likely match yet" beneath it is the same #843 duplication the
        // channel line was just split to avoid, pointed at a different pair. The manual link control is
        // deliberately still offered (`offersManualLink` does not ask this), because a Gmail thread may
        // still turn up and linking it is worth more than the sentence was.
        if r.replyMarkedByHandAt != nil { return .notApplicable }
        // A standing question survives the horizon. Overture stops LOOKING for new candidates; it does
        // not withdraw a question Dan has not answered.
        if let c = stored(on: r) { return .proposed(c) }
        if !declined(r).isEmpty { return .allDeclined }
        // Asked of the same predicate the search selects by, so the row cannot say Overture is reading
        // for a reply on a pitch the search has already dropped (L16).
        guard ReplySearchScope.inScope(r, now: now) else { return .stoppedLooking }
        return .none(searched: r.replyCandidateSearchedAt != nil)
    }

    // Dan's explicit ask: "I'll also need a way to tell it about the email if there's a situation where
    // it doesn't propose but I got an email anyway."
    static func offersManualLink(_ r: Recipient) -> Bool { isAskable(r) }

    // Everything the manual picker may offer: every message the search found that is not REFUSED for this
    // show, best first.
    //
    // The refusals still apply, and that is the point of routing the manual path through the same
    // function rather than round it. Dan picking by hand is him overriding the SCORE, which is a
    // judgement about who is most likely; it is not him overriding "never the room's own address" or
    // "never a press desk", which are rules the product has held since #368 and #635. A hand route that
    // skipped them would be a side door into the exact defect the guards exist for.
    //
    // Declined conversations are dropped too, because offering one he has already said is not them is
    // asking the same question twice.
    // `@MainActor` on this one function only, because it is the single member here that reaches into
    // `ReplyCandidateMatch`, and marking the whole type would drag `DueWork.counts` onto the main actor
    // with it.
    @MainActor
    static func pickable(_ candidates: [GmailReplySearch.InboundMessage], for r: Recipient,
                         on p: Prospect, selfEmail: String) -> [Candidate] {
        let declinedIds = declined(r)
        return candidates
            .filter { ReplyCandidateMatch.refusal(for: $0, venue: p.venue, selfEmail: selfEmail) == nil }
            .filter { !declinedIds.contains($0.threadId) }
            .map { m in
                let scored = ReplyCandidateMatch.score(m, tokens: ReplyCandidateMatch.tokens(for: r, on: p))
                return Candidate(messageId: m.messageId, threadId: m.threadId,
                                 fromAddress: m.fromAddress, fromName: m.fromName,
                                 subject: m.subject, sentAt: m.sentAt, score: scored.score)
            }
            // Best first, then newest, so the list reads the way Dan would sort it himself and two equal
            // scores do not change places between openings.
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.sentAt > $1.sentAt }
    }

    // MARK: due work

    // The rows the count promises. ONE predicate, so the pill Dan clicks and the list he lands on can
    // never state different numbers (L16). Deliberately shaped like `PostEventPrompt.dueRecipients`, the
    // other member of `DueWork.Counts`.
    struct DueRecipient {
        let prospect: Prospect
        let recipient: Recipient
        let candidate: Candidate
    }

    static func dueRecipients(from prospects: [Prospect]) -> [DueRecipient] {
        prospects.flatMap { p -> [DueRecipient] in
            // A show Dan has closed out or booked is not asking him anything.
            guard !p.replyWatchManualOutcome, !p.replyWatchIsBooked else { return [] }
            return p.recipients.compactMap { r in
                guard case .proposed(let c) = state(of: r) else { return nil }
                guard r.replyWatchConversationIsOpen else { return nil }
                return DueRecipient(prospect: p, recipient: r, candidate: c)
            }
        }
    }
}
