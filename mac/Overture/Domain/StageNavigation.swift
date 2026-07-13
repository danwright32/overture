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
    static func naturalKeys(for focus: StageFocus, in prospects: [Prospect],
                            today: String = QueueModel.easternToday(),
                            now: Date = Date()) -> [String] {
        prospects.filter { matches(focus, $0, today: today, now: now) }.map(\.naturalKey)
    }

    private static func matches(_ focus: StageFocus, _ p: Prospect, today: String, now: Date) -> Bool {
        switch focus {
        case .scout:
            // #861: "waiting to be triaged" is a question about TIME, not just status. The pill counted
            // every show still marked new, so Dan's backlog read 102 when 25 of them were June shows
            // already three weeks gone: work that could not be done, and he went looking for it.
            guard p.status == .new else { return false }
            // Judged on the run's LAST night, the same rule the ingest guard (#798) and the reconcile
            // both use, so there is one answer to "is this show over" rather than three. A run that
            // opened in the past but is still playing tonight is still a lead.
            let lastNight = EasternDate.runLastNight(runEndDate: p.runEndDate,
                                                     performanceDate: p.performanceDate)
            // An undated show is NOT past. `runIsLive` answers false for a nil date, which is right for
            // the reconcile (a show with no date can never be marked "gone from the feed") and exactly
            // wrong here: dropping it would silently lose a real lead whose date is simply not announced
            // yet. So the question asked here is "has it demonstrably happened", not "is it live".
            guard lastNight != nil else { return true }
            return EasternDate.runIsLive(lastNight: lastNight, today: today)

        case .prep:
            return PrepQueueBuilder.needsPrep(status: p.status, hasDraft: p.hasDraft,
                                              reprepDraftRequested: p.reprepDraftRequested,
                                              reprepContactsRequested: p.reprepContactsRequested)

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
        }
    }
}
