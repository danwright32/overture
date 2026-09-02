import Foundation

// #863: what a pill is currently ABOUT, which is not the same as which pill it is.
//
// Scout, Prep and Review each ask one question, so their name was enough. Send never did: it reports
// whichever of five different problems is most urgent (an unconfirmed send, a failed one, one that
// cannot be watched for replies, a contact held for a check, or simply an approved email waiting on a
// click), and each of those names a DIFFERENT set of shows. Keyed by name, its tap could only ever
// resolve one of them, so "3 sent but can't be watched for replies" navigated to the approved queue,
// which contains none of them. That is #792 again: a pill that states a number and takes Dan nowhere.
//
// So navigation is keyed by the focus, and the focus is chosen once, by AgentRoster, when it decides
// what the pill says. One decision, one predicate, one destination.
// #2524: CaseIterable so a rule about "every stage except one" can be DERIVED rather than written as the
// list somebody remembered, which is the list that silently omits the stage added next (L96, L113).
enum StageFocus: String, Equatable, Sendable, CaseIterable {
    case scout, prep, review
    // #1583/#1691: kept, undrafted, and held back by a date clash that landed AFTER the keep. Its own focus
    // rather than a fold into `.prep`, on the same reasoning as the five send focuses: the Prep RUN still
    // refuses these shows, so counting them under Prep would state a number the run then does not work
    // through, which is the exact mismatch #863 exists to prevent. Before it existed these shows matched no
    // focus at all, and the queue is stage-scoped only, so they were rendered nowhere (#1691).
    case sendApproved, sendBlocked, sendErrors, sendStuck, sendDegraded
    // #2647: sent, but the real Message-ID Gmail assigned could not be read back, so Overture's NEXT
    // message on that conversation cannot reference it and a standards based client will file it as a
    // separate conversation. Its own focus rather than a fold into .sendDegraded, on the #863 rule: the
    // two name different sets of shows, so sharing one focus would state a number and land Dan on a
    // different list. It is also a different problem with a different consequence (their replies are
    // still watched fine here; it is OUR next message that comes adrift).
    case sendThreadingDegraded
    // Not a queue filter: the pill opens FollowUpsView, which lists the due RECIPIENTS itself.
    case followUps
    // #1134: like .followUps, not a matches-based focus. Its rows are per-recipient (rendered by
    // reachedOutList, not standard QueueItem rows), and its count comes from ReachedOutQueue, so it
    // resolves no queue keys here.
    case reachedOut
}

// #338/#370: the stage pills (Scout/Prep/Review/Send/Follow-ups) are real navigation, taking Dan to
// exactly the prospects the pill is counting. These criteria MUST match AgentRoster's own per-stage
// counts exactly, so what a pill shows is what tapping it navigates to.
//
// That rule is no longer maintained by hand: `AgentInputs.from` builds every count by calling THIS
// function, so a count and its destination are the same list, and the invariant holds by construction
// rather than by two places being edited together. It was stated here and unenforced for four months,
// and drifted twice in that time (#792, #861).
enum StageNavigation {
    // #1134: the queue opens on Scout, always (never auto-jumping to another stage even when Scout is
    // empty). A named constant, not a literal buried in the view, so the choice has a testable seam.
    static let openingStage: StageFocus = .scout

    static func naturalKeys(for focus: StageFocus, in prospects: [Prospect],
                            context: StageContext) -> [String] {
        prospects.filter { matches(focus, $0, context: context) }.map(\.naturalKey)
    }

    // #1134: which stage a deep-linked lead belongs to, so a tapped OmniFocus follow-up or a search pick
    // focuses the stage that actually contains the show now that the pipeline picker is gone. A
    // reached-out lead focuses .reachedOut (its rows come from ReachedOutQueue, keyed separately); every
    // other lead is placed by the same `matches` predicate the pills count with. nil for a lead in no
    // stage at all (RootView routes those to Archive instead).
    static func stage(containing key: String, in prospects: [Prospect], reachedOutKeys: Set<String>,
                      context: StageContext) -> StageFocus? {
        if reachedOutKeys.contains(key) { return .reachedOut }
        guard let p = prospects.first(where: { $0.naturalKey == key }) else { return nil }
        return countedFocuses.first { matches($0, p, context: context) }
    }

