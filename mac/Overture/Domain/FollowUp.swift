import Foundation

// The gentle re-touch sequencer (#45): decides who is DUE for a nudge and writes the nudge
// text. Up to maxFollowUps per lead, paced by gapDays; auto-stops the moment the outcome
// is anything but no-response (a reply or booking ends the sequence). Pure: it never sends:
// sending stays an explicit click (Dan's hard rule).
struct FollowUpConfig: Sendable {
    var gapDays: Int = 6
    var maxFollowUps: Int = 2
}

// #1740: what the stand-down control says. Beside the config it reads from, not inside the view, so the
// interval in the sentence and the interval the clock actually uses are one fact rather than two.
// #1740: which clock a row's "remind me later" moves. The two tracks have separate anchors, and moving
// the wrong one is not a no-op: the conversation anchor outranks the state's own date, so stamping it on
// a contact with no conversation makes that contact's first reminder read as already overdue.
enum StandDownTrack { case nudge, conversation }

// #1740: whether Dan is declining this ONE contact or the whole event. Both, because he decides at both
// grains (2026-07-30): "We should have both per show and per contact."
enum StandDownScope { case contact, show }

enum StandDownCopy {
    // Deliberately not "Dismiss": what Dan is declining is the SENDING, not the row. A label about the row
    // would read as "hide this", which is the one thing he said he did not want.
    static let menu = "Not this one"
    static let stop = "Stop sending to this contact"
    // Names the SHOW, because that is the decision: not working this event any more. The two sit together
    // so the grain is a choice he makes in the moment rather than one the app picks for him.
    static let stopShow = ShowOutcome.turnedThemDown.label
    // The closing-note row's own way out. Says what it does and what it does not do, because "done" and
    // "sent" are the two things it must not be confused between (Dan: "not sent but also done").
    static let closeOut = "Close this out without sending"

    static func pushOut(config: FollowUpConfig = .init()) -> String {
        "Remind me in \(config.gapDays) days"
    }

    // What the contact's own row says afterwards. Without it the card shows a contact with no follow-up
    // activity, which looks exactly like one nobody ever got to; this says the silence was a decision.
    // nil when there is nothing to report, so no row gains a line it did not have.
    //
    // Relative rather than a date, matching FormOutreach.awaitingQuestion: what Dan needs off this line is
    // how long ago he decided, not which Tuesday it was.
    static func standDownLine(stoodDownAt: Date?, now: Date) -> String? {
        guard let stoodDownAt else { return nil }
        return "You stopped sending to this contact \(ago(stoodDownAt, now: now))"
    }

    // #1740: the closing note still comes due on a show Dan stood down, and its row says so, because the
    // decision is months old by then and he is being asked whether to keep the door open for the NEXT
    // event. Without this the row reads as a nudge about a show he already walked away from.
    static func closingNoteOnStoodDownShow(stoodDownAt: Date?, now: Date) -> String? {
        guard let stoodDownAt else { return nil }
        return "You stopped working this show \(ago(stoodDownAt, now: now))"
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}

enum FollowUp {
    // The pacing core (#418 D): eligible AND sent AND under the cap AND the gap has passed since the
    // last touch. Eligibility differs by grain; see the two callers below.
    //
    // #2550: asked of `nextDue` rather than recomputing the anchor, so "is a nudge due" and "when is the
    // next nudge" are one rule. The reached-out row's timing text reads the second and its button reads the
    // first, and while they were two implementations they disagreed on a stood-down contact and on
    // "remind me later": the row printed "Reach out now" beside no control at all.
    static func isDue(eligible: Bool, sentAt: Date?, lastFollowUpAt: Date?, followUpCount: Int,
                      remindedAt: Date? = nil, now: Date, config: FollowUpConfig = .init()) -> Bool {
        guard let due = nextDue(eligible: eligible, sentAt: sentAt, lastFollowUpAt: lastFollowUpAt,
                                followUpCount: followUpCount, remindedAt: remindedAt, config: config)
        else { return false }
        return now >= due
    }

