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
        // #3890: conversations where somebody wrote back and is waiting on Dan's answer, scouted shows
        // and hire inquiries both. The count the Dock and menu bar exist to show, and the one #2397 took
        // out of this total without anything replacing it.
        var repliesToAnswer: Int = 0

        var total: Int {
            followUps + afterTheShow + conversationsToConfirm + stalledReplyDrafts + repliesToAnswer
        }
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
        // #2967: these are DRAWN now, in their own section of the sheet the count heads. They used to
        // be counted here and rendered only on the Reached out row, so the header could stand over
        // fewer rows than it promised, which is #863 in the one place that exists to prevent it.
        var conversationsToConfirm: [ProposedConversation.DueRecipient] = []
        // #3890: drawn first, in their own section, because a person waiting on an answer is the most
        // time sensitive thing on the sheet (L609).
        var repliesToAnswer: [ReplyToAnswer.DueConversation] = []

        // What FollowUpsView actually DRAWS. Named apart from the count below on purpose: the whole
        // defect was a number and a list that were not the same thing.
        var rendered: Int {
            afterTheShow.count + silent.count + stalledReplyDrafts.count + conversationsToConfirm.count
                + repliesToAnswer.count
        }
        var isEmpty: Bool { rendered == 0 }

        // Derived from the lists rather than measured beside them, so the number the sheet's header
        // states cannot be a second opinion about what the sheet holds (L16).
        var counts: Counts {
            Counts(followUps: silent.count, afterTheShow: afterTheShow.count,
                   conversationsToConfirm: conversationsToConfirm.count,
                   stalledReplyDrafts: stalledReplyDrafts.count,
                   repliesToAnswer: repliesToAnswer.count)
        }
    }

    // `replyRunAlive` is required and carries no default (L168). A caller that forgot it would report a
    // classify run still beating as a dead one (#471), which is a wrong list and a wrong badge rather
    // than a compile error.
    static func rows(prospects: [Prospect], inquiries: [Inquiry], now: Date, replyRunAlive: Bool,
                     followUp: FollowUpConfig = .init()) -> Rows {
        // #2967 state 2: one form pitch on a show that has been and gone is owed BOTH questions at
        // once, and counting it twice put "Due 2" over one contact. The confirm question wins and the
        // post-event prompt yields, because how a show ended cannot be answered honestly while it is
        // still unsettled whether the act ever replied; answering the confirm re-decides what the other
        // prompt should even say. Suppressed here, in the one place that decides what the sheet holds,
        // rather than in the view, so the number and the rows cannot disagree about it (L16).
        let toConfirm = ProposedConversation.dueRecipients(from: prospects)
        let confirmKeys = Set(toConfirm.map(\.recipient.id))
        // #3890: two more of the same shape, each settled here for the same reason.
        //
        // A reply whose requested draft DIED is already listed, as the stalled draft with its own remedy,
        // so its conversation is not listed a second time as a reply to answer.
        //
        // And a passed show whose reply is unanswered is ONE thing, the answer: the post-event prompt for
        // that conversation yields until Dan has answered, then comes back. Dan's call, 2026-09-15, on
        // the same reasoning as the confirm rule above: how a show ended is often exactly what the reply
        // is about, so it is asked once the conversation is dealt with rather than beside it.
        let stalled = StalledReplyDraft.dueRecipients(from: prospects, now: now, runAlive: replyRunAlive)
        let stalledConversations = Set(stalled.map { SendGroup.groupKey($0.recipient) })
        let replies = ReplyToAnswer.dueConversations(prospects: prospects, inquiries: inquiries)
            .filter { conversation in
                guard case .show(_, let r) = conversation else { return true }
                return !stalledConversations.contains(SendGroup.groupKey(r))
            }
        let waitingConversations = Set(replies.compactMap { conversation -> String? in
            guard case .show(let p, let r) = conversation else { return nil }
            return "\(p.naturalKey)|\(SendGroup.groupKey(r))"
        })
        return Rows(afterTheShow: PostEventPrompt.dueRecipients(from: prospects, now: now)
                .filter { !confirmKeys.contains($0.recipient.id) }
                .filter { !waitingConversations.contains("\($0.prospect.naturalKey)|\(SendGroup.groupKey($0.recipient))") },
             // Oldest pitch first, which is the order the sheet showed before this ordering moved here
             // from its body: one place decides what the list holds AND what order it is in.
             silent: FollowUp.dueRecipients(from: prospects, now: now, config: followUp)
                .sorted { ($0.recipient.sentAt ?? .distantPast) < ($1.recipient.sentAt ?? .distantPast) },
             stalledReplyDrafts: stalled,
             // The SAME function the Reached out row is built from, never a second predicate that
             // happens to agree today (L16).
             conversationsToConfirm: toConfirm,
             repliesToAnswer: replies)
    }

    static func counts(prospects: [Prospect], inquiries: [Inquiry], now: Date, replyRunAlive: Bool,
                       followUp: FollowUpConfig = .init()) -> Counts {
        rows(prospects: prospects, inquiries: inquiries, now: now, replyRunAlive: replyRunAlive,
             followUp: followUp).counts
    }

    // #4110: the toolbar badge's number AND the instant it could next change, worked out together.
    //
    // ONE VALUE rather than two calls, and that is the whole point. Both halves are whole-store sweeps
    // over every prospect and every recipient, so a caller that memoised the count and then asked
    // `nextChange` separately to decide whether the memo was still good would pay on the cheap path
    // exactly what the memo exists to save (L431: a guard that skips expensive work saves nothing unless
    // computing its key is cheaper than the work).
    //
    // They are also ONE FACT: a count, and the moment after which that count is no longer the answer.
    // Held apart they could be taken at different instants and describe different stores (L544).
    struct CountAndNextChange: Equatable, Sendable {
        let total: Int
        // Nothing where no rule already in play has a future moment, which is a real answer and not an
        // absence: it means the clock alone cannot change this number, so a memo of it never needs to
        // expire on time.
        let couldChangeAt: Date?
    }

    static func countAndNextChange(prospects: [Prospect], inquiries: [Inquiry], now: Date,
                                   replyRunAlive: Bool,
                                   followUp: FollowUpConfig = .init()) -> CountAndNextChange {
        CountAndNextChange(
            total: counts(prospects: prospects, inquiries: inquiries, now: now,
                          replyRunAlive: replyRunAlive, followUp: followUp).total,
            couldChangeAt: nextChange(prospects: prospects, now: now, replyRunAlive: replyRunAlive,
                                      followUp: followUp))
    }
}

