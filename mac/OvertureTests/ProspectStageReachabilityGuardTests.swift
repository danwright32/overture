import Testing
import Foundation
import SwiftData

// #2050. Dan approved his first hand-prepped draft and it vanished: "I clicked approve on it and it
// disappeared? It's not in reached out". Nothing was lost. Approving moved the show into
// `.sendApproved`, and `AgentRoster.statuses` drops the Send pill entirely whenever Gmail is connected
// and nothing has gone wrong, so the stage holding it had no pill pointing at it. He works from the
// pills alone ("I have no way of viewing the main list, and I don't want one"), so the record was in
// the store and reachable from no view he uses.
//
// This is the prospect-side twin of InquiryStageReachabilityGuardTests (#1505), which caught exactly
// this shape for an inquiry parked in the same stage. The prospect half was never guarded, so the same
// defect walked back in through the other door (L30: fix the class, not the instance).
//
// The guard is deliberately NOT "assert `matches` returns .review for an approved show". That would be a
// test compared against its own definition. It DRIVES the real `stage(containing:)` over the states a
// show can actually be in, takes whatever stage comes back, and asserts that stage is genuinely
// reachable by tapping a pill.
//
// Reachable is checked the way Dan meets it, with the store holding ONLY that show. That is the exact
// shape of the bug: the Send pill reports whichever of five problems is most urgent, so `.sendApproved`
// only ever became a pill's focus when OTHER shows put a send problem there. A test seeded with a
// storeful of shows would have missed it entirely.
@MainActor
@Suite("A show may only be placed in a navigable stage (#2050)")
struct ProspectStageReachabilityGuardTests {
    private let today = ScoutTestClock.stageNavigationAnchor
    private let now = Date(timeIntervalSince1970: 1_768_000_000)
    private let earlier = Date(timeIntervalSince1970: 1_767_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext, status: ReviewStatus, drafted: Bool, sentAt: Date? = nil) -> Prospect {
        let p = Prospect(naturalKey: "show-1", groupName: "Quartet", discipline: "music",
                         venue: "Merkin Hall", performanceDate: "2026-09-19", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: status)
        if drafted {
            p.draftBody = "Hello, I photograph performances."
            p.draftSubject = "Photographing your September concert"
        }
        p.sentAt = sentAt
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ ctx: ModelContext, on p: Prospect, id: String = "c1",
                         sendState: SendState = .pending, sentAt: Date? = nil) -> Recipient {
        let r = Recipient(id: id, email: "\(id)@org.example", name: "Someone",
                          role: "Manager", provenance: .act)
        r.sendState = sendState
        r.sentAt = sentAt
        // A real send stamps both (SendService), and Recipient.hasProvenOutreach demands them before it
        // will believe an email went out. Without them a "sent" contact here would be the staged/corrupt
        // record that guard exists to reject, and this suite would be measuring a state that cannot occur.
        if sentAt != nil {
            r.gmailMessageId = "m-\(id)"
            r.gmailThreadId = "t-\(id)"
        }
        r.prospect = p
        p.recipients.append(r)
        ctx.insert(r)
        return r
    }