    // #1140: which rows the focused list shows. A stage pill (`stage` non-nil) re-derives its membership
    // LIVE from the current prospects on every render, so a show that leaves the stage (a draft sent, so
    // its status moves off `.drafted`) drops out of the focused list instead of lingering because the key
    // set was frozen at tap time. The #308 away-alert leads path (`stage` nil) is not a stage: it is a
    // specific named set Dan asked to see, so its keys are returned verbatim (the flat list renders
    // whichever of them still exist). This lives here, not in the SwiftUI view, so it can be tested at all
    // (the #863 lesson: a rule computed inside a view has no seam a test can reach).
    static func focusedKeys(stage: StageFocus?, leadKeys: [String], in prospects: [Prospect],
                            context: StageContext) -> [String] {
        guard let stage else { return leadKeys }
        return naturalKeys(for: stage, in: prospects, context: context)
    }

    // #1567: whether the Queue will show Dan this lead at all, which is what a global search pick and an
    // OmniFocus follow-up tap need to know before choosing between the Queue and Archive.
    //
    // LIVE-STORE-CLAIM verified=2026-07-26 measure="untriaged shows the deep-link filter and the stage lists disagreed about"
    // It is `stage(containing:)`, the SAME call the focused list renders from, because that is the only
    // honest answer: a stage list IS the Queue's content. This used to be QueueModel.isReachableForDeepLink,
    // a second filter (the 90-day window, the untouched-and-gone rule) that no stage list applies, so the
    // two disagreed about 137 of 589 untriaged shows on the live store. Searching for a November show
    // sitting in the Scout list opened ARCHIVE, which reads as "this show is gone" about a visible row.
    //
    // It closes a dead end in the other direction too: a contacted show with no send problem passed the
    // old date filter and then no stage rendered it, so the Queue opened on nothing (#792's failure mode).
    // A dismissed show, or a key no show answers to, is in no stage, so both still route to Archive.
    static func opensInQueue(key: String, in prospects: [Prospect], reachedOutKeys: Set<String>,
                             context: StageContext) -> Bool {
        stage(containing: key, in: prospects, reachedOutKeys: reachedOutKeys,
              context: context) != nil
    }

    // #1567: the shows behind the masthead's "N in the queue", which is every show a stage will render
    // apart from the ones already pitched. Reached-out leads stay out, as they always have: that line is
    // about work still to send, and Reached out has its own pill and its own per-recipient rows.
    //
    // LIVE-STORE-CLAIM verified=2026-07-26 measure="the masthead total against the sum of the stage pills beneath it, over untriaged shows"
    // Counted through the same `matches` predicate as the pill beneath it, so the masthead can no longer
    // read lower than the pills it sits above (452 against 589 on the live store). One pass over the
    // prospects, in the style of `counts` above, so a prospect's recipients fault at most once (#1121).
    static func queueKeys(in prospects: [Prospect], reachedOutKeys: Set<String>,
                          context: StageContext) -> Set<String> {
        var result = Set<String>()
        for p in prospects where !reachedOutKeys.contains(p.naturalKey) {
            if countedFocuses.contains(where: { matches($0, p, context: context) }) {
                result.insert(p.naturalKey)
            }
        }
        return result
    }

    // #1580: every show a stage will render, which is what the global search bar is allowed to find.
    // The masthead's `queueKeys` above plus the reached-out leads it deliberately leaves out: that line
    // is about work still to send, but Reached out is a real stage with its own pill and its own rows,
    // so a show Dan has pitched and is waiting on is still somewhere he can be taken.
    //
    // Written as the union rather than as a second sweep so it cannot drift from `opensInQueue`, which
    // is the same question asked of one key. `SearchScopedToQueueTests` holds the two to each other.
    static func stagedKeys(in prospects: [Prospect], reachedOutKeys: Set<String>,
                           context: StageContext) -> Set<String> {
        var result = queueKeys(in: prospects, reachedOutKeys: reachedOutKeys, context: context)
        for p in prospects where reachedOutKeys.contains(p.naturalKey) { result.insert(p.naturalKey) }
        return result
    }

    // Every focus that resolves queue keys. `.followUps` is excluded on purpose: it opens FollowUpsView
    // and resolves no keys (matches returns false), so counting it here would only ever add a zero.
    static let countedFocuses: [StageFocus] = [
        .scout, .prep, .review,
        .sendApproved, .sendBlocked, .sendErrors, .sendStuck, .sendDegraded, .sendThreadingDegraded
    ]

