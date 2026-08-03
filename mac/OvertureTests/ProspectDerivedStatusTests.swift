import Testing
import Foundation
import SwiftData

// Phase F (#440): the lead-level derived reads the migrated readers consume. `isClosed` gates routine
// follow-ups/reminders; `hasUnhandledReply` flags a reply that still needs triage. Per Dan's call,
// hasUnhandledReply is INDEPENDENT of isClosed, so a late reply from another contact surfaces even on a
// show that was already closed.
@Suite("Prospect derived status")
struct ProspectDerivedStatusTests {
    @Test func performanceStatusHasAReadableLabelForEachCase() {
        #expect(PerformanceStatus.new.label == "New")
        #expect(PerformanceStatus.active.label == "Active")
        #expect(PerformanceStatus.lostDoorOpen.label == "Closed (not now)")
        #expect(PerformanceStatus.lostNotInterested.label == "Closed (not interested)")
        #expect(PerformanceStatus.booked.label == "Booked")
    }

    private func makeInMemoryContext() throws -> ModelContext {
        let container = try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    private func makeProspect(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: nil,
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private func recipient(_ id: String, sendState: SendState, replied: Bool = false,
                           resolution: RecipientResolution? = nil, bounced: Bool = false) -> Recipient {
        let r = Recipient(id: id, email: id, provenance: .act)
        r.sendState = sendState
        r.replied = replied
        r.resolution = resolution
        r.bounced = bounced
        return r
    }

    // hasUnhandledReply
    @Test func hasUnhandledReplyWhenAContactRepliedAndIsUnresolved() throws {
        let ctx = try makeInMemoryContext()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@e.com", sendState: .sent, replied: true)])
        #expect(p.hasUnhandledReply)
    }

    @Test func noUnhandledReplyOnceThatRecipientsOwnStateIsHandSet() throws {
        let ctx = try makeInMemoryContext()
        let p = makeProspect(ctx)
        let r = recipient("a@e.com", sendState: .sent, replied: true)
        r.conversationStateSource = .manual
        p.setRecipients([r])
        #expect(!p.hasUnhandledReply)
    }

    @Test func noUnhandledReplyWhenTheRepliedContactIsResolved() throws {
        let ctx = try makeInMemoryContext()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@e.com", sendState: .sent, replied: true, resolution: .declinedSoft)])
        #expect(!p.hasUnhandledReply)
    }

    @Test func aBookedShowHasNoUnhandledReply() throws {
        let ctx = try makeInMemoryContext()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@e.com", sendState: .sent, replied: true)])
        p.outcome = .booked
        #expect(!p.hasUnhandledReply)
    }

    // isClosed
    @Test func notClosedWhileAContactIsInPlay() throws {
        let ctx = try makeInMemoryContext()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@e.com", sendState: .sent)])
        #expect(!p.isClosed)
    }

    @Test func closedWhenBooked() throws {
        let ctx = try makeInMemoryContext()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@e.com", sendState: .sent)])
        p.outcome = .booked
        #expect(p.isClosed)
    }

    @Test func closedWhenEveryContactDeclined() throws {
        let ctx = try makeInMemoryContext()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@e.com", sendState: .sent, resolution: .declinedHard)])
        #expect(p.isClosed)
    }

    // The union: Dan closed the lead by hand / closing note (lostSoft) even though a contact is still
    // technically in play. Routine follow-ups should stop.
    @Test func closedWhenLeadManuallyMarkedLostEvenIfAContactIsUnresolved() throws {
        let ctx = try makeInMemoryContext()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@e.com", sendState: .sent)])
        p.outcome = .lostSoft
        #expect(p.isClosed)
    }

    // Dan's decision (#424): a late reply from another contact surfaces for triage even on a closed
    // show, so an "actually, yes" is never missed — while routine follow-ups stay stopped.
    @Test func aLateReplyStillSurfacesOnAClosedShow() throws {
        let ctx = try makeInMemoryContext()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@e.com", sendState: .sent, replied: true)])
        p.outcome = .lostSoft
        #expect(p.isClosed)
        #expect(p.hasUnhandledReply)
    }
}
