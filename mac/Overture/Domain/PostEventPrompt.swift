import Foundation

// #2397: what is left of the conversation reminder track once `ConversationState` is retired.
//
// The old track was keyed on a state Dan set by hand (Interested, Wants to book, Has a question), and every
// part of it existed to tune when and how a nudge went out. His words on the state menu: "we shouldn't have
// both state and close out. It feels like it's supposed to be the same thing? state is mostly just trying to
// capture the outcome." Asked whether the three live values earned their place, he chose to drop all three,
// and with them: their three interval settings, the two-day "you haven't said where this stands" chase, the
// AI's guess at the state, and the Confirm button beside it.
//
// This survives because its trigger was never the state. It is the show's DATE, so it outlives everything
// keyed on what Dan set. Two kinds, and which one appears turns on one question: did anybody write back?
//
//   - Nobody did, so the gracious closing note fits. Dan's rule is exact: "If I'm sending that, it basically
//     HAS to mean never heard back. If I heard back and they said not now or something I would have already
//     set that state." Sending it records `ShowOutcome.neverHeardBack`.
//   - Somebody did, and no ending is recorded. The closing note would assert nobody answered, which is
//     false, so the prompt is to close it out: he already knows what happened, it only needs recording.
//     Without a prompt the show sits in Reached out absent from the reporting the funnel exists to produce.
//     His decision, 2026-08-09, asked directly.
//
// The silent follow-up track (`FollowUp`) is a different thing entirely and is untouched.
// A UI-agnostic accent for a prompt, so the colour decision is testable without SwiftUI. The view maps each
// token to a brand colour. Kept from the retired reminder track, which is where it was declared.
enum ReminderAccent: Equatable, Sendable {
    case onTrack, attention, warm, neutral
}

enum PostEventPrompt {
    // #2710: NEITHER of these is an email any more.
    //
    // Dan's call, 2026-08-14, after reading both emails rendered as a recipient meets them: "I don't want
    // two closing notes. I think I actually want to make it so nudge 2 of 2 is the last email and I don't
    // do a closing note after the show." Reconfirmed 2026-08-16 against the alternative of keeping it
    // wherever an address exists.
    //
    // So the final follow-up is the last thing Overture ever emails a contact who has not written back,
    // and it already reads as a goodbye. What remains after the show is a request to RECORD how it ended,
    // which is a fact only Dan has.
    //
    // Two cases rather than one, because the sentence differs and a message may claim only what its check
    // measured (L11): telling Dan "they replied" on a show nobody answered would be false.
    enum Kind: Equatable, Sendable {
        // Somebody wrote back. Dan knows how it ended.
        case closeOut
        // Nobody wrote back. The likely answer is "never heard back", and it is still his to choose: it
        // may have ended some other way he knows about and Overture does not.
        case closeOutUnanswered
    }

    struct Prompt: Equatable, Sendable {
        let kind: Kind
        let reason: String
    }

    static func reason(for kind: Kind) -> String {
        switch kind {
        case .closeOut: return "Event passed, they replied, say how it ended"
        case .closeOutUnanswered: return "Event passed, nobody replied, say how it ended"
        }
    }

    // #2710: both are `.attention` now, where the closing note used to be `.neutral`. That was right for
    // an optional email that kept a door open; it is wrong for the last thing standing between a finished
    // pitch and the reporting. Both are now the same kind of work, and only Dan can do either.
    static func accent(for kind: Kind) -> ReminderAccent {
        switch kind {
        case .closeOut, .closeOutUnanswered: return .attention
        }
    }

    // A close-out is the more useful of the two to Dan (it is a fact only he has), so it leads.
    // A show somebody replied to leads: the answer is richer, and it is the one where a lead may still be
    // live. An unanswered one is bookkeeping, and it is almost always the same answer.
    static func urgencyRank(_ kind: Kind) -> Int {
        switch kind {
        case .closeOut: return 0
        case .closeOutUnanswered: return 1
        }
    }

