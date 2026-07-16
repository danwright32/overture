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
    // does (#66) so booking detection sees a genuine pre-send relationship. A real prospect
    // already carries its own recipients (from PrepImporter, #654); any still-pending one is
    // marked sent too, mirroring SendService.deliver, so per-recipient downstream flows
    // (follow-ups, reminders, reply handling) have something to act on.
    //
    // #378: ReachedOutQueue now requires a Gmail message id as proof of a real send, so each
    // staged recipient gets a synthetic one (a "debug-" id no real Gmail response could produce)
    // to keep showing up in the Reached-out queue for testing, without it being mistakable for
    // a genuine send.
    //
    // #963: the same proof requirement now applies at the PROSPECT level too (outreach stats,
    // booking auto-detection), mirroring SendService.deliver's lead-level rollup, so a staged
    // prospect still counts as contacted for those flows in a Debug build.
    static func stageAsSent(_ prospect: Prospect, now: Date) {
        prospect.sentAt = now
        prospect.status = .approved
        prospect.priorRelationshipAtSend = prospect.priorRelationship
        prospect.sendError = nil
        prospect.gmailMessageId = "debug-\(prospect.naturalKey)-\(Int(now.timeIntervalSince1970))"
        for r in prospect.recipients where r.sendState == .pending {
            r.sendState = .sent
            r.sentAt = now
            r.gmailMessageId = "debug-\(r.id)-\(Int(now.timeIntervalSince1970))"
        }
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
        // #963: mirrors stageAsSent's prospect-level synthetic id, so this staged lead also counts
        // as contacted for outreach stats/booking auto-detection, not just the reminder flow it targets.
        p.gmailMessageId = "debug-\(key)-\(Int(now.timeIntervalSince1970))"
        p.outcome = .replied
        // #654: the conversation state Dan confirms lives on the recipient now, not the lead.
        let recipient = Recipient(id: "reminder@debug.example", email: "reminder@debug.example",
                                  name: "Test Contact (debug)", provenance: .act)
        recipient.sendState = .sent
        recipient.sentAt = p.sentAt
        recipient.gmailMessageId = "debug-\(recipient.id)-\(Int(now.timeIntervalSince1970))"
        recipient.replied = true
        recipient.setConversationState(.wantsToBook, now: now)
        p.setRecipients([recipient])
        context.insert(p)
        return p
    }

    // #325: stage a self-addressed lead so the real approve -> send -> success path can be verified
    // end to end without risking a real email to a prospect. It goes to `address` (Dan's own inbox by
    // default). Left `.drafted` (not pre-approved) so Dan exercises the real approve + send clicks; its
    // performance date is inside the bookable window so it shows in the queue; keyed under the
    // "debug-of-" prefix so clearDebugLeads removes it.
    static let defaultSelfSendAddress = SendIdentity.danWright.email

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
        p.draftSubject = "Overture self-send test"
        p.draftBody = "This is a self-send test from Overture. If you received it, the send path works."
        let recipient = Recipient(id: Recipient.makeId(email: address, formURL: nil) ?? address,
                                  email: address, name: "Dan (test)", provenance: .act)
        p.setRecipients([recipient])
        context.insert(p)
        return p
    }

    // #425: like stageSelfSendLead but with TWO recipients (an act and a presenter) instead of one, so
    // a real approve -> send -> send sequence can prove the per-recipient fan-out (#415) sends two
    // separate emails, each to its own address and greeting its own name, on their own Gmail threads.
    // Both addresses derive from Dan's own inbox via a +tag so a live send still reaches him, but the
    // two recipients keep distinct ids (Recipient.id is the canonicalized email) within this one lead.
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
