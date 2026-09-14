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
    // #3711: `displaced` is the address the pitch actually WENT to, when linking moved the contact off
    // it. Its own parameter rather than a second flag, on `address`'s own precedent: a row whose flag says
    // an address was displaced and carries none cannot render "not " with nothing after it (L67).
    static func linkedAndAnswered(wroteAddress: Bool, address: String?, displaced: String? = nil) -> String {
        let account = "Their reply is here and you've already answered it."
        guard let clause = addressClause(wroteAddress: wroteAddress, address: address,
                                          displaced: displaced) else { return account }
        return account + " " + clause
    }

    // #3711: the same account for the state where he has NOT answered yet. It was a bare `let` saying
    // "You linked their reply. It's waiting on you", which is true of a link that merely captured a reply
    // and silent about the bigger thing a link can now do, which is move the contact onto a different
    // person entirely. The two states share one clause for that (below) rather than each describing the
    // move in its own words, because one fact told two ways on one screen is two facts to a reader (L605).
    static func attachedAwaitingAnswer(wroteAddress: Bool = false, address: String? = nil,
                                       displaced: String? = nil) -> String {
        let account = "You linked their reply. It's waiting on you."
        guard let clause = addressClause(wroteAddress: wroteAddress, address: address,
                                          displaced: displaced) else { return account }
        return account + " " + clause
    }

    // WHO the show talks to from now on, which is the consequence with the longest reach and the one
    // neither state used to give. Nil when there is nothing to say: an attach onto a contact that already
    // had the writer's address changed nobody's address at all, and a sentence about it would be a fact
    // invented to fill a line.
    //
    // The displaced arm is checked FIRST, because a link that MOVED the contact is the bigger claim and
    // the two arms are mutually exclusive on the attach side anyway (`attachWroteAddress` fills an empty
    // address, `attachDisplacedEmail` replaces a populated one). Reading them the other way round would
    // silently prefer the smaller sentence if that ever stopped holding.
    private static func addressClause(wroteAddress: Bool, address: String?, displaced: String?) -> String? {
        guard let address, !address.isEmpty else { return nil }
        if let displaced, !displaced.isEmpty, displaced.lowercased() != address.lowercased() {
            return "Email goes to \(address) from now on, not \(displaced)."
        }
        guard wroteAddress else { return nil }
        return "Email goes to \(address) from now on."
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
    // #3711: what confirming DOES, one whole sentence per state rather than one built from clauses.
    //
    // `replacing` is the address the pitch actually went to. The sentence this replaces was written for a
    // contact with no address at all, and where there IS one, confirming agrees to something larger than
    // saving an address: it moves the show off the one Dan pitched. What he approves has to be exactly
    // what happens, including who it reaches (L64).
    //
    // Written out twice rather than assembled from parts, deliberately. `docs/copy-inventory.md` is read
    // by a person, in the words Dan will read, and a sentence built from fragments arrives there as its
    // fragments ("Overture will watch the conversation,"), which is exactly the reading that document
    // exists to make possible (#915).
    //
    // It says NOTHING about a conversation being displaced, and that is measured rather than assumed:
    // both its call sites draw `ProposedConversation.State.proposed`, which is reachable only through
    // `isAskable`, which requires `!hasWatchableConversation`. A parameter for it would be one nothing
    // could ever pass true.
    //
    // `isAskable` also requires `formOutreachRecordedAt`, so every row this can appear on is a FORM
    // pitch, which is why it says "the address it replaces" where the picker says "the address you
    // pitched": a form pitch went to a form, and an address Prep found for that contact is not one Dan
    // pitched to. The two sentences differ because the two states differ, and only the second is entitled
    // to the warmer phrasing (L11).
    static func confirmDetail(address: String, replacing: String? = nil) -> String {
        guard let displaced = displacedAddress(replacing, adopting: address) else {
            return "Linking this saves \(address) on the contact. Overture will watch the conversation, "
                + "and every email on this show from now on goes to that address."
        }
        return "Linking this moves the contact from \(displaced) to \(address). Overture will watch the "
            + "conversation, and every email on this show from now on goes to \(address). The address it "
            + "replaces is kept on the contact."
    }

    // #3711: the same thing said ONCE, above the picker's list, because the picker is the one surface
    // that shows several candidates at a time.
    //
    // `confirmDetail` above is per candidate and right where there is one: the row's proposal and the
    // Follow-ups sheet each ask about a single message. In the picker it was drawn on every row, and its
    // whole first half is a fact about the CONTACT rather than about the message, identical down the
    // list. At the real count that is a wall of repeated text nobody reads, and no fixture reaches it
    // (L579); saying it once and letting each row's own sender line name who it would move to is every
    // fact once per screen (L605).
    //
    // Unlike `confirmDetail` this one CAN be reached on a contact holding a conversation, because the
    // menu route (#3707) offers it on an emailed pitch, and that is the state milestone 82 exists for.
    // Overture stops watching the thread it sent on, which is a consequence Dan could not guess and which
    // no other sentence tells him. Named as the one it EMAILED rather than the one it is watching, which
    // is exact for every state a link can actually succeed in: a watched thread that no attach put there
    // came from a real send, and `AttachConversation` refuses a contact that already holds an attached
    // one.
    //
    // Four states, four whole sentences, for the reason above. Only the two that MOVE a conversation open
    // with "this pitch went to": those are reachable only from the menu route, which needs a real send,
    // and on a form pitch reached from the inline control the pitch went to a FORM rather than to an
    // address (L11). What every branch that displaces one says, in the same words as the row's own
    // sentence, is that it survives: one fact, one wording, wherever it is shown (L605).
    static func pickWhatLinkingDoes(replacing: String?, alsoMovesTheConversation: Bool = false) -> String {
        guard let displaced = displacedAddress(replacing) else {
            return alsoMovesTheConversation
                ? "Linking one of these saves the writer's address on the contact. Overture watches that "
                    + "conversation instead of the one it emailed, and every email on this show from now "
                    + "on goes to that address."
                : "Linking one of these saves the writer's address on the contact. Overture will watch "
                    + "that conversation, and every email on this show from now on goes to that address."
        }
        return alsoMovesTheConversation
            ? "This pitch went to \(displaced). Linking one of these moves the contact onto whoever wrote "
                + "it. Overture watches that conversation instead of the one it emailed, and every email "
                + "on this show from now on goes to them. The address it replaces is kept on the contact."
            : "Linking one of these moves the contact from \(displaced) onto whoever wrote it, and every "
                + "email on this show from now on goes to them. The address it replaces is kept on the "
                + "contact."
    }

    // The address a link would really move OFF this contact, or nil where nothing moves: nothing stored,
    // whitespace, or the writer already being the contact. Asked in one place, so two sentences about one
    // act cannot disagree about whether it is a move (L16).
    private static func displacedAddress(_ replacing: String?, adopting: String? = nil) -> String? {
        guard let trimmed = replacing?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if let adopting, trimmed.lowercased() == adopting.lowercased() { return nil }
        return trimmed
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
    static let linked = "Linked. Overture is watching that conversation now."
    // #3712: what a confirm with no conversation in front of it says. It used to borrow
    // `DetachConversationCopy.nothingLinked`, which is the DETACH's sentence and reads "there's no linked
    // conversation on this pitch to unlink": a message about undoing something, shown to Dan at the moment
    // he asked to do it. A message may claim only what its check measured (L11), and what this one
    // measured is that the question it was about to answer is no longer on the row.
    static let nothingToLink =
        "Overture couldn't find the message you picked, so it linked nothing. Try picking it again."
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
    // #3708: the two answers that are NOT "read it and found nothing", kept apart from it and from each
    // other because only one of the three is Overture telling Dan the reply is not there (L98, L11).
    //
    // A read that stopped short covers both ways it can stop (too many pages of ids, too many messages),
    // because to Dan they are one fact: the newest stretch of the window was read and the older mail in
    // it was not. The number is the budget itself rather than a word like "some", since "is their reply
    // older than the last 300 messages" is a question he can actually answer.
    static func pickStoppedShort(examined: Int) -> String {
        "Overture read the \(examined) most recent messages since this pitch went out and stopped there. "
            + "If their reply is older than those, it isn't in this list."
    }
    static let pickNoPitchDate =
        "Overture has no record of when this pitch went out, so it doesn't know how far back to read "
            + "your inbox. Nothing was read."
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
