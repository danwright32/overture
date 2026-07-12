import Testing
import Foundation
import SwiftData
@testable import Overture

// #792: a contact held back by one of the send guards makes the SHOW read as fully Sent, and it is then
// never surfaced again.
//
// When the last sendable recipient goes out, SendService flips the prospect to `.contacted`. A recipient
// held back by a guard is, by definition, not sendable, so it does not count, and the show leaves Dan's
// queue reading "Sent" while that contact never received anything and nothing afterwards surfaces it.
//
// The blocked contact is usually the one WORTH emailing: the act's own address, held back by a heuristic
// Dan only has to glance at to dismiss. So the show is genuinely contacted (somebody was emailed) and
// the contact is genuinely still waiting on him, and both facts have to be true at once and both have to
// be visible. Today the first silently erases the second.
@MainActor
@Suite("A blocked contact stays visible (#792)")
struct BlockedContactVisibilityTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func prospect(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "show", groupName: "Brooklyn Youth Chorus", discipline: "music",
                         venue: "Merkin Hall", performanceDate: "2099-09-19", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        p.draftBody = "Hello, I photograph performances and would love to shoot this."
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func recipient(_ p: Prospect, email: String, in ctx: ModelContext) -> Recipient {
        let r = Recipient(id: "\(p.naturalKey)-\(email)", email: email, name: "Someone",
                          role: "Manager", provenance: .act)
        r.prospect = p
        p.recipients.append(r)
        ctx.insert(r)
        return r
    }

    // MARK: - Each guard leaves a contact WAITING, not finished

    // Every guard that gates isSendablePending: the venue guess (#388), the press contact (#722), the
    // duplicate (#399), the salutation review (#407) and the draft lint (#789). Each one holds a real
    // contact back pending one glance from Dan, and each must read as waiting rather than as done.
    @Test func aContactHeldByAnyGuardIsWaitingOnDanNotFinished() throws {
        let ctx = try context()

        let venue = recipient(prospect(ctx), email: "box@hall.example", in: ctx)
        venue.looksLikeVenue = true

        let press = recipient(prospect(ctx), email: "press@org.example", in: ctx)
        press.looksLikePressContact = true

        let dupe = recipient(prospect(ctx), email: "same@org.example", in: ctx)
        dupe.looksLikeDuplicateContact = true

        for r in [venue, press, dupe] {
            #expect(r.isSendablePending == false)          // held back, as designed
            #expect(r.isBlockedAwaitingReview, "a guard holds a real contact pending Dan's glance")
        }
    }

    // MARK: - What is NOT waiting on Dan

    // A contact already emailed is finished. So is one deliberately suppressed, and one with no address
    // at all. Counting those as "waiting on you" would make the signal meaningless, which is how a
    // genuine one gets ignored.
    @Test func aFinishedContactIsNotWaitingOnAnybody() throws {
        let ctx = try context()
        let p = prospect(ctx)

        let sent = recipient(p, email: "a@org.example", in: ctx)
        sent.sendState = .sent

        let suppressed = recipient(p, email: "b@org.example", in: ctx)
        suppressed.sendState = .suppressed

        let noAddress = recipient(p, email: "", in: ctx)

        #expect(sent.isBlockedAwaitingReview == false)
        #expect(suppressed.isBlockedAwaitingReview == false)
        #expect(noAddress.isBlockedAwaitingReview == false)
    }

    // A contact paused because the org REPLIED is not blocked by a guard: Dan is deliberately not
    // emailing them again while a conversation is live, and calling that "waiting on you" would nag him
    // about a thing that is working correctly.
    @Test func aContactPausedByAReplyIsNotWaitingOnAGuard() throws {
        let ctx = try context()
        let r = recipient(prospect(ctx), email: "a@org.example", in: ctx)
        r.pausedByReply = true

        #expect(r.isSendablePending == false)
        #expect(r.isBlockedAwaitingReview == false)
    }

    // A perfectly sendable contact is not "blocked" either. It is just waiting to be sent, which the
    // Send pill already counts.
    @Test func anOrdinarySendableContactIsNotBlocked() throws {
        let ctx = try context()
        let r = recipient(prospect(ctx), email: "a@org.example", in: ctx)

        #expect(r.isSendablePending)
        #expect(r.isBlockedAwaitingReview == false)
    }

    // MARK: - The show, and the bug

    // THE test. One contact goes out, one is held by a guard. The show is genuinely contacted, AND the
    // held contact is genuinely still waiting, and both must be true at once. Before this, the second
    // fact was silently erased by the first.
    @Test func aShowWithOneSentAndOneBlockedContactStillSaysSomebodyIsWaiting() throws {
        let ctx = try context()
        let p = prospect(ctx)

        let sent = recipient(p, email: "manager@org.example", in: ctx)
        sent.sendState = .sent
        let blocked = recipient(p, email: "box@hall.example", in: ctx)
        blocked.looksLikeVenue = true

        // The show has no sendable recipient left, which is what makes SendService call it contacted.
        #expect(p.recipients.contains(where: \.isSendablePending) == false)

        // And that is fine, as long as it does not erase the fact that somebody is still waiting.
        #expect(p.blockedContactCount == 1)
        #expect(sent.isBlockedAwaitingReview == false)
        #expect(blocked.isBlockedAwaitingReview)
    }

    @Test func aShowWithNothingHeldBackCountsNobody() throws {
        let ctx = try context()
        let p = prospect(ctx)
        let sent = recipient(p, email: "manager@org.example", in: ctx)
        sent.sendState = .sent

        #expect(p.blockedContactCount == 0)
    }

    // MARK: - It reaches the one place Dan always looks

    // The masthead's "needs you" row is the app's own answer to "where am I needed". A held contact must
    // appear there, or it is invisible again by a different route, and the whole bug is that it went
    // invisible.
    @Test func aBlockedContactShowsUpInTheNeedsYouRow() {
        var inputs = AgentInputs(toTriage: 0, keptToPrep: 0, prepRunning: false, toReview: 0,
                                 readyToSend: 0, gmailConnected: true, sendErrors: 0, followUpsDue: 0)
        inputs.blockedContacts = 2

        let statuses = AgentRoster.statuses(inputs)
        let send = try! #require(statuses.first { $0.name == "Send" })

        #expect(send.state == .needsAttention)
        #expect(send.detail.contains("2"))
        // It must say WHY, or Dan cannot tell it from an ordinary queue of approved sends.
        #expect(send.detail.localizedCaseInsensitiveContains("check"))
        #expect(AgentRoster.needsYouCount(statuses) > 0)
    }

    // A real failure still outranks it: a send that failed, or one whose outcome is unknown, needs his
    // eyes more urgently than a contact held back by a heuristic.
    @Test func aFailedSendStillOutranksAHeldContact() {
        var inputs = AgentInputs(toTriage: 0, keptToPrep: 0, prepRunning: false, toReview: 0,
                                 readyToSend: 0, gmailConnected: true, sendErrors: 1, followUpsDue: 0)
        inputs.blockedContacts = 2

        let send = AgentRoster.statuses(inputs).first { $0.name == "Send" }
        #expect(send?.state == .error)
        #expect(send?.detail.localizedCaseInsensitiveContains("failed") == true)
    }
}

