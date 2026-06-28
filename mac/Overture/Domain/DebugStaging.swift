import Foundation
import SwiftData

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

    // Insert a fresh lead already eligible for the OmniFocus sync (#231): contacted, replied, with a
    // confirmed (manual) "verbal yes" set now, so its next reminder is ~7 days out (inside the
    // horizon). Used to verify a task actually gets created end to end, regardless of live data.
    @discardableResult
    static func stageReminderDueLead(in context: ModelContext, now: Date) -> Prospect {
        let key = "debug-of-\(Int(now.timeIntervalSince1970))"
        let p = Prospect(naturalKey: key, groupName: "Test Choir (debug)", discipline: "choral",
                         venue: "Weill Recital Hall",
                         performanceDate: EasternDate.dayString(from: now.addingTimeInterval(20 * 86_400)),
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "debug", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        p.sentAt = now.addingTimeInterval(-86_400)
        p.outcome = .replied
        p.conversationStateRaw = ConversationState.wantsToBook.rawValue
        p.conversationStateSourceRaw = OutcomeSource.manual.rawValue
        p.conversationStateSetAt = now
        context.insert(p)
        return p
    }

    // #325: stage a self-addressed lead so the real approve -> send -> success path can be verified
    // end to end without risking a real email to a prospect. It goes to `address` (Dan's own inbox by
    // default). Left `.drafted` (not pre-approved) so Dan exercises the real approve + send clicks; its
    // performance date is inside the bookable window so it shows in the queue; keyed under the
    // "debug-of-" prefix so clearDebugLeads removes it.
    @discardableResult
    static func stageSelfSendLead(in context: ModelContext, now: Date,
                                  address: String = "dan@danwrightphotography.com") -> Prospect {
        let key = "debug-of-selfsend-\(Int(now.timeIntervalSince1970))"
        let p = Prospect(naturalKey: key, groupName: "Self-send Test (debug)", discipline: "choral",
                         venue: "Weill Recital Hall",
                         performanceDate: EasternDate.dayString(from: now.addingTimeInterval(20 * 86_400)),
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "debug self-send", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .drafted)
        p.contactName = "Dan (test)"
        p.contactEmail = address
        p.draftSubject = "Overture self-send test"
        p.draftBody = "This is a self-send test from Overture. If you received it, the send path works."
        context.insert(p)
        return p
    }

    // Remove every debug-staged lead (naturalKey prefix "debug-of-"). After this, a sync completes
    // their now-orphaned OmniFocus tasks (they leave the desired set). Cleans up after testing.
    static func clearDebugLeads(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        for p in all where p.naturalKey.hasPrefix("debug-of-") { context.delete(p) }
    }
}
#endif
