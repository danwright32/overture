import Foundation

// #2398: a pitch that has spent its nudges, and the line that says so.
//
// Dan's rule has two halves and they pull in opposite directions, which is why this exists. Nothing is
// closed unless he closed it: "Assume it's not closed lost if I haven't set a state that says it's closed."
// And the emails stay capped where they are: "Two nudges and then stop until the date of the show. Maybe add
// a flag that tells me I've emailed them three times already so no more nudges."
//
// So the show STAYS on the Reached out stage with nothing due, which is a state the row could not previously
// describe. A spent row and a row nobody has got round to rendered as the same thing, which is #2388's class
// of defect exactly: two different states wearing one sentence.
enum SpentNudges {
    // A contact whose nudges are used up. Read off the same cap the sequencer enforces, so the marker cannot
    // claim the emails are done while another one is still queued to go.
    static func isSpent(_ r: Recipient, config: FollowUpConfig = .init()) -> Bool {
        r.sendState == .sent && r.followUpCount >= config.maxFollowUps
    }

    // The SHOW is spent when every contact that was actually emailed is. A colleague with a nudge left is a
    // show that still has something to send, and saying otherwise would be a promise Overture then breaks by
    // sending one.
    static func isSpent(show p: Prospect, config: FollowUpConfig = .init()) -> Bool {
        let emailed = p.recipients.filter { $0.sendState == .sent }
        guard !emailed.isEmpty else { return false }
        return emailed.allSatisfy { isSpent($0, config: config) }
    }

    // What the row says. Names the count, which is Dan's own ask ("a flag that tells me I've emailed them
    // three times already"), and then what happens NEXT: a line that only said the nudges had stopped would
    // leave him wondering whether the show had been dropped.
    //
    // The count is the pitch PLUS the follow-ups, because that is the number of emails the person received,
    // which is what he asked to be told.
    //
    // nil is not a case here: this is only ever called for a row already known to be spent, and returning an
    // optional would invite a caller to render an empty marker beside a row that had gone quiet.
    static func marker(eventDay: String?, today: String, config: FollowUpConfig = .init()) -> String? {
        let emails = config.maxFollowUps + 1
        // No date to come back on, and none is invented: "date to be confirmed" is a normal state on a season
        // page, and a fabricated night would send Dan looking for a show nobody published (#2169's rule).
        guard let eventDay, EasternDate.daysUntil(from: today, to: eventDay) != nil else {
            return "\(emails) emails sent. Nothing more until you close this out."
        }
        return "\(emails) emails sent. Nothing more until the show."
    }
}
