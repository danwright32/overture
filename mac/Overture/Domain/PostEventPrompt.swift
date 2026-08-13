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
    enum Kind: Equatable, Sendable {
        // A real email Dan reviews and sends.
        case closingNote
        // Not an email. A request to record what he already knows.
        case closeOut
    }

    struct Prompt: Equatable, Sendable {
        let kind: Kind
        let reason: String
    }

    static func reason(for kind: Kind) -> String {
        switch kind {
        case .closingNote: return "Event passed, send a closing note"
        case .closeOut: return "Event passed, they replied, say how it ended"
        }
    }

    static func accent(for kind: Kind) -> ReminderAccent {
        switch kind {
        // Winding down: a note that keeps a door open costs nothing and is not urgent.
        case .closingNote: return .neutral
        // Dan is the one holding this up, and it is the only thing standing between a finished pitch and
        // the reporting, so it reads as something to act on.
        case .closeOut: return .attention
        }
    }

    // A close-out is the more useful of the two to Dan (it is a fact only he has), so it leads.
    static func urgencyRank(_ kind: Kind) -> Int {
        switch kind {
        case .closeOut: return 0
        case .closingNote: return 1
        }
    }

    // The single source of truth for WHEN a post-event prompt is due, shared by the Due gate and by
    // `ReachedOutQueue`'s schedule so the two cannot drift.
    //
    // nil means none applies: the show has not been and gone, it has no date to pass, Dan has already
    // recorded how it ended, or this contact is out of play.
    static func nextPromptDate(for r: Recipient, of p: Prospect, now: Date) -> Date? {
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
        guard now >= dayAfter else { return nil }
        // A re-anchor from a note already sent steps the prompt forward instead of nagging.
        if let anchored = r.conversationRemindedAt, anchored >= dayAfter { return nil }
        return dayAfter
    }

    static func prompt(for r: Recipient, of p: Prospect, now: Date) -> Prompt? {
        guard let due = nextPromptDate(for: r, of: p, now: now), now >= due else { return nil }
        // The one question that decides which kind: did anybody write back? Asked of the SHOW rather than
        // this contact, because a colleague's answer is an answer about the event, and offering a note that
        // says "never heard back" on a show somebody replied to would be false whoever replied.
        let anybodyReplied = p.recipients.contains { $0.replied }
        let kind: Kind = anybodyReplied ? .closeOut : .closingNote
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

    // #948: the exact subject and body the closing note will send, in ONE place, shared by the branded
    // confirmation sheet and the sender, so what Dan confirms cannot differ from what goes out.
    //
    // Returns nil for `.closeOut`, which is not a sendable email at all but a request to record a decision.
    // Nil rather than an empty body, so a caller that forgets the distinction fails loudly.
    struct NudgeContent: Equatable, Sendable { let subject: String; let body: String; let isClosing: Bool }

    static func nudgeContent(kind: Kind, originalSubject: String?, groupName: String, isMerged: Bool = false,
                             contactName: String?, performanceDate: String?, venue: String?) -> NudgeContent? {
        guard kind == .closingNote else { return nil }
        // #1276/#1273: sanitize the merged-concert name and the venue ONCE here, at the shared chokepoint,
        // so a conductor list never reaches a recipient and a legitimate semicolon title keeps its name.
        // The body no longer interpolates the name at all (#2615), but the subject's fallback still does.
        let name = FollowUp.safeDisplayName(groupName, isMerged: isMerged)
        let body = closingNudgeBody(contactName: contactName, performanceDate: performanceDate,
                                    venue: FollowUp.safeVenue(venue))
        return NudgeContent(subject: FollowUp.replySubject(originalSubject: originalSubject, groupName: name),
                            body: body, isClosing: true)
    }

    // copy-inventory:ignore-start  outbound email: a recipient reads this, not Dan (#915)

    // The gracious post-event close: a kind "perhaps another time" that keeps the relationship warm for a
    // future season. #2397: sending it records `ShowOutcome.neverHeardBack`, which is what it has always
    // MEANT and what the send path did not say. It used to resolve the lead to a soft decline in every case,
    // claiming somebody turned Dan down when nobody had written back.
    //
    // #2615: the sentence describes the SHOW, never the group name. `groupName` is whatever the source
    // listed, and for a large share of Overture's prospects that is a solo performer's own name, so
    // "I know <groupName> has come and gone" told a person, in Dan's voice, that they had come and gone.
    // The show is named by its date and room instead, which needs to know nothing about what kind of
    // thing the group name is, and which the thread's own subject already spells out.
    static func closingNudgeBody(contactName: String?, performanceDate: String?, venue: String?) -> String {
        let greeting = Salutation.greeting(for: contactName)
        // An unparseable or missing date drops to a plain "your show", never to a half-built clause or a
        // date string a scrape happened to leave behind.
        let dayClause = performanceDate.flatMap { EasternDate.longDayLabel($0) }.map { "\($0) " } ?? ""
        let show = "your \(dayClause)show" + ((venue?.isEmpty == false) ? " at \(venue!)" : "")
        // #2643: the two sentences this used to end on asserted a conversation that by construction never
        // happened. This note is offered ONLY when nobody on the show has written back (see `prompt(for:)`,
        // which picks `.closeOut` the moment anybody has), and sending it records
        // `ShowOutcome.neverHeardBack`. So "the timing didn't line up this round" reported a decision the
        // recipient never communicated, and "it was good to be in touch" claimed a completed exchange when
        // there had been one message in one direction. Dan read both in the send sheet on 2026-08-13.
        //
        // What replaces them says only what is true of silence: the show has passed, the offer stands, and
        // no reply is wanted. It holds a door open without inventing a relationship to hold it open on, and
        // without guilting anybody for not answering.
        //
        // #1144: the signature is appended once at the send layer, so this ends at its last sentence.
        return greeting + "\n\nI know \(show) has come and gone, and I hope it went well. If there's a "
            + "future performance you'd like documented, I'd be glad to help then. No need to reply to "
            + "this one."
    }

    // copy-inventory:ignore-end
}