    // #1121: one pass over the prospects for ALL pill counts, instead of one full pass per focus. The
    // per-focus `naturalKeys` above still exists for navigation (a tap needs the keys, not just the
    // count), but the masthead only needs the counts, and computing nine of them meant nine traversals
    // that each re-faulted every prospect's `recipients` relationship on the main thread. Here each
    // prospect is visited once and every focus decided against it before moving on, so its recipients
    // fault at most once. It goes through the SAME private `matches` predicate as `naturalKeys`, so
    // counts[focus] is identical to naturalKeys(for: focus).count by construction, which is the #863
    // invariant (the number a pill shows is the rows its tap lands on). Pinned by StageNavigationCountsTests.
    // Which stage a hire inquiry belongs to (#1436). Only two apply: an inquiry Dan has not yet replied
    // to needs his action, so it sits in .review, a CLICKABLE pill he reaches (the #1436 walk found
    // .sendApproved has no navigable pill; it surfaces only in the masthead or a connect-Gmail button).
    // Once he has replied and is awaiting a response it moves to .reachedOut. A booked or hand-lost
    // inquiry is closed and in no stage. Pure and tested; the view and the counts both read it so they
    // cannot drift.
    static func stage(for inquiry: Inquiry) -> StageFocus? {
        guard inquiry.isOpen else { return nil }
        return inquiry.sentAt == nil ? .review : .reachedOut
    }

    static func counts(in prospects: [Prospect],
                       context: StageContext) -> [StageFocus: Int] {
        var result: [StageFocus: Int] = [:]
        for p in prospects {
            for focus in countedFocuses where matches(focus, p, context: context) {
                result[focus, default: 0] += 1
            }
        }
        return result
    }

    // #2359: the queue's far edge, applied to TRIAGE ALONE.
    //
    // Private, and asked from exactly one branch of `matches` below, because a second copy of this
    // judgment is the defect this whole milestone exists to prevent (#1567, #1575). The number itself
    // stays where it has always been, `QueueModel.leadTimeWindowDays`, beside `daysUntil` and
    // `tooCloseDays`, which are the rest of the same "how far out is this" family; moving it here alone
    // would separate it from the helper this line calls to use it.
    //
    // Deliberately NOT applied to any other stage. A show Dan has kept, prepped, drafted, approved or
    // pitched is work in flight, and a row disappearing off the stage holding it reads as deletion
    // (#1014, #901); the filter retired in #2348 never touched the stage lists either. Inquiries never
    // reach here at all: `stage(for:)` above places them, and it consults no date, because an inquiry is
    // live for as long as somebody is waiting on a reply.
    //
    // An undated show stays. "Date to be confirmed" is ordinary on a season page, and nothing has
    // measured such a show as far out, so dropping it would lose a real lead on a fact nobody
    // established. That is the same call #861 made at the past edge.
    private static func isWithinLeadTime(_ p: Prospect, context: StageContext) -> Bool {
        // #2365: a past client's show gets the longer window, because a returning client books a season a
        // year ahead and the scout already READS their calendar that far. Without this arm Overture
        // fetched a client's next-season date, stored it, and then declined to offer it for triage for
        // nine months. Measured on the live store that day: 36 of the 124 shows past the ordinary edge.
        //
        // #2524: expressed as the ordinary window OR the client reach, rather than as a client branch that
        // restates the whole rule, because the card now SAYS which of the two kept a row. Written the old
        // way the sentence would be a second predicate agreeing with this one by inspection, and the two
        // could drift silently (L16). Same verdicts, in the same order: a client's show inside 90 days is
        // ordinary rather than early, which is exactly what the card must not claim.
        if QueueModel.isWithinOrdinaryLeadTime(performanceDate: p.performanceDate, today: context.today) {
            return true
        }
        return QueueModel.isOfferedEarlyAsAClient(performanceDate: p.performanceDate,
                                                  isPastClient: context.clients.isPastClientShow(p),
                                                  today: context.today)
    }

