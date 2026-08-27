import Testing
import Foundation
import SwiftData

// #1134: Reached out becomes its own stage, separate from Follow-ups. Because its rows are
// per-recipient (rendered by reachedOutList, not the standard QueueItem rows), it is a special focus
// like .followUps: it resolves no queue keys through `matches`, and its pill count comes from
// ReachedOutQueue instead. These tests pin both halves so the count Dan sees on the pill equals the
// rows he lands on (the #863 invariant), and so the focus never leaks into the matches-based
// queue-key resolution.
@MainActor
@Suite("Reached out is its own stage (#1134)")
struct ReachedOutStageTests {
    private let today = ScoutTestClock.stageNavigationAnchor
    private let now = Date(timeIntervalSince1970: 1_768_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: "2026-09-19", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.draftBody = "Hello, I photograph performances."
        ctx.insert(p)
        return p
    }

    // A recipient that has genuinely been reached out to (sent, with an address and a gmail message id),
    // so ReachedOutQueue counts it.
    @discardableResult
    private func reachedOutContact(_ ctx: ModelContext, on p: Prospect, id: String) -> Recipient {
        let r = Recipient(id: id, email: id, provenance: .act)
        r.sentAt = now.addingTimeInterval(-2 * 86_400)
        r.sendState = .sent
        r.gmailMessageId = "msg-\(id)"
        p.setRecipients(p.recipients + [r])
        ctx.insert(r)
        return r
    }

    // .reachedOut is not a matches-based focus: it resolves no queue keys, exactly like .followUps, so
    // the standard focused-list rendering never tries to look its rows up by natural key.
    @Test func reachedOutResolvesNoQueueKeys() throws {
        let ctx = try context()
        let p = show(ctx, "pitched", status: .contacted)
        reachedOutContact(ctx, on: p, id: "a@org.example")
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        #expect(StageNavigation.naturalKeys(for: .reachedOut, in: all, context: .at(today, now: now)).isEmpty)
    }

    // Like .followUps, .reachedOut is excluded from the single-pass counted focuses, so it never adds a
    // meaningless zero from `matches` (its real count comes from ReachedOutQueue).
    @Test func reachedOutIsNotAMatchesCountedFocus() {
        #expect(!StageNavigation.countedFocuses.contains(.reachedOut))
    }

    // #1194 (Dan's call): the Reached-out pill counts SHOWS, like every other stage pill (Scout/Prep/
    // Review), even though its LIST stays one row per recipient (#652). So a show pitched to two contacts
    // makes the pill read one fewer than the list, and that is intended: cross-pill consistency (a stage
    // number always means shows) wins over this one pill matching its per-recipient list.
    // #2396: the list counts shows too now, so the pill and its rows are the same quantity and the tension
    // this test was written to record is gone.
    @Test func inputsReachedOutPillAndItsRowsCountTheSameShows() throws {
        let ctx = try context()
        let a = show(ctx, "one", status: .contacted)
        reachedOutContact(ctx, on: a, id: "a@org.example")
        let b = show(ctx, "two", status: .contacted)
        reachedOutContact(ctx, on: b, id: "b@org.example")
        reachedOutContact(ctx, on: b, id: "c@org.example")   // two contacts on show "two"
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let inputs = AgentInputs.from(prospects: all, allProspects: all, context: .at(today, now: now),
                                      gmailConnected: true, runInFlight: nil, replyRunAlive: false)

        #expect(ReachedOutQueue.activeWithDates(from: all, now: now).count == 2)   // two rows, one per show
        #expect(inputs.reachedOut == 2)                                           // and the pill agrees
    }

    // Deep-link routing: a lead already in the reached-out queue focuses the Reached out stage, so a
    // tapped follow-up or search pick lands on the right stage now that the pipeline picker is gone.
    @Test func stageContainingRoutesAReachedOutLeadToTheReachedOutStage() throws {
        let ctx = try context()
        let p = show(ctx, "pitched", status: .contacted)
        reachedOutContact(ctx, on: p, id: "a@org.example")
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        #expect(StageNavigation.stage(containing: "pitched", in: all,
                                      reachedOutKeys: ["pitched"], context: .at(today, now: now)) == .reachedOut)
    }

    // A lead still awaiting a decision focuses the Scout stage; a drafted one focuses Review.
    @Test func stageContainingRoutesByStatusForNonReachedOutLeads() throws {
        let ctx = try context()
        show(ctx, "fresh", status: .new)
        show(ctx, "drafted", status: .drafted)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        #expect(StageNavigation.stage(containing: "fresh", in: all,
                                      reachedOutKeys: [], context: .at(today, now: now)) == .scout)
        #expect(StageNavigation.stage(containing: "drafted", in: all,
                                      reachedOutKeys: [], context: .at(today, now: now)) == .review)
    }
}
