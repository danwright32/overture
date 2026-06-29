import Foundation

// The gentle re-touch sequencer (#45): decides who is DUE for a nudge and writes the nudge
// text. Up to maxFollowUps per lead, paced by gapDays; auto-stops the moment the outcome
// is anything but no-response (a reply or booking ends the sequence). Pure: it never sends
// — sending stays an explicit click (Dan's hard rule).
struct FollowUpConfig: Sendable {
    var gapDays: Int = 6
    var maxFollowUps: Int = 2
}

enum FollowUp {
    // The pacing core (#418 D): eligible AND sent AND under the cap AND the gap has passed since the
    // last touch. Eligibility differs by grain — see the two callers below.
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
    static func nudgeBody(contactName: String?, groupName: String, venue: String?, attempt: Int = 1) -> String {
        let venueClause = (venue?.isEmpty == false) ? " at \(venue!)" : ""
        let greeting = Salutation.greeting(for: contactName)
        let signoff = "\n\nBest,\nDan Wright\nDan Wright Photography"
        if attempt >= FollowUpConfig().maxFollowUps {
            return greeting + "\n\nOne last note on photographing \(groupName)\(venueClause). "
                + "If it would be useful down the line I'm glad to help, and if not, no need to reply. "
                + "I'll leave it here either way." + signoff
        }
        return greeting + "\n\nI wanted to follow up on my earlier note about photographing \(groupName)\(venueClause). "
            + "If a few sample frames from similar performances would be useful, I'm glad to send some over.\n\n"
            + "No problem if the timing isn't right." + signoff
    }
}
