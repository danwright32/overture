import Foundation

// #338/#370: the stage pills (Scout/Prep/Review/Send/Follow-ups) become real navigation, taking
// Dan to exactly the prospects in that stage. These criteria MUST match AgentRoster's own
// per-stage counts (toTriage/keptToPrep/toReview/readyToSend) exactly, so what a pill shows is
// what tapping it navigates to. Follow-ups isn't a queue filter (it opens the existing
// FollowUpsView sheet instead), so it isn't represented here.
enum StageNavigation {
    // #861: `today` is here because "waiting to be triaged" is a question about TIME, not just status.
    // The pill counted every show still marked new, so Dan's backlog read 102 when 25 of them were June
    // shows already three weeks gone. The queue filtered them correctly, so the pill counted work that
    // could not be done and then navigated him to shows the queue refused to render.
    static func naturalKeys(forStage name: String, in prospects: [Prospect],
                            today: String = QueueModel.easternToday()) -> [String] {
        switch name {
        case "Scout":
            return prospects.filter {
                // Judged on the run's LAST night, the same rule the ingest guard (#798) and the reconcile
                // both use, so there is one answer to "is this show over" rather than three. A run that
                // opened in the past but is still playing tonight is still a lead. An undated show can
                // never be judged past: "date to be confirmed" is a normal state on an org's season page,
                // and dropping it would silently lose a real one.
                guard $0.status == .new else { return false }
                let lastNight = EasternDate.runLastNight(runEndDate: $0.runEndDate,
                                                         performanceDate: $0.performanceDate)
                // An undated show is NOT past. `runIsLive` answers false for a nil date, which is right
                // for the reconcile (a show with no date can never be marked "gone from the feed") and
                // exactly wrong here: dropping it would silently lose a real lead whose date is simply
                // not announced yet. So the question asked here is "has it demonstrably happened", not
                // "is it demonstrably live".
                guard lastNight != nil else { return true }
                return EasternDate.runIsLive(lastNight: lastNight, today: today)
            }.map(\.naturalKey)
        case "Prep":
            return prospects.filter {
                PrepQueueBuilder.needsPrep(status: $0.status, hasDraft: $0.hasDraft,
                                          reprepDraftRequested: $0.reprepDraftRequested,
                                          reprepContactsRequested: $0.reprepContactsRequested)
            }.map(\.naturalKey)
        case "Review":
            return prospects.filter { $0.status == .drafted }.map(\.naturalKey)
        case "Send":
            // #792: a show whose only remaining contact is held by a review guard has usually ALREADY
            // been sent to somebody else, so it is `.contacted` and would not appear here. That is
            // precisely how the held contact became invisible: the pill counts it and tapping the pill
            // took Dan nowhere. The header rule above is the one that matters here, so the two stay in
            // lockstep: what the pill shows is what tapping it navigates to.
            return prospects.filter {
                ($0.status == .approved && $0.sentAt == nil) || $0.blockedContactCount > 0
            }.map(\.naturalKey)
        default:
            return []
        }
    }
}
