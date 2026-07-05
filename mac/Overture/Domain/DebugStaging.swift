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
        seedRecipient(prospect)
    }

    // #391: mirror the staged singular fields into recipients[0] in-session, reusing the same
    // synthesizer the launch backfill uses, so a staged lead carries the new model immediately
    // instead of showing zero recipients until the next-launch backfill. No-op when the staged lead
    // has no contact email (nothing to make a recipient from).
    private static func seedRecipient(_ prospect: Prospect) {
        guard let recipient = RecipientBackfill.synthesizedRecipient(from: prospect) else { return }
        prospect.setRecipients([recipient])
    }

    // Insert a fresh lead already eligible for the OmniFocus sync (#231): contacted, replied, with a
    // confirmed (manual) "verbal yes" set now, so its next reminder is ~7 days out (inside the
    // horizon). Used to verify a task actually gets created end to end, regardless of live data.
    @discardableResult
    static func stageReminderDueLead(in context: ModelContext, now: Date) -> Prospect {
        let key = "debug-of-\(Int(now.timeIntervalSince1970))"
        let p = Prospect(naturalKey: key, groupName: "Test Choir (debug)", discipline: "music",
                         venue: "Weill Recital Hall",
                         performanceDate: EasternDate.dayString(from: now.addingTimeInterval(20 * 86_400)),
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "debug", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        p.sentAt = now.addingTimeInterval(-86_400)
        p.contactName = "Test Contact (debug)"
        p.contactEmail = "reminder@debug.example"   // a real send always has a contact (#331)
        p.outcome = .replied
        p.conversationStateRaw = ConversationState.wantsToBook.rawValue
        p.conversationStateSourceRaw = OutcomeSource.manual.rawValue
        p.conversationStateSetAt = now
        seedRecipient(p)
        context.insert(p)
        return p
    }

    // #325: stage a self-addressed lead so the real approve -> send -> success path can be verified
    // end to end without risking a real email to a prospect. It goes to `address` (Dan's own inbox by
    // default). Left `.drafted` (not pre-approved) so Dan exercises the real approve + send clicks; its
    // performance date is inside the bookable window so it shows in the queue; keyed under the
    // "debug-of-" prefix so clearDebugLeads removes it.
    static let defaultSelfSendAddress = "dan@danwrightphotography.com"

    // #432: resolve the self-send test address from an optional override (the `selfSendTestAddress`
    // user default), falling back to Dan's primary inbox when it is absent or blank. Pure so the
    // precedence is unit-tested without driving the Debug menu.
    static func resolvedSelfSendAddress(override: String?) -> String {
        guard let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return defaultSelfSendAddress }
        return trimmed
    }

    @discardableResult
    static func stageSelfSendLead(in context: ModelContext, now: Date,
                                  address: String = defaultSelfSendAddress) -> Prospect {
        let key = "debug-of-selfsend-\(Int(now.timeIntervalSince1970))"
        let p = Prospect(naturalKey: key, groupName: "Self-send Test (debug)", discipline: "music",
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
        seedRecipient(p)
        context.insert(p)
        return p
    }

    // #425: like stageSelfSendLead but with TWO recipients (an act and a presenter) instead of one, so
    // a real approve -> send -> send sequence can prove the per-recipient fan-out (#415) sends two
    // separate emails, each to its own address and greeting its own name, on their own Gmail threads.
    // Both addresses derive from Dan's own inbox via a +tag so a live send still reaches him, but the
    // two recipients keep distinct ids (Recipient.id is the canonicalized email) within this one lead.
    // The legacy contactName/contactEmail fields mirror the act recipient (same pattern seedRecipient
    // establishes for the single-recipient stager) since DraftReviewView's Approve button is disabled
    // when contactEmail is nil.
    @discardableResult
    static func stageMultiRecipientSelfSendLead(in context: ModelContext, now: Date,
                                                address: String = defaultSelfSendAddress) -> Prospect {
        let key = "debug-of-selfsend-multi-\(Int(now.timeIntervalSince1970))"
        let actEmail = plusTaggedAddress(address, tag: "act")
        let presenterEmail = plusTaggedAddress(address, tag: "presenter")

        let p = Prospect(naturalKey: key, groupName: "Self-send Multi Test (debug)", discipline: "music",
                         venue: "Weill Recital Hall",
                         performanceDate: EasternDate.dayString(from: now.addingTimeInterval(20 * 86_400)),
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "debug multi-recipient self-send",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        p.contactName = "Dan (test act)"
        p.contactEmail = actEmail
        p.draftSubject = "Overture self-send test"
        p.draftBody = "This is a self-send test from Overture. If you received it, the send path works."

        let act = Recipient(id: Recipient.makeId(email: actEmail, formURL: nil) ?? actEmail, email: actEmail,
                            name: "Dan (test act)", role: "Act", provenance: .act)
        let presenter = Recipient(id: Recipient.makeId(email: presenterEmail, formURL: nil) ?? presenterEmail,
                                  email: presenterEmail, name: "Dan (test presenter)", role: "Presenter",
                                  provenance: .presenter)
        p.setRecipients([act, presenter])
        context.insert(p)
        return p
    }

    // Inserts a +tag before the @ so the same inbox receives a distinguishable address per recipient
    // (e.g. dan+act@x.com), keeping Recipient.id (the canonicalized email) unique per role even though
    // both ultimately land in Dan's one inbox.
    private static func plusTaggedAddress(_ address: String, tag: String) -> String {
        guard let atIndex = address.firstIndex(of: "@") else { return address }
        let local = address[address.startIndex..<atIndex]
        let domain = address[atIndex...]
        return "\(local)+\(tag)\(domain)"
    }

    // Remove every debug-staged lead (naturalKey prefix "debug-of-"). After this, a sync completes
    // their now-orphaned OmniFocus tasks (they leave the desired set). Cleans up after testing.
    static func clearDebugLeads(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        for p in all where p.naturalKey.hasPrefix("debug-of-") { context.delete(p) }
    }
}
#endif
