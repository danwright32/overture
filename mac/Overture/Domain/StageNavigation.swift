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
enum StageFocus: String, Equatable, Sendable {
    case scout, prep, review
    case sendApproved, sendBlocked, sendErrors, sendStuck, sendDegraded
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
                            today: String = QueueModel.easternToday(),
                            now: Date = Date()) -> [String] {
        prospects.filter { matches(focus, $0, today: today, now: now) }.map(\.naturalKey)
    }

    // #1134: which stage a deep-linked lead belongs to, so a tapped OmniFocus follow-up or a search pick
    // focuses the stage that actually contains the show now that the pipeline picker is gone. A
    // reached-out lead focuses .reachedOut (its rows come from ReachedOutQueue, keyed separately); every
    // other lead is placed by the same `matches` predicate the pills count with. nil for a lead in no
    // stage at all (RootView routes those to Archive instead).
    static func stage(containing key: String, in prospects: [Prospect], reachedOutKeys: Set<String>,
                      today: String = QueueModel.easternToday(), now: Date = Date()) -> StageFocus? {
        if reachedOutKeys.contains(key) { return .reachedOut }
        guard let p = prospects.first(where: { $0.naturalKey == key }) else { return nil }
        return countedFocuses.first { matches($0, p, today: today, now: now) }
    }

    // #1140: which rows the focused list shows. A stage pill (`stage` non-nil) re-derives its membership
    // LIVE from the current prospects on every render, so a show that leaves the stage (a draft sent, so
    // its status moves off `.drafted`) drops out of the focused list instead of lingering because the key
    // set was frozen at tap time. The #308 away-alert leads path (`stage` nil) is not a stage: it is a
    // specific named set Dan asked to see, so its keys are returned verbatim (the flat list renders
    // whichever of them still exist). This lives here, not in the SwiftUI view, so it can be tested at all
    // (the #863 lesson: a rule computed inside a view has no seam a test can reach).
    static func focusedKeys(stage: StageFocus?, leadKeys: [String], in prospects: [Prospect],
                            today: String = QueueModel.easternToday(), now: Date = Date()) -> [String] {
        guard let stage else { return leadKeys }
        return naturalKeys(for: stage, in: prospects, today: today, now: now)
    }

    // Every focus that resolves queue keys. `.followUps` is excluded on purpose: it opens FollowUpsView
    // and resolves no keys (matches returns false), so counting it here would only ever add a zero.
    static let countedFocuses: [StageFocus] = [
        .scout, .prep, .review,
        .sendApproved, .sendBlocked, .sendErrors, .sendStuck, .sendDegraded
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
                       today: String = QueueModel.easternToday(),
                       now: Date = Date()) -> [StageFocus: Int] {
        var result: [StageFocus: Int] = [:]
        for p in prospects {
            for focus in countedFocuses where matches(focus, p, today: today, now: now) {
                result[focus, default: 0] += 1
            }
        }
        return result
    }

    private static func matches(_ focus: StageFocus, _ p: Prospect, today: String, now: Date) -> Bool {
        switch focus {
        case .scout:
            // #861: "waiting to be triaged" is a question about TIME, not just status. The pill counted
            // every show still marked new, so Dan's backlog read 102 when 25 of them were June shows
            // already three weeks gone: work that could not be done, and he went looking for it.
            // #864: the exact complement of what the launch retirement sweeps up, by construction, both
            // asking Prospect.hasGoneBy. An untriaged show is either waiting on him or already gone.
            return p.status == .new && !p.hasGoneBy(today: today)

        case .prep:
            // #901: through needsPrepEligible, not needsPrep with the fields spelled out again. Spelled
            // out, this call quietly omitted the new conflict gate, so the pill counted a show Dan is
            // booked against and the Prep run then refused to draft it. The (Prospect) -> Bool wrapper
            // exists precisely so a new field cannot be forgotten at one of two call sites.
            return PrepQueueBuilder.needsPrepEligible(p)

        case .review:
            return p.status == .drafted

        case .sendApproved:
            return p.status == .approved && p.sentAt == nil

        case .sendBlocked:
            // #792: a show whose only remaining contact is held by a review guard has usually ALREADY
            // been sent to somebody else, so it is `.contacted` and appears in no other send state.
            // That is precisely how the held contact became invisible.
            return p.blockedContactCount > 0

        case .sendErrors:
            return p.sendError != nil

        case .sendStuck:
            // #475/#476: claimed .sending and never resolved, so the outcome is genuinely unknown.
            return p.recipients.contains { $0.isSendStuck(now: now) }

        case .sendDegraded:
            // #483: the send went out fine, just with no usable threadId to watch for a reply. These
            // shows are SENT, so they are neither approved nor blocked: before #863 the pill counted
            // them and its tap resolved none of them.
            return p.recipients.contains { $0.replyTrackingDegraded }

        case .followUps:
            return false

        case .reachedOut:
            // #1134: like .followUps, resolves no queue keys here. Its rows are per-recipient and its
            // count comes from ReachedOutQueue; the reached-out view renders reachedOutList directly.
            return false
        }
    }
}
