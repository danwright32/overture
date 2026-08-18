import Foundation

// #885: what is DUE, defined once.
//
// Two views summed this for themselves: RootView's toolbar badge (`followUpsDue`) and FollowUpsView's
// own header count. Same rule, written twice, in two bodies no test can reach. They agreed only because
// they happened to read the same stored settings, and nothing asserted that they did.
//
// The number on the pill Dan clicks and the number on the sheet he lands on must be the same number by
// construction, not by coincidence. A badge that disagrees with the list behind it is the #863 defect:
// a count is a promise about rows.
enum DueWork {
    struct Counts: Equatable, Sendable {
        var followUps: Int          // silent leads waiting on a gentle nudge
        // #2397: shows whose date has passed, waiting on a closing note or on Dan saying how it ended.
        var afterTheShow: Int
        // #2718: form and DM pitches where Overture has found a conversation that might be their reply
        // and is waiting on Dan to say whether it is theirs. It joins this count rather than sitting
        // quietly on a card because a quiet question would go unanswered until the show had been and
        // gone (his call, 2026-08-14), and because a proposal shown in Reached out but excluded here
        // would give a pill whose number is smaller than the list behind it.
        var conversationsToConfirm: Int = 0
        // #2878/#2828: reply drafts Dan asked for that died before arriving. Counted here as well as on
        // the Follow-ups pill because this number is what the sheet's own header states: without it the
        // pill read "1 reply draft stalled" and the sheet behind it read "Due 0".
        var stalledReplyDrafts: Int = 0

        var total: Int { followUps + afterTheShow + conversationsToConfirm + stalledReplyDrafts }
    }

    // #2878/#2828: the ROWS behind the number, so the two are one derivation rather than two that happen
    // to agree today (L16). `Counts` is derived from these lists rather than measured beside them, so a
    // number can no longer be stated over rows nobody produced, and a member the sheet does not render
    // is visible HERE as one rather than being invisible in a separate count. There is exactly one such
    // member today, `conversationsToConfirm`, and the guard in `StalledReplyDraftSectionTests` names it
    // so a second cannot arrive quietly.
    struct Rows {
        var afterTheShow: [PostEventPrompt.DueRecipient] = []
        var silent: [FollowUp.DueRecipient] = []
        var stalledReplyDrafts: [StalledReplyDraft.DueRecipient] = []
        // Counted, and rendered NOWHERE in the sheet the count heads: those rows are answered on the
        // Reached out row instead (#2718). Carried here rather than fetched separately by `counts` so
        // the gap is visible in the one type that says what the sheet holds, and so the guard in
        // `StalledReplyDraftSectionTests` can name it. Filed as #2967.
        var conversationsToConfirm: [ProposedConversation.DueRecipient] = []

        // What FollowUpsView actually DRAWS. Named apart from the count below on purpose: the whole
        // defect was a number and a list that were not the same thing.
        var rendered: Int { afterTheShow.count + silent.count + stalledReplyDrafts.count }
        var isEmpty: Bool { rendered == 0 }

        // Derived from the lists rather than measured beside them, so the number the sheet's header
        // states cannot be a second opinion about what the sheet holds (L16).
        var counts: Counts {
            Counts(followUps: silent.count, afterTheShow: afterTheShow.count,
                   conversationsToConfirm: conversationsToConfirm.count,
                   stalledReplyDrafts: stalledReplyDrafts.count)
        }
    }

    // `replyRunAlive` is required and carries no default (L168). A caller that forgot it would report a
    // classify run still beating as a dead one (#471), which is a wrong list and a wrong badge rather
    // than a compile error.
    static func rows(prospects: [Prospect], now: Date, replyRunAlive: Bool,
                     followUp: FollowUpConfig = .init()) -> Rows {
        Rows(afterTheShow: PostEventPrompt.dueRecipients(from: prospects, now: now),
             // Oldest pitch first, which is the order the sheet showed before this ordering moved here
             // from its body: one place decides what the list holds AND what order it is in.
             silent: FollowUp.dueRecipients(from: prospects, now: now, config: followUp)
                .sorted { ($0.recipient.sentAt ?? .distantPast) < ($1.recipient.sentAt ?? .distantPast) },
             stalledReplyDrafts: StalledReplyDraft.dueRecipients(from: prospects, now: now,
                                                                 runAlive: replyRunAlive),
             // The SAME function the Reached out row is built from, never a second predicate that
             // happens to agree today (L16).
             conversationsToConfirm: ProposedConversation.dueRecipients(from: prospects))
    }

    static func counts(prospects: [Prospect], now: Date, replyRunAlive: Bool,
                       followUp: FollowUpConfig = .init()) -> Counts {
        rows(prospects: prospects, now: now, replyRunAlive: replyRunAlive, followUp: followUp).counts
    }
}

// #885: the toolbar pill's own title. It hides its count when there is nothing due, so a zero never sits
// on the masthead pretending to be work.
extension DueWork {
    static func badgeTitle(count: Int) -> String { count == 0 ? "Due" : "Due (\(count))" }
}