    private static func matches(_ focus: StageFocus, _ p: Prospect, context: StageContext) -> Bool {
        // #1570: the geography gate, asked HERE so every surface inherits it, rather than on the
        // masthead's own path alone. It used to sit only in QueueModel.filter, which the stage list Dan
        // triages never called, so the number and the list beneath it counted different shows. The gate
        // spares committed outreach and anything Overture cannot place; GeoRefusals owns both rules.
        if context.geo.hidesFromQueue(p) { return false }
        switch focus {
        case .scout:
            // #861: "waiting to be triaged" is a question about TIME, not just status. The pill counted
            // every show still marked new, so Dan's backlog read 102 when 25 of them were June shows
            // already three weeks gone: work that could not be done, and he went looking for it.
            // #864: the exact complement of what the launch retirement sweeps up, by construction, both
            // asking Prospect.hasOpened. An untriaged show is either waiting on him or already open.
            // #1540: "already open", not "already over" -- once a run has started Dan will not pitch it,
            // so it is not work, and the triage list drops it on the same rule.
            //
            // #2359: and the same question has a FAR edge, asked here for the first time. Triage had none
            // at all, so it ran as far ahead as the scout had read: 585 untriaged shows on the live store
            // on 2026-08-09, 119 of them past 90 days and out to June 2027. Dan's call that day was to
            // enforce the window the repo had been describing since #1571, and the shows past it come
            // back on their own as their dates roll in.
            return p.status == .new && !p.hasOpened(today: context.today) && isWithinLeadTime(p, context: context)

        case .prep:
            // #901: through needsPrepEligible, not needsPrep with the fields spelled out again. Spelled
            // out, this call quietly omitted the new conflict gate, so the pill counted a show Dan is
            // booked against and the Prep run then refused to draft it. The (Prospect) -> Bool wrapper
            // exists precisely so a new field cannot be forgotten at one of two call sites.
            return PrepQueueBuilder.needsPrepEligible(p)

        case .review:
            // #2050: a show belongs to Review from the moment it has a draft until every contact on it
            // has been emailed (the last send flips it to `.contacted`, which leaves). Approving used to
            // move it out, into `.sendApproved`, which has a pill only when Gmail is disconnected, so an
            // approved email sat in a stage nothing pointed at. Dan, minutes after approving his first
            // hand-prepped draft: "I clicked approve on it and it disappeared?" He navigates by the pills
            // alone, so the record was in the store and reachable from no view he uses (L45).
            //
            // Stated as the two statuses rather than as "drafted, or approved and unsent", so there is no
            // gap between them for a part-sent show (approved with `sentAt` already set) to fall into.
            //
            // #1940: except while a re-prep is queued on it. Review holds drafts worth reading NOW, and a
            // draft a queued run is about to rewrite is not one of those (Dan, 2026-08-01), so the show
            // sits under Prep alone until the run ends. #1800 recorded the old overlap as deliberate; this
            // reverses that, and the reversal is safe only because of the two halves under it: the same
            // flag that takes it out of here puts it in `.prep` above, so it cannot fall
            // out of every list, and ReprepRelease returns it here when the run ends without serving it
            // (L45: the filters must cover the whole state space between them).
            return (p.status == .drafted || p.status == .approved) && !p.isReprepQueued

        case .sendApproved:
            return p.status == .approved && p.sentAt == nil

        case .sendBlocked:
            // #792: a show whose only remaining contact is held by a review guard has usually ALREADY
            // been sent to somebody else, so it is `.contacted` and appears in no other send state.
            // That is precisely how the held contact became invisible.
            //
            // #1797: "usually" was the whole gate, and it went stale. The triage reachability check
            // (#1585) writes its contacts through PrepImporter, which runs the same three guards, so an
            // untriaged show collects guard flags without going anywhere near a send, and Send issues
            // then reported a send problem on a show nothing had ever been sent to. The assumption the
            // comment above states is now asked out loud. A held contact on a show that is NOT in the
            // send half is not lost: its triage card says so instead (ProspectRowView), through this
            // same predicate, so exactly one surface speaks for it.
            return p.blockedContactCount > 0 && p.hasEnteredSendHalf

        case .sendErrors:
            return p.sendError != nil

        case .sendStuck:
            // #475/#476: claimed .sending and never resolved, so the outcome is genuinely unknown.
            return p.recipients.contains { $0.isSendStuck(now: context.now) }

        case .sendDegraded:
            // #483: the send went out fine, just with no usable threadId to watch for a reply. These
            // shows are SENT, so they are neither approved nor blocked: before #863 the pill counted
            // them and its tap resolved none of them.
            return p.recipients.contains { $0.replyTrackingDegraded }

        case .sendThreadingDegraded:
            // #2647: the send went out and its replies are watched normally; what is missing is the id
            // our own next message on that conversation would reference, so a nudge or closing note
            // will read as a separate conversation in every client that is not Gmail.
            return p.recipients.contains { $0.threadingDegraded }

        case .followUps:
            return false

        case .reachedOut:
            // #1134: like .followUps, resolves no queue keys here. Its rows are per-recipient and its
            // count comes from ReachedOutQueue; the reached-out view renders reachedOutList directly.
            return false
        }
    }
}