    // WHEN the next nudge comes due, or nil if this contact has no nudge left to come due at all
    // (ineligible, never sent, or the cap is spent). Same eligibility and same anchor as `isDue`, because
    // it IS `isDue`'s anchor.
    static func nextDue(eligible: Bool, sentAt: Date?, lastFollowUpAt: Date?, followUpCount: Int,
                        remindedAt: Date? = nil, config: FollowUpConfig = .init()) -> Date? {
        guard eligible, let sentAt else { return nil }
        guard followUpCount < config.maxFollowUps else { return nil }
        // #1740: "remind me later" moves the clock without pretending a nudge was sent, so the anchor is
        // whichever touch is most recent. `lastFollowUpAt` keeps meaning a nudge actually went.
        let lastTouch = [lastFollowUpAt, remindedAt, sentAt].compactMap { $0 }.max() ?? sentAt
        return lastTouch.addingTimeInterval(TimeInterval(config.gapDays) * 86_400)
    }

    // #1740: eligible for a NUDGE specifically, which is the silent-follow-up eligibility plus Dan's own
    // stand-down. Deliberately NOT folded into `Recipient.isAwaitingFollowUp`: that predicate also drives
    // the Reached out decide clock (`ReachedOutQueue`), and "stop writing to this one" is not "I have
    // decided what happened to this lead". Widening it there would quietly hide a lead he still owes an
    // answer, which is a worse failure than the one being fixed.
    //
    // Every surface that OFFERS or SENDS a nudge reads this one predicate, so the row, the Due count and
    // the send path cannot disagree about who is due (#863: a count is a promise about rows).
    // Two grains, because Dan decides at both (2026-07-30): this contact, or the whole show. The show
    // grain is a fact on the SHOW rather than a stamp copied onto each contact, so a contact added later
    // is covered by a decision made before it existed.
    // The show is NOT defaulted, and that is the whole point. A default here is exactly the shape #1679
    // was: the send path had already been written asking about the contact alone, which silently ignored a
    // show Dan had walked away from, and it compiled and passed either way. Required, so forgetting it is
    // a compile error rather than a nudge sent about an event he was finished with.
    static func isAwaitingNudge(_ r: Recipient, in p: Prospect) -> Bool {
        guard r.isAwaitingFollowUp, !r.isOutreachStoodDown else { return false }
        return !p.isOutreachStoodDown(asOf: r.repliedAt)
    }

    // Lead-level (legacy / single-contact): eligible = outcome is still no-response (auto-stop on a
    // reply/booking/loss). Delegates to the pacing core so there's one gap/cap implementation.
    static func isDue(sentAt: Date?, lastFollowUpAt: Date?, followUpCount: Int,
                      outcome: Outcome, now: Date, config: FollowUpConfig = .init()) -> Bool {
        isDue(eligible: outcome == .noResponse, sentAt: sentAt, lastFollowUpAt: lastFollowUpAt,
              followUpCount: followUpCount, now: now, config: config)
    }

    // Lead-level due filter (still used by the conversation/sequencer-standdown tests). The app's UI
    // now uses dueRecipients (per-contact); this remains the lead-grain view of the same pacing.
    static func due(from prospects: [Prospect], now: Date, config: FollowUpConfig = .init()) -> [Prospect] {
        prospects.filter {
            isDue(sentAt: $0.sentAt, lastFollowUpAt: $0.lastFollowUpAt, followUpCount: $0.followUpCount,
                  outcome: $0.outcome, now: now, config: config)
        }
    }

    struct DueRecipient { let prospect: Prospect; let recipient: Recipient }