    // The single source of truth for WHEN a post-event prompt is due, shared by the Due gate and by
    // `ReachedOutQueue`'s schedule so the two cannot drift.
    //
    // #2646: it takes no clock, and that is the fix. It used to end on `guard now >= dayAfter`, so it
    // declined to name its own date until that date had already arrived, which is the one question a
    // function called "when is this due" exists to answer. A clock reporting nil is indistinguishable
    // from a clock with nothing to report, so `ReachedOutQueue.nextActionableMoment`'s `min` skipped
    // straight past it to the farther nudge: Dan read "in 5 days" on a row whose closing note was owed
    // the next morning, and it would have jumped to "Reach out now" overnight with no warning.
    //
    // Whether it is due YET is a separate question, asked only by `prompt(for:of:now:)` below.
    //
    // nil still means none applies, and every reason below is a genuine absence rather than a moment in
    // the future: the show has no date to pass, Dan has already recorded how it ended, this contact is
    // out of play, or a note already sent has stepped the prompt forward.
    static func nextPromptDate(for r: Recipient, of p: Prospect) -> Date? {
        // Dan closed it out, so Overture stops asking. The inverse of his own rule that nothing is closed
        // unless he closed it: once he has, leave it alone.
        //
        // NOTE this supersedes #1840's deliberate carve-out, which kept the closing note coming due on a
        // show Dan had stood down, on the grounds that the note serves the NEXT event. It cannot survive the
        // new rule: standing a show down is now the recorded ending "I turned them down", and a note whose
        // whole meaning is "never heard back" would assert something false about it.
        guard p.showOutcome == nil else { return nil }
        guard p.status != .dismissed else { return nil }          // #238: a dismissed lead stops nagging
        guard !p.isBooked else { return nil }
        guard r.sentAt != nil, r.hasProvenOutreach else { return nil }
        guard !r.bounced else { return nil }
        // #1740: the closing note Dan closed out by hand, "not sent but also done". A reply reopens it.
        guard !r.isClosingNoteStoodDown else { return nil }
        // Dated the day AFTER the show, not read off the clock, so one owed for a week reads a week overdue
        // rather than arriving fresh every morning (#2116).
        guard let dayAfter = dayAfterShow(p.performanceDate) else { return nil }
        // A re-anchor from a note already sent steps the prompt forward instead of nagging.
        if let anchored = r.conversationRemindedAt, anchored >= dayAfter { return nil }
        // #2651: the final follow-up has already said goodbye in Dan's voice ("If it would be useful down
        // the line I'm glad to help, and if not, no need to reply. I'll leave it here either way."), so a
        // closing note after it would reopen the conversation only to close it a second time. To a
        // stranger who has ignored two emails that reads as a third unsolicited contact rather than as
        // grace, and the scheduling makes it ordinary: any lead scouted far enough ahead exhausts its
        // follow-ups well before the date arrives.
        //
        // ONLY the closing note. A close-out is not an email at all, it is Dan recording how the show
        // ended, it is the more useful of the two prompts to him, and it is a fact only he has, so
        // suppressing it because Overture happened to send two nudges would lose the outcome the whole
        // funnel is reported on.
        //
        // The other half of the issue's choice, making the final nudge stop saying goodbye so the note
        // could be the one that does, was rejected: that goodbye has already been SENT to everybody
        // currently at two nudges, so rewording it would help only future contacts and leave every
        // existing one still getting two.
        return dayAfter
    }

    // WHICH prompt this contact is owed, shared by `nextPromptDate` and `prompt` so the rule above and the
    // Prompt handed to the screen cannot disagree about what kind it is (L16).
    //
    // The one question that decides it: did anybody write back? Asked of the SHOW rather than this
    // contact, because a colleague's answer is an answer about the event, and offering a note that says
    // "never heard back" on a show somebody replied to would be false whoever replied.
    static func kind(for r: Recipient, of p: Prospect) -> Kind {
        p.recipients.contains { $0.replied } ? .closeOut : .closeOutUnanswered
    }

    static func prompt(for r: Recipient, of p: Prospect, now: Date) -> Prompt? {
        // #2646: THIS is where the clock belongs. `nextPromptDate` says when; this says whether it is now.
        guard let due = nextPromptDate(for: r, of: p), now >= due else { return nil }
        let kind = kind(for: r, of: p)
        return Prompt(kind: kind, reason: reason(for: kind))
    }

    // Eastern midnight opening the day after the performance, the moment a prompt starts being owed.
    private static func dayAfterShow(_ performanceDate: String?) -> Date? {
        performanceDate
            .flatMap { EasternDate.date(from: $0) }
            .flatMap { EasternDate.calendar.date(byAdding: .day, value: 1, to: $0) }
    }

    struct DueRecipient { let prospect: Prospect; let recipient: Recipient; let prompt: Prompt }

    static func dueRecipients(from prospects: [Prospect], now: Date) -> [DueRecipient] {
        var due: [DueRecipient] = []
        for p in prospects {
            let here = p.recipients.compactMap { r -> DueRecipient? in
                prompt(for: r, of: p, now: now).map { DueRecipient(prospect: p, recipient: r, prompt: $0) }
            }
            // #2126: one row per EMAIL. Everyone on one send is reading one thread, so it is one thing for
            // Dan to act on; two rows asked him the same question twice.
            due.append(contentsOf: SendGroup.oneRowPerGroup(here) { $0.recipient })
        }
        return due.sorted {
            let ra = urgencyRank($0.prompt.kind), rb = urgencyRank($1.prompt.kind)
            if ra != rb { return ra < rb }
            return ($0.prospect.performanceDate ?? "9999") < ($1.prospect.performanceDate ?? "9999")
        }
    }

    // #2710: `nudgeContent`, `closingNudgeBody` and their outbound-email ignore region stood here, and
    // they are gone with the email itself. Nothing composes a post-show message any more: the last thing
    // Overture sends a silent contact is the final follow-up, which already says goodbye. Git remembers
    // the words; keeping them would be a body with no sender (L29).
}
