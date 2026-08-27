import Testing
import Foundation
import SwiftData

// #1121: the stage-pill counts used to run one full pass over every prospect PER focus (nine passes),
// and each send-related pass faulted the lazily loaded `recipients` relationship on the main thread all
// over again. StageNavigation.counts collapses that into a single pass, so a prospect's recipients fault
// at most once while counting instead of once per send focus.
//
// The one thing that pass must not change is the numbers. counts[focus] has to equal the length of
// naturalKeys(for: focus) for every focus, because that is the invariant the whole design rests on
// (#863): the number a pill shows is a promise about the rows its tap lands on. This suite pins the
// single-pass count to the per-focus navigation it must agree with, over a store holding one of each
// send problem (blocked, stuck, degraded, failed) plus the ordinary stages.
@MainActor
@Suite("Single-pass stage counts equal per-focus navigation (#1121)")
struct StageNavigationCountsTests {
    private let today = ScoutTestClock.stageNavigationAnchor
    private let now = Date(timeIntervalSince1970: 1_768_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, status: ReviewStatus = .new,
                      date: String = "2026-09-19", hasDraft: Bool = true, sentAt: Date? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: date, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        if hasDraft { p.draftBody = "Hello, I photograph performances." }
        p.sentAt = sentAt
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ ctx: ModelContext, on p: Prospect, email: String = "a@org.example") -> Recipient {
        let r = Recipient(id: "\(p.naturalKey)-\(email)", email: email, name: "Someone",
                          role: "Manager", provenance: .act)
        r.prospect = p
        p.recipients.append(r)
        ctx.insert(r)
        return r
    }

    // A store carrying one show for every queue-resolving focus at once, so a single-pass count that
    // mishandled any focus (double-counted, skipped, or leaked a send focus into another) shows up as a
    // disagreement with that focus's own navigation.
    private func oneOfEverything(_ ctx: ModelContext) {
        show(ctx, "to-triage", status: .new, hasDraft: false)
        show(ctx, "to-prep", status: .queued, hasDraft: false)
        show(ctx, "to-review", status: .drafted)
        show(ctx, "to-send", status: .approved)

        let failed = show(ctx, "failed", status: .approved)
        failed.sendError = "550 mailbox unavailable"

        let stuck = show(ctx, "stuck", status: .approved)
        let stuckR = contact(ctx, on: stuck)
        stuckR.sendState = .sending
        stuckR.sendClaimedAt = now.addingTimeInterval(-RunTimeouts.send - 60)

        let degraded = show(ctx, "degraded", status: .contacted, sentAt: now)
        contact(ctx, on: degraded).replyTrackingDegraded = true

        let held = show(ctx, "held", status: .contacted, sentAt: now)
        contact(ctx, on: held, email: "held@org.example").looksLikeVenue = true
    }

    // Every focus that resolves queue keys, counted in one pass, agrees with counting it the old way
    // (one naturalKeys pass per focus). Follow-ups is deliberately excluded: it resolves no keys.
    @Test func singlePassCountMatchesPerFocusNavigation() throws {
        let ctx = try context()
        oneOfEverything(ctx)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let counts = StageNavigation.counts(in: all, context: .at(today, now: now))
        let focuses: [StageFocus] = [.scout, .prep, .review, .sendApproved, .sendBlocked,
                                     .sendErrors, .sendStuck, .sendDegraded]

        for focus in focuses {
            let navCount = StageNavigation.naturalKeys(for: focus, in: all, context: .at(today, now: now)).count
            #expect(counts[focus] ?? 0 == navCount,
                    "counts[\(focus)] = \(counts[focus] ?? 0) but naturalKeys(\(focus)).count = \(navCount)")
        }
    }

    // The single pass and per-focus navigation must also agree on an empty store: every counted focus is
    // zero, not absent-and-therefore-wrong.
    @Test func anEmptyStoreCountsZeroForEveryFocus() throws {
        let ctx = try context()
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let counts = StageNavigation.counts(in: all, context: .at(today, now: now))
        let focuses: [StageFocus] = [.scout, .prep, .review, .sendApproved, .sendBlocked,
                                     .sendErrors, .sendStuck, .sendDegraded]
        for focus in focuses {
            #expect(counts[focus] ?? 0 == 0)
        }
    }

    // AgentInputs.from now builds its focus counts through the single pass, so its output has to be byte
    // for byte what the per-focus navigation would have produced. This is the same invariant
    // StagePillCountMatchesNavigationTests asserts, checked here on the send problems specifically.
    @Test func inputsFromMatchesNavigationForEverySendProblem() throws {
        let ctx = try context()
        oneOfEverything(ctx)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let inputs = AgentInputs.from(prospects: all, allProspects: all, context: .at(today, now: now),
                                      gmailConnected: true, runInFlight: nil, replyRunAlive: false)
        func nav(_ f: StageFocus) -> Int { StageNavigation.naturalKeys(for: f, in: all, context: .at(today, now: now)).count }

        #expect(inputs.toTriage == nav(.scout))
        #expect(inputs.keptToPrep == nav(.prep))
        #expect(inputs.toReview == nav(.review))
        #expect(inputs.readyToSend == nav(.sendApproved))
        #expect(inputs.sendErrors == nav(.sendErrors))
        #expect(inputs.stuckSends == nav(.sendStuck))
        #expect(inputs.degradedReplyTracking == nav(.sendDegraded))
        #expect(inputs.blockedContacts == nav(.sendBlocked))
    }
}