    static func dueRecipients(from prospects: [Prospect], now: Date, config: FollowUpConfig = .init()) -> [DueRecipient] {
        var due: [DueRecipient] = []
        for p in prospects {
            // A hand-resolved or booked show stops all its follow-ups (matches the lead-level auto-stop).
            if p.outcomeSourceRaw == OutcomeSource.manual.rawValue || p.outcome == .booked { continue }
            // #2033: one row per EMAIL. Contacts who received one shared email are one conversation to
            // chase, and two rows would be two buttons doing the same thing to the same thread.
            //
            // #2126: due FIRST, collapse after. ANDed with the old lowest-id test this dropped the whole
            // conversation whenever the alphabetically first contact was the one not due, so a colleague's
            // overdue nudge vanished behind a contact who had already declined.
            let dueHere = p.recipients.filter { r in
                isDue(eligible: isAwaitingNudge(r, in: p), sentAt: r.sentAt,
                      lastFollowUpAt: r.lastFollowUpAt, followUpCount: r.followUpCount,
                      remindedAt: r.nudgeRemindedAt, now: now, config: config)
            }
            due.append(contentsOf: SendGroup.oneRowPerGroup(dueHere) { $0 }
                .map { DueRecipient(prospect: p, recipient: $0) })
        }
        return due
    }

    // #885: which nudge THIS one is. `followUpCount` is how many have already gone; the one about to go
    // is the next. Trivial arithmetic, and it was written twice: once for the label Dan reads on the row
    // (FollowUpsView), once for the `attempt:` that decides which of the two nudge bodies a stranger
    // receives (requestNudge). Two independent statements of one off-by-one, neither testable. Drift and
    // the row says "nudge 1 of 2" while the email is written as the softer last note, or the reverse.
    static func attempt(after followUpCount: Int) -> Int { followUpCount + 1 }

    // The row's line: who this goes to, and where it sits in the sequence.
    static func nudgeLabel(email: String?, followUpCount: Int, config: FollowUpConfig = .init()) -> String {
        let to = (email?.isEmpty == false) ? email! : "no contact"
        return "\(to) · nudge \(attempt(after: followUpCount)) of \(config.maxFollowUps)"
    }

    // #948: the exact subject and body a follow-up nudge will send, in ONE place, so the branded
    // confirmation sheet (SendConfirmation.init(followUpFor:of:)) and the sender (SendService.sendFollowUp)
    // read the same values. Before this, the confirm preview built its subject from `nudgeSubject` while
    // the send used `replySubject`, so Dan confirmed one subject and a different one went out. Pure
    // (primitives in, strings out): no model access, no actor, testable on its own.
    struct NudgeContent: Equatable, Sendable { let subject: String; let body: String }

    static func nudgeContent(originalSubject: String?, groupName: String, isMerged: Bool = false,
                             contactName: String?, venue: String?, followUpCount: Int) -> NudgeContent {
        // #1276: sanitize ONCE here, the single chokepoint both SendService and the confirm sheet call,
        // then hand the safe name to the leaves. Keeps every subject/body path covered without each leaf
        // re-deciding.
        let name = safeDisplayName(groupName, isMerged: isMerged)
        return NudgeContent(
            subject: replySubject(originalSubject: originalSubject, groupName: name),
            body: nudgeBody(contactName: contactName, groupName: name,
                            venue: safeVenue(venue), attempt: attempt(after: followUpCount)))   // #1273
    }

    // copy-inventory:ignore-start  outbound email: a recipient reads this, not Dan (#915)
    //
    // Everything to the ignore-end below is what Dan SENDS, not what Overture SAYS to him, so it stays
    // out of the copy inventory, which is a list of the app's own voice. What goes to a stranger has its
    // own guard: the draft lint (#789), which reads it before it can leave.