// The stage pills are real navigation: what a pill SHOWS must be what tapping it takes Dan TO
// (StageNavigation's own header rule). A held contact broke that in the worst way: the show it belongs
// to has usually already been sent to somebody else, so it is `.contacted` and was not in the Send
// stage at all. The pill would have counted a person the tap could not reach.
@MainActor
@Suite("Tapping Send reaches the held contact (#792)")
struct BlockedContactNavigationTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext, key: String, status: ReviewStatus) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: "2099-09-19", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        ctx.insert(p)
        return p
    }

    // THE test. An already-contacted show with a held contact IS reachable from the Send pill.
    @Test func anAlreadyContactedShowWithAHeldContactIsStillReachable() throws {
        let ctx = try context()
        let contacted = show(ctx, key: "contacted", status: .contacted)
        contacted.sentAt = Date()
        let held = Recipient(id: "r1", email: "box@hall.example", name: "Box Office",
                             role: "Box Office", provenance: .act)
        held.looksLikeVenue = true
        held.prospect = contacted
        contacted.recipients.append(held)
        ctx.insert(held)

        let keys = StageNavigation.naturalKeys(forStage: "Send", in: [contacted])

        #expect(keys == ["contacted"])
    }

    @Test func anOrdinaryApprovedShowIsStillReachableToo() throws {
        let ctx = try context()
        let approved = show(ctx, key: "approved", status: .approved)

        #expect(StageNavigation.naturalKeys(forStage: "Send", in: [approved]) == ["approved"])
    }

    // A contacted show with NOTHING held is finished, and must not come back into the Send stage. The
    // point of the fix is to surface a person still waiting, not to re-open every show Dan has emailed.
    @Test func aFinishedContactedShowStaysFinished() throws {
        let ctx = try context()
        let done = show(ctx, key: "done", status: .contacted)
        done.sentAt = Date()

        #expect(StageNavigation.naturalKeys(forStage: "Send", in: [done]).isEmpty)
    }
}

// The symptom the issue is named for: the show READS as fully Sent. "Sent" standing alone, while a real
// contact sits held back by a check, is the lie. Both facts have to be on the row at once.
@Suite("The row never says only Sent while somebody waits (#792)")
struct BlockedContactRowGuardTests {
    private var draftReview: String { SourceGuardHelper.source("Overture/UI/DraftReviewView.swift") }
    private var queueModel: String { SourceGuardHelper.source("Overture/UI/QueueView+Model.swift") }

    @Test func theSentRowAlsoSaysHowManyContactsAreHeld() {
        #expect(!draftReview.isEmpty)
        #expect(draftReview.contains("item.blockedContactCount > 0"))
        #expect(draftReview.contains("held for a check"))
    }

    // And it has to reach the row at all: the count is carried on the QueueItem, not recomputed in a
    // view that a future refactor could quietly drop.
    @Test func theCountReachesTheRow() {
        #expect(queueModel.contains("blockedContactCount: p.blockedContactCount"))
    }
}
