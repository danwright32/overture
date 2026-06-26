import Testing
import Foundation
import SwiftData
@testable import Overture

// #176 / #229: the pure core of the OmniFocus sync. `desired` builds the set of tasks that should
// exist right now (only remotely-actionable reminders, within a horizon, each carrying its due);
// `reconcile` diffs that against the existing Overture-tagged tasks into create/complete actions.
// No OmniFocus dependency here.
@MainActor
@Suite("OmniFocus sync")
struct OmniFocusSyncTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func lead(_ ctx: ModelContext, key: String, state: ConversationState?,
                      source: OutcomeSource?, outcome: Outcome = .replied,
                      setAt: Date?, performanceDate: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "choral", venue: "V",
                         performanceDate: performanceDate, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.sentAt = Date(timeIntervalSince1970: 1)
        p.outcome = outcome
        p.conversationStateRaw = state?.rawValue
        p.conversationStateSourceRaw = source?.rawValue
        p.conversationStateSetAt = setAt
        ctx.insert(p)
        return p
    }

    @Test func desiredIncludesConfirmedActiveWithinHorizonWithItsDue() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        // Confirmed (manual) wantsToBook set now: interval 7d -> due now+7d, inside a 14d horizon.
        lead(ctx, key: "warm-lead", state: .wantsToBook, source: .manual, setAt: now)
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                          now: now, horizonDays: 14)
        #expect(tasks.count == 1)
        #expect(tasks.first?.naturalKey == "warm-lead")
        #expect(tasks.first?.due == now.addingTimeInterval(7 * 86_400))
    }

    @Test func desiredExcludesUnconfirmedUncategorizedResolvedAndBeyondHorizon() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "auto", state: .wantsToBook, source: .auto, setAt: now)        // AI guess: in-app only
        lead(ctx, key: "needsState", state: nil, source: nil, setAt: nil)             // replied, uncategorized
        lead(ctx, key: "booked", state: .wantsToBook, source: .manual, outcome: .booked, setAt: now)
        lead(ctx, key: "farOff", state: .interested, source: .manual, setAt: now)     // interested = 10d > 3d horizon
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                          now: now, horizonDays: 3)
        #expect(tasks.isEmpty)
    }

    @Test func reconcileCreatesMissingAndCompletesStaleOrResolved() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let d1 = now.addingTimeInterval(7 * 86_400)
        let desired = [OmniFocusSync.DesiredTask(naturalKey: "a", title: "A", note: "", due: d1),
                       OmniFocusSync.DesiredTask(naturalKey: "c", title: "C", note: "", due: d1)]
        let existing = [OmniFocusSync.ExistingTask(naturalKey: "a", due: d1),                          // matches: leave
                        OmniFocusSync.ExistingTask(naturalKey: "b", due: d1),                          // resolved: complete
                        OmniFocusSync.ExistingTask(naturalKey: "c", due: now)]                         // stale due: complete + recreate
        let plan = OmniFocusSync.reconcile(desired: desired, existing: existing)
        #expect(Set(plan.toComplete.map(\.naturalKey)) == ["b", "c"])
        #expect(Set(plan.toCreate.map(\.naturalKey)) == ["c"])
    }
}