    // #1260 Phase 1 / #1276: a merged same-date+venue prospect (SameDateVenueMerge, #1236) carries a
    // conductor-LIST groupName ("We Sing Noel; Craig Courtney; The Four Freedoms"). Right on screen,
    // wrong in an outbound email under Dan's name. The nudge/reminder paths interpolate the name verbatim
    // with NO edit surface (unlike the AI-drafted pitch, which Dan reviews). So substitute a neutral
    // brand-voice phrase for a merged name. #1276: keyed on the PERSISTED merge fact (isMerged), not a
    // "; " sniff, because a legitimate single title (Carnegie's "Symphony of Psalms & Les Noces
    // (Stravinsky); No Time for Idle Tears") also carries that separator and must keep its real name.
    static let mergedNameSubstitute = "your upcoming performance"

    static func safeDisplayName(_ groupName: String, isMerged: Bool) -> String {
        isMerged ? mergedNameSubstitute : groupName
    }

    // #1273: the venue's counterpart to safeDisplayName. The nudge/reminder bodies interpolate the venue
    // verbatim ("photographing X at <venue>") with NO edit surface. A stored venue has already cleared the
    // ingest guard (ExtractedEventGuard rejects a missing/placeholder/numeric-id venue), so the residual
    // risk is a value that is present but not presentable in a sentence to a stranger: a line break or
    // control character from a bad scrape, which that ingest guard never checks for ("Carnegie Hall\n881
    // 7th Ave" is a storable venue that would inject a newline mid-sentence). Returns a clean venue to
    // interpolate, or nil to DROP the " at <venue>" clause entirely (a placeless nudge still reads fine),
    // never an ugly one. Applied once at each nudgeContent chokepoint, like safeDisplayName, so both send
    // paths and their confirmation sheets agree.
    static func safeVenue(_ venue: String?) -> String? {
        guard let raw = venue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // A line break or control character in a venue name is a scrape artifact, not a real room; drop the
        // whole clause rather than send a broken sentence under Dan's name.
        let unsafe = CharacterSet.controlCharacters.union(.newlines)
        if raw.unicodeScalars.contains(where: { unsafe.contains($0) }) { return nil }
        // Collapse any internal run of whitespace to a single space (a flattened multi-space scrape).
        return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func nudgeSubject(groupName: String) -> String {
        "Following up: photographs for \(groupName)"
    }

    // A follow-up replies on the original thread, so its subject is the original with a single
    // "Re:" prefix (Gmail wants a matching subject to thread). Falls back to the nudge subject
    // if the original is missing (#74).
    static func replySubject(originalSubject: String?, groupName: String) -> String {
        let base = (originalSubject?.isEmpty == false) ? originalSubject! : nudgeSubject(groupName: groupName)
        return base.lowercased().hasPrefix("re:") ? base : "Re: \(base)"
    }

    // A short, low-key nudge in Dan's voice: no performative enthusiasm, no em dashes. The
    // final nudge (attempt == maxFollowUps) reads as a softer last note so the second touch
    // isn't a verbatim repeat of the first (#75).
    // #1144: no sign-off here any more. Every outbound email's signature is appended once at the send
    // layer (GmailMessage, from OutboundSignature), so this body ends at its last sentence and the styled
    // signature reaches follow-ups too, not just a flat "Best, Dan" line.
    static func nudgeBody(contactName: String?, groupName: String, venue: String?, attempt: Int = 1) -> String {
        let venueClause = (venue?.isEmpty == false) ? " at \(venue!)" : ""
        let greeting = Salutation.greeting(for: contactName)
        if attempt >= FollowUpConfig().maxFollowUps {
            return greeting + "\n\nOne last note on photographing \(groupName)\(venueClause). "
                + "If it would be useful down the line I'm glad to help, and if not, no need to reply. "
                + "I'll leave it here either way."
        }
        return greeting + "\n\nI wanted to follow up on my earlier note about photographing \(groupName)\(venueClause). "
            + "If a few sample frames from similar performances would be useful, I'm glad to send some over.\n\n"
            + "No problem if the timing isn't right."
    }
    // copy-inventory:ignore-end
}
