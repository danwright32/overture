import Foundation

// The gentle re-touch sequencer (#45): decides who is DUE for a nudge and writes the nudge
// text. Up to maxFollowUps per lead, paced by gapDays; auto-stops the moment the outcome
// is anything but no-response (a reply or booking ends the sequence). Pure: it never sends:
// sending stays an explicit click (Dan's hard rule).
struct FollowUpConfig: Sendable {
    var gapDays: Int = 6
    var maxFollowUps: Int = 2
}

enum FollowUp {
    // The pacing core (#418 D): eligible AND sent AND under the cap AND the gap has passed since the
    // last touch. Eligibility differs by grain; see the two callers below.
    static func isDue(eligible: Bool, sentAt: Date?, lastFollowUpAt: Date?, followUpCount: Int,
                      now: Date, config: FollowUpConfig = .init()) -> Bool {
        guard eligible, let sentAt else { return false }
        guard followUpCount < config.maxFollowUps else { return false }
        let lastTouch = lastFollowUpAt ?? sentAt
        return now.timeIntervalSince(lastTouch) >= TimeInterval(config.gapDays) * 86_400
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
            for r in p.recipients where isDue(eligible: r.isAwaitingFollowUp, sentAt: r.sentAt,
                                              lastFollowUpAt: r.lastFollowUpAt, followUpCount: r.followUpCount,
                                              now: now, config: config) {
                due.append(DueRecipient(prospect: p, recipient: r))
            }
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

    static func nudgeContent(originalSubject: String?, groupName: String,
                             contactName: String?, venue: String?, followUpCount: Int) -> NudgeContent {
        NudgeContent(
            subject: replySubject(originalSubject: originalSubject, groupName: groupName),
            body: nudgeBody(contactName: contactName, groupName: groupName,
                            venue: venue, attempt: attempt(after: followUpCount)))
    }

    // copy-inventory:ignore-start  outbound email: a recipient reads this, not Dan (#915)
    //
    // Everything to the ignore-end below is what Dan SENDS, not what Overture SAYS to him, so it stays
    // out of the copy inventory, which is a list of the app's own voice. What goes to a stranger has its
    // own guard: the draft lint (#789), which reads it before it can leave.

    // #1260 Phase 1: a merged same-date+venue prospect (SameDateVenueMerge, #1236) carries a
    // conductor-LIST groupName ("We Sing Noel; Craig Courtney; The Four Freedoms"). Right on screen,
    // wrong in an outbound email under Dan's name. The nudge/reminder paths below interpolate groupName
    // verbatim with NO edit surface (unlike the AI-drafted pitch, which Dan reviews). So substitute a
    // neutral brand-voice phrase whenever the name is a merged list. Detection is the "; " separator that
    // SameDateVenueMerge.combinedName is the sole producer of; a single real title never carries it.
    // (Phase 2 persists seriesId; a later tightening could gate on isMerged for exactness.) ConversationReminder
    // routes through this same helper, so the two send paths can never disagree on the substitution.
    static let mergedNameSubstitute = "your upcoming performance"

    static func safeDisplayName(_ groupName: String) -> String {
        groupName.contains("; ") ? mergedNameSubstitute : groupName
    }

    static func nudgeSubject(groupName: String) -> String {
        "Following up: photographs for \(safeDisplayName(groupName))"
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
        let name = safeDisplayName(groupName)
        if attempt >= FollowUpConfig().maxFollowUps {
            return greeting + "\n\nOne last note on photographing \(name)\(venueClause). "
                + "If it would be useful down the line I'm glad to help, and if not, no need to reply. "
                + "I'll leave it here either way."
        }
        return greeting + "\n\nI wanted to follow up on my earlier note about photographing \(name)\(venueClause). "
            + "If a few sample frames from similar performances would be useful, I'm glad to send some over.\n\n"
            + "No problem if the timing isn't right."
    }
    // copy-inventory:ignore-end
}