// #885: the toolbar pill's own title. It hides its count when there is nothing due, so a zero never sits
// on the masthead pretending to be work.
extension DueWork {
    static func badgeTitle(count: Int) -> String { count == 0 ? "Due" : "Due (\(count))" }
}

extension DueWork {
    // #3474: the next instant at which this count could GROW, so the two surfaces outside the app can
    // be republished when it does rather than up to half an hour later.
    //
    // The badge lives on the Dock tile and beside the menu bar glyph, which exist precisely for when
    // the window is closed. With the window closed nothing re-renders, so a clock is the only thing
    // that can republish, and the only clock was the 30 minute reconcile. A post-event prompt comes due
    // at Eastern midnight, so newly due work was invisible on both of them until the next tick.
    //
    // Three of the four rules are time driven and each already knows its own moment, so this asks them
    // rather than restating any of their arithmetic (L107). `conversationsToConfirm` is not here because
    // it is not time driven: a proposal appears when a mailbox sweep stores one, which is a store change
    // and already republishes through the render.
    //
    // What it CLAIMS, exactly, because a name like this invites more (L11): the earliest future moment
    // at which a rule ALREADY IN PLAY comes due, judged on the eligibility that holds right now.
    // Eligibility can itself change with the clock, so this is a lower bound on the next change and not
    // a promise to catch every one. The periodic reconcile stays as the backstop that covers the rest;
    // this makes the common case immediate instead of making the backstop unnecessary.
    static func nextChange(prospects: [Prospect], now: Date, replyRunAlive: Bool,
                           followUp: FollowUpConfig = .init()) -> Date? {
        var soonest: Date?
        func consider(_ moment: Date?) {
            guard let moment, moment > now else { return }   // already passed is already counted
            if let best = soonest, best <= moment { return }
            soonest = moment
        }
        for p in prospects {
            // The same two stoppers `FollowUp.dueRecipients` applies to a whole show, so this cannot
            // arm a republish for a show whose follow-ups have stopped.
            let followUpsStopped = p.outcomeSourceRaw == OutcomeSource.manual.rawValue || p.outcome == .booked
            for r in p.recipients {
                consider(PostEventPrompt.nextPromptDate(for: r, of: p))
                if !followUpsStopped {
                    consider(FollowUp.nextDue(eligible: FollowUp.isAwaitingNudge(r, in: p, now: now),
                                              sentAt: r.sentAt, lastFollowUpAt: r.lastFollowUpAt,
                                              followUpCount: r.followUpCount,
                                              remindedAt: r.nudgeRemindedAt, config: followUp))
                }
                // A draft still being written is not stalled however long it has taken (#471), so a live
                // run has no pending moment at all rather than one further out.
                if !replyRunAlive, let requested = r.awaitedReplyDraftRequestedAt {
                    consider(requested.addingTimeInterval(Recipient.replyDraftStallTimeout))
                }
            }
        }
        return soonest
    }
}
