import Foundation

// #2878/#2828: the reply drafts that died on their way, as ROWS.
//
// `Recipient.isReplyDraftStalled` (#431) has decided this for a long time, and the Follow-ups pill has
// counted it for just as long, but nothing anywhere turned it into a list. So the pill said "1 reply
// draft stalled" and the sheet it opens said "Due 0" over an empty state about a different subject
// entirely (Dan, 2026-08-17, two screenshots seconds apart).
//
// A pill's number is a promise about rows (#863), and the way that promise is kept is that the count and
// the list are ONE derivation rather than two that happen to agree (L16). This is that derivation: the
// pill counts what this returns, `DueWork` counts what this returns, and `FollowUpsView` renders what
// this returns.
//
// Deliberately a rendering of the existing predicate, never a second copy of it. Asking the same
// question a second way here is exactly how the count and the list came apart in the first place.
enum StalledReplyDraft {
    // Mirrors `FollowUp.DueRecipient` and `PostEventPrompt.DueRecipient`: the show and the contact whose
    // conversation this is, because the row has to name which conversation stalled and not merely that
    // one did.
    struct DueRecipient {
        let prospect: Prospect
        let recipient: Recipient
        // Carried unwrapped, so the row's sentence has no absent case to describe. `isReplyDraftStalled`
        // cannot be true without this stamp, so an optional here would only ever produce a branch of copy
        // Overture could not say, which is a sentence in `docs/copy-inventory.md` claiming something
        // false about the product (L29).
        let requestedAt: Date
    }

    // `runAlive` is required and carries no default, for the reason `sourceCalendars` carries none on the
    // rows below it (L168): a caller that forgot it would silently report a run still drafting as a dead
    // one, which is #471's defect, and would get a wrong list rather than a compile error.
    //
    // The `compactMap` cannot drop a row the filter accepted (the filter's own first guard is that this
    // stamp exists), and if it ever could, the pill's count is taken from THIS list, so both halves would
    // lose the row together rather than coming apart, which is the whole property this file exists for.
    //
    // Oldest request first, so the one that has been stranded longest is the one Dan meets at the top.
    static func dueRecipients(from prospects: [Prospect], now: Date, runAlive: Bool) -> [DueRecipient] {
        prospects
            .flatMap { p in
                p.recipients
                    .filter { $0.isReplyDraftStalled(now: now, runAlive: runAlive) }
                    .compactMap { r in
                        r.replyDraftRequestedAt.map { DueRecipient(prospect: p, recipient: r, requestedAt: $0) }
                    }
            }
            .sorted { $0.requestedAt < $1.requestedAt }
    }
}

// What this section says on screen. Beside the rule rather than inside the view, so the sentence Dan
// reads is testable and so the section's heading and its rows cannot come to describe different things.
enum StalledReplyDraftCopy {
    static let section = "Stalled reply drafts"

    // Says what happened and when, because "stalled" alone does not tell Dan whether this died a minute
    // ago or last Tuesday, and that is the whole of what decides whether he waits or presses again.
    static func line(requestedAt: Date, now: Date) -> String {
        "You asked for this reply draft \(ago(requestedAt, now: now)) and it never arrived."
    }

    // The action, so the row is somewhere to act rather than somewhere to read that something is wrong
    // (#80, #126). Names what it does: this asks for the draft again, it does not send anything.
    static let tryAgain = "Draft it again"

    // Said where nothing is stalled, drafting, or otherwise waiting, so the sheet's own empty state can
    // name every subject it holds rather than two of the three (L11).
    static let nothingStalled = "A reply draft that stalls before it arrives appears here too."

    private static func ago(_ date: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}