    // Every state a show can actually be in on its way from found to fully pitched, each built in its own
    // store. A state this list forgets is a state the guard cannot speak for, so each one is named.
    private func everyShowState() throws -> [(String, ModelContext)] {
        var all: [(String, ModelContext)] = []

        let triage = try context()
        _ = show(triage, status: .new, drafted: false)
        all.append(("freshly scouted, awaiting triage", triage))

        let kept = try context()
        _ = show(kept, status: .queued, drafted: false)
        all.append(("kept, waiting to be prepped", kept))

        let clashed = try context()
        let c = show(clashed, status: .queued, drafted: false)
        c.conflictOpen = true
        all.append(("kept, then held by a date clash", clashed))

        let drafted = try context()
        let d = show(drafted, status: .drafted, drafted: true)
        contact(drafted, on: d)
        all.append(("drafted, waiting for Dan to read it", drafted))

        // The reported bug: approved, nothing wrong, Gmail connected, nothing sent yet.
        let approved = try context()
        let a = show(approved, status: .approved, drafted: true)
        contact(approved, on: a)
        all.append(("approved and waiting to send", approved))

        // The same show with nothing sendable on it, so it cannot go out at all: #2052's missing subject
        // line, which holds every contact (Recipient.isSendablePending). Approved and stuck is the state
        // most in need of a way back to it.
        let approvedBlocked = try context()
        let ab = show(approvedBlocked, status: .approved, drafted: true)
        ab.draftSubject = nil
        contact(approvedBlocked, on: ab)
        all.append(("approved, but its draft has no subject line so nothing can send", approvedBlocked))

        // A show emailing its contacts one at a time: the first has gone, the second has not. It stays
        // approved with `sentAt` set, so it matches neither the drafted nor the approved-and-unsent rule.
        let partly = try context()
        let pt = show(partly, status: .approved, drafted: true, sentAt: earlier)
        contact(partly, on: pt, id: "c1", sendState: .sent, sentAt: earlier)
        contact(partly, on: pt, id: "c2")
        all.append(("part sent, with a second contact still to go", partly))

        let failed = try context()
        let f = show(failed, status: .contacted, drafted: true, sentAt: earlier)
        f.sendError = "Gmail said no"
        contact(failed, on: f, id: "c1", sendState: .sent, sentAt: earlier)
        all.append(("sent, but the send failed", failed))

        let degraded = try context()
        let g = show(degraded, status: .contacted, drafted: true, sentAt: earlier)
        let gr = contact(degraded, on: g, id: "c1", sendState: .sent, sentAt: earlier)
        gr.replyTrackingDegraded = true
        all.append(("sent, but replies cannot be watched for", degraded))

        let heldAfterSend = try context()
        let h = show(heldAfterSend, status: .contacted, drafted: true, sentAt: earlier)
        contact(heldAfterSend, on: h, id: "c1", sendState: .sent, sentAt: earlier)
        let blocked = contact(heldAfterSend, on: h, id: "c2")
        blocked.looksLikeVenue = true
        all.append(("sent, with another contact held for a check", heldAfterSend))

        return all
    }

    private func placement(_ ctx: ModelContext) throws -> (StageFocus?, [AgentStatus]) {
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let reachedOutKeys = Set(ReachedOutQueue.activeWithDates(from: all, now: now)
            .map(\.prospect.naturalKey))
        let stage = StageNavigation.stage(containing: "show-1", in: all, reachedOutKeys: reachedOutKeys,
                                          today: today, now: now)
        let inputs = AgentInputs.from(prospects: all, now: now, today: today, gmailConnected: true,
                                      prepRunning: false, replyRunAlive: false)
        return (stage, AgentRoster.statuses(inputs))
    }

    @Test("every stage a show can be placed in has a pill that navigates to it")
    func everyPlacedStageIsNavigable() throws {
        var checkedAtLeastOne = false

        for (description, ctx) in try everyShowState() {
            let (stage, pills) = try placement(ctx)
            guard let stage else { continue }
            checkedAtLeastOne = true

            let matching = pills.filter { $0.focus == stage }
            #expect(!matching.isEmpty,
                    "a show \(description) was placed in \(stage), which no pill points at, so Dan cannot reach it")
            for pill in matching {
                #expect(AgentRoster.chipAction(for: pill) == .focusOnStage,
                        "the pill for \(stage) does not navigate to the stage (\(pill.name)), so a show \(description) is unreachable")
            }
        }

        // If the state matrix ever stops placing any show at all, the loop above would pass vacuously.
        #expect(checkedAtLeastOne)
    }

    // The counterpart the reported bug would also have failed: a show still needing work from Dan is
    // always placed somewhere. A nil stage is the same disappearance by the other route.
    @Test("a show still waiting on Dan is always placed in some stage")
    func unfinishedShowsAreAlwaysPlaced() throws {
        for (description, ctx) in try everyShowState() {
            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            guard let p = all.first, p.status != .dismissed else { continue }
            let (stage, _) = try placement(ctx)
            #expect(stage != nil, "a show \(description) was placed nowhere, so it is absent from the queue")
        }
    }

    // And the reverse, so the fix cannot be "place everything in Review": a show Dan has finished with
    // leaves the queue rather than sitting in a stage forever.
    @Test("a dismissed show is placed nowhere")
    func dismissedShowsLeave() throws {
        let ctx = try context()
        let p = show(ctx, status: .dismissed, drafted: false)
        p.dismissReason = .notInterested
        let (stage, _) = try placement(ctx)
        #expect(stage == nil)
    }
}
