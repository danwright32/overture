import Foundation

// #338: the stage pills (Prep/Review/Send/Follow-ups) become real navigation, taking Dan to
// exactly the prospects in that stage. These criteria MUST match AgentRoster's own per-stage
// counts (keptToPrep/toReview/readyToSend) exactly, so what a pill shows is what tapping it
// navigates to. Follow-ups isn't a queue filter (it opens the existing FollowUpsView sheet
// instead), so it isn't represented here.
enum StageNavigation {
    static func naturalKeys(forStage name: String, in prospects: [Prospect]) -> [String] {
        switch name {
        case "Prep":
            return prospects.filter { $0.status == .queued && !$0.hasDraft }.map(\.naturalKey)
        case "Review":
            return prospects.filter { $0.status == .drafted }.map(\.naturalKey)
        case "Send":
            return prospects.filter { $0.status == .approved && $0.sentAt == nil }.map(\.naturalKey)
        default:
            return []
        }
    }
}
