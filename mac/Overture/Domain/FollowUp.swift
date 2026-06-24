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
    static func isDue(sentAt: Date?, lastFollowUpAt: Date?, followUpCount: Int,
                      outcome: Outcome, now: Date, config: FollowUpConfig = .init()) -> Bool {
        guard let sentAt else { return false }              // must have been sent first
        guard outcome == .noResponse else { return false }  // auto-stop on reply/booked/lost
        guard followUpCount < config.maxFollowUps else { return false } // stop after the max
        let lastTouch = lastFollowUpAt ?? sentAt
        return now.timeIntervalSince(lastTouch) >= TimeInterval(config.gapDays) * 86_400
    }

    static func due(from prospects: [Prospect], now: Date, config: FollowUpConfig = .init()) -> [Prospect] {
        prospects.filter {
            isDue(sentAt: $0.sentAt, lastFollowUpAt: $0.lastFollowUpAt, followUpCount: $0.followUpCount,
                  outcome: $0.outcome, now: now, config: config)
        }
    }

    static func nudgeSubject(groupName: String) -> String {
        "Following up: photographs for \(groupName)"
    }

    // A short, low-key nudge in Dan's voice: no performative enthusiasm, no em dashes. The
    // final nudge (attempt == maxFollowUps) reads as a softer last note so the second touch
    // isn't a verbatim repeat of the first (#75).
    static func nudgeBody(contactName: String?, groupName: String, venue: String?, attempt: Int = 1) -> String {
        let venueClause = (venue?.isEmpty == false) ? " at \(venue!)" : ""
        let greeting = "Hi \(firstName(contactName)),"
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

    private static func firstName(_ name: String?) -> String {
        guard let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return "there" }
        return n.split(separator: " ").first.map(String.init) ?? "there"
    }
}
