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
        let due = rows(from: prospects, contacts: { $0.recipients }, inquiries: inquiries, now: now,
                       replyRunAlive: replyRunAlive, followUp: followUp)
        return Rows(
            afterTheShow: due.afterTheShow.map {
                PostEventPrompt.DueRecipient(prospect: $0.prospect, recipient: $0.recipient, prompt: $0.prompt)
            },
            silent: due.silent.map { FollowUp.DueRecipient(prospect: $0.prospect, recipient: $0.recipient) },
            stalledReplyDrafts: due.stalledReplyDrafts.map {
                StalledReplyDraft.DueRecipient(prospect: $0.prospect, recipient: $0.recipient, requestedAt: $0.requestedAt)
            },
            conversationsToConfirm: due.conversationsToConfirm.map {
                ProposedConversation.DueRecipient(prospect: $0.prospect, recipient: $0.recipient, candidate: $0.candidate)
            },
            repliesToAnswer: due.repliesToAnswer)
    }

    // #4357 slice E2: the five lists over any rows, with the contacts handed in, so the model entry point
    // above walks the recipients it always did and a retained row answers by the one body. Each list keeps
    // its term's own row shape; the model entry point wraps them in the structs the sheet draws.
    struct Due<Row: ProspectFacts> {
        var afterTheShow: [(prospect: Row, recipient: Row.Contact, prompt: PostEventPrompt.Prompt)]
        var silent: [(prospect: Row, recipient: Row.Contact)]
        var stalledReplyDrafts: [(prospect: Row, recipient: Row.Contact, requestedAt: Date)]
        var conversationsToConfirm: [(prospect: Row, recipient: Row.Contact, candidate: ProposedConversation.Candidate)]
        var repliesToAnswer: [ReplyToAnswer.Conversation<Row>]

        var counts: Counts {
            Counts(followUps: silent.count, afterTheShow: afterTheShow.count,
                   conversationsToConfirm: conversationsToConfirm.count,
                   stalledReplyDrafts: stalledReplyDrafts.count,
                   repliesToAnswer: repliesToAnswer.count)
        }
    }

    static func rows<Row: ProspectFacts>(from shows: [Row], contacts: (Row) -> [Row.Contact], inquiries: [Inquiry],
                                         now: Date, replyRunAlive: Bool,
                                         followUp: FollowUpConfig = .init()) -> Due<Row> {
        // #2967 state 2: one form pitch on a show that has been and gone is owed BOTH questions at
        // once, and counting it twice put "Due 2" over one contact. The confirm question wins and the
        // post-event prompt yields, because how a show ended cannot be answered honestly while it is
        // still unsettled whether the act ever replied; answering the confirm re-decides what the other
        // prompt should even say. Suppressed here, in the one place that decides what the sheet holds,
        // rather than in the view, so the number and the rows cannot disagree about it (L16).
        //
        // #4531: every rule below is keyed by `conversation`, the show AND its conversation, never by a
        // contact's `id` alone. That `id` is an address or a form's URL, shared by every show it was pitched
        // for, so a question on one show used to silence a different question on another.
        let toConfirm = ProposedConversation.dueRecipients(from: shows, contacts: contacts, now: now)
        let confirmKeys = Set(toConfirm.map { conversation($0.prospect, $0.recipient) })
        // #3890: two more of the same shape, each settled here for the same reason.
        //
        // A reply whose requested draft DIED is already listed, as the stalled draft with its own remedy,
        // so its conversation is not listed a second time as a reply to answer.
        //
        // And a passed show whose reply is unanswered is ONE thing, the answer: the post-event prompt for
        // that conversation yields until Dan has answered, then comes back. Dan's call, 2026-09-15, on
        // the same reasoning as the confirm rule above: how a show ended is often exactly what the reply
        // is about, so it is asked once the conversation is dealt with rather than beside it.
        let stalled = StalledReplyDraft.dueRecipients(from: shows, contacts: contacts, now: now, runAlive: replyRunAlive)
        let stalledConversations = Set(stalled.map { conversation($0.prospect, $0.recipient) })
        let replies = ReplyToAnswer.dueConversations(prospects: shows, contacts: contacts, inquiries: inquiries)
            .filter { reply in
                guard case .show(let p, let r) = reply else { return true }
                return !stalledConversations.contains(conversation(p, r))
            }
        let waitingConversations = Set(replies.compactMap { reply -> String? in
            guard case .show(let p, let r) = reply else { return nil }
            return conversation(p, r)
        })
        return Due(afterTheShow: PostEventPrompt.dueRecipients(from: shows, contacts: contacts, now: now)
                .filter { !confirmKeys.contains(conversation($0.prospect, $0.recipient)) }
                .filter { !waitingConversations.contains(conversation($0.prospect, $0.recipient)) },
             // Oldest pitch first, which is the order the sheet showed before this ordering moved here
             // from its body: one place decides what the list holds AND what order it is in. #4531: and
             // two pitched at one instant by `showThenContact`, never the order the store handed them over.
             silent: FollowUp.dueRecipients(from: shows, contacts: contacts, now: now, config: followUp)
                .sorted { a, b in
                    let (sa, sb) = (a.recipient.sentAt ?? .distantPast, b.recipient.sentAt ?? .distantPast)
                    if sa != sb { return sa < sb }
                    return showThenContact(a.prospect, a.recipient, b.prospect, b.recipient)
                },
             stalledReplyDrafts: stalled,
             // The SAME function the Reached out row is built from, never a second predicate that
             // happens to agree today (L16).
             conversationsToConfirm: toConfirm,
             repliesToAnswer: replies)
    }

    static func counts(prospects: [Prospect], inquiries: [Inquiry], now: Date, replyRunAlive: Bool,
                       followUp: FollowUpConfig = .init()) -> Counts {
        counts(from: prospects, contacts: { $0.recipients }, inquiries: inquiries, now: now,
               replyRunAlive: replyRunAlive, followUp: followUp)
    }

    // #4357 slice G3: the same over any rows, with the contacts handed in, read by `AgentInputs.from` and by the
    // model entry point above. Slice E2 left it out because nothing read it yet. Counted off the generic lists
    // directly: the model entry point used to wrap every row in the sheet's structs only to count them, and the
    // counts of a wrapped list and of the list it wraps are the same numbers.
    static func counts<Row: ProspectFacts>(from shows: [Row], contacts: (Row) -> [Row.Contact], inquiries: [Inquiry],
                                           now: Date, replyRunAlive: Bool,
                                           followUp: FollowUpConfig = .init()) -> Counts {
        rows(from: shows, contacts: contacts, inquiries: inquiries, now: now, replyRunAlive: replyRunAlive,
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

// #4531: the two things every list on the Follow-ups sheet needs and none of them had.
extension DueWork {
    // The tie break after whatever a list sorts by: the show's natural key, then the store's identifier for
    // the show, then the contact's `id`, then the store's identifier for the contact. Each list runs over an
    // unsorted whole-store read and over a relationship SwiftData hands back in any order (L343), so a tie
    // left to arrival order reordered the sheet between launches on unchanged data (L419). The contact's
    // `id` is not enough on its own: it is an address, and one show can hold two contacts on one address.
    static func showThenContact<Row: ProspectFacts>(_ a: Row, _ ra: Row.Contact, _ b: Row, _ rb: Row.Contact) -> Bool {
        if a.naturalKey != b.naturalKey { return a.naturalKey < b.naturalKey }
        if a.persistentModelID != b.persistentModelID { return a.persistentModelID < b.persistentModelID }
        if ra.id != rb.id { return ra.id < rb.id }
        return ra.persistentModelID < rb.persistentModelID
    }

    // ONE conversation on ONE show: the show's natural key, which the store holds unique, and the send group
    // the contact belongs to. The rules in `rows(from:)` that let one question yield to another for the same
    // conversation all key on this, so a question on one show can never silence another show's.
    static func conversation<Row: ProspectFacts>(_ p: Row, _ r: Row.Contact) -> String {
        "\(p.naturalKey)|\(SendGroup.groupKey(r))"
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
        nextChange(from: prospects, contacts: { $0.recipients }, now: now, replyRunAlive: replyRunAlive,
                   followUp: followUp)
    }

    // #4357 slice E2: the same over any rows, with the contacts handed in. The show the post-event prompt
    // reads is built once per row, where the model path used to build it once per contact.
    static func nextChange<Row: ProspectFacts>(from shows: [Row], contacts: (Row) -> [Row.Contact], now: Date,
                                               replyRunAlive: Bool, followUp: FollowUpConfig = .init()) -> Date? {
        var soonest: Date?
        func consider(_ moment: Date?) {
            guard let moment, moment > now else { return }   // already passed is already counted
            if let best = soonest, best <= moment { return }
            soonest = moment
        }
        for p in shows {
            // The same two stoppers `FollowUp.dueRecipients` applies to a whole show, so this cannot
            // arm a republish for a show whose follow-ups have stopped.
            let followUpsStopped = FollowUp.nudgesStopped(on: p)
            let show = ReachedOutQueue.Show(p, contacts: contacts(p))
            for r in show.contacts {
                consider(PostEventPrompt.nextPromptDate(for: r, of: show))
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
