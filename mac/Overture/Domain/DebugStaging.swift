import Foundation

// #196: a DEBUG-only test affordance. Booking detection, follow-ups, conversation reminders,
// and reply handling all key off a prospect being contacted (sentAt set), but the only
// production path to that is a live Gmail send. This stages a prospect as if its email had
// already gone out, so those post-send flows can be exercised without sending real mail or
// hand-editing the SwiftData store. Wrapped in #if DEBUG so it is compiled out of release
// builds entirely and can never fake data in normal use.
#if DEBUG
enum DebugStaging {
    // Mark a prospect as an approved-and-sent lead. sentAt + the .approved status are exactly
    // what wasContacted reads, and priorRelationshipAtSend is snapshotted just as SendService
    // does (#66) so booking detection sees a genuine pre-send relationship. Nothing else is
    // touched, so the lead reads as a fresh send with no reply or outcome yet.
    static func stageAsSent(_ prospect: Prospect, now: Date) {
        prospect.sentAt = now
        prospect.status = .approved
        prospect.priorRelationshipAtSend = prospect.priorRelationship
        prospect.sendError = nil
    }
}
#endif
