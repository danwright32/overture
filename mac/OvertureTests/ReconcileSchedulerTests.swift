import Testing
import Foundation
import SwiftData
@testable import Overture

// #265 / Phase 1: the app-owned scheduler that runs the SAFE deterministic reconciles independent of
// any window. This covers its core tick — a reminder-due lead produces an OmniFocus task — with an
// injected clock and a fake OmniFocus client, so no AppleScript or real OmniFocus is touched. (The
// AppDelegate wiring + stripping the window's launch tasks is deferred to a runtime-verifiable session.)
private final class CapturingOmniFocusClient: OmniFocusClient, @unchecked Sendable {
    var created: [OmniFocusSync.DesiredTask] = []
    func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { [] }
    func create(_ task: OmniFocusSync.DesiredTask) throws { created.append(task) }
    func complete(naturalKey: String) throws {}
}

@MainActor
@Suite("Reconcile scheduler (#265)")
struct ReconcileSchedulerTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @Test func tickCreatesAnOmniFocusTaskForAReminderDueLead() throws {
        let ctx = ModelContext(try container())
        // A confirmed active conversation state set 30 days ago is due for a reminder now.
        let now = Date(timeIntervalSince1970: 40 * 86_400)
        let p = Prospect(naturalKey: "warm-lead", groupName: "Warm Lead", discipline: "choral", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = Date(timeIntervalSince1970: 1)
        p.outcome = .replied
        p.conversationState = .wantsToBook
        p.conversationStateSource = .manual
        p.conversationStateSetAt = now.addingTimeInterval(-30 * 86_400)
        ctx.insert(p)
        try ctx.save()

        let fake = CapturingOmniFocusClient()
        let scheduler = ReconcileScheduler(context: ctx)
        scheduler.syncOmniFocus(now: now, client: fake, horizonDays: 14, statusDefaults: freshDefaults())

        #expect(fake.created.contains { $0.naturalKey == "warm-lead" })
    }

    @Test func tickRecordsSyncSuccessSoTheFailureWarningClears() throws {
        let ctx = ModelContext(try container())
        let defaults = freshDefaults()
        OmniFocusSyncStatus.recordFailure("stale", at: Date(timeIntervalSince1970: 1), into: defaults)

        let scheduler = ReconcileScheduler(context: ctx)
        scheduler.syncOmniFocus(now: Date(timeIntervalSince1970: 100),
                                client: CapturingOmniFocusClient(), horizonDays: 14, statusDefaults: defaults)

        #expect(OmniFocusSyncStatus.lastFailure(from: defaults) == nil)   // a clean sync clears the warning
    }

    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "sched-\(UUID().uuidString)")! }
}
