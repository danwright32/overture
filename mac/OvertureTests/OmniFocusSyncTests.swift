import Testing
import Foundation
import SwiftData
@testable import Overture

// #176 / #229: the pure core of the OmniFocus sync. `desired` builds the set of tasks that should
// exist now (only remotely-actionable reminders, within a horizon), each carrying a defer date
// (11am Eastern on the due day) and a due date (6pm Eastern on the due day). `reconcile` diffs that
// against the existing Overture-tagged tasks (by naturalKey + due day) into create/complete actions.
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

    @Test func desiredCarriesDeferElevenAmAndDueSixPmEasternOnTheDueDay() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "warm-lead", state: .wantsToBook, source: .manual, setAt: now)  // wantsToBook = 7d
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                          now: now, horizonDays: 14)
        #expect(tasks.count == 1)
        let t = try #require(tasks.first)
        let cal = EasternDate.calendar
        let dueDay = now.addingTimeInterval(7 * 86_400)
        #expect(cal.component(.hour, from: t.deferDate) == 11)
        #expect(cal.component(.hour, from: t.dueDate) == 18)
        #expect(cal.isDate(t.deferDate, inSameDayAs: dueDay))
        #expect(cal.isDate(t.dueDate, inSameDayAs: dueDay))
    }

    // The note layout is load-bearing: the AppleScript client reads paragraph 1 (lead key) and
    // paragraph 2 (due day) back. Lock that order/format.
    @Test func desiredNoteCarriesLeadKeyThenDueDayInFirstTwoLines() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "warm-lead", state: .wantsToBook, source: .manual, setAt: now)
        let t = try #require(OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                                   now: now, horizonDays: 14).first)
        let lines = t.note.components(separatedBy: "\n")
        #expect(lines[0] == "Overture lead: warm-lead")
        #expect(lines[1] == "Due: " + EasternDate.dayString(from: t.dueDate))
    }

    @Test func desiredExcludesDismissedLeads() throws {
        // #238: a lead Dan dismissed is a no-go and must not generate an OmniFocus task, even if it
        // still carries an active confirmed conversation state.
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        let p = lead(ctx, key: "dismissed-but-active", state: .wantsToBook, source: .manual, setAt: now)
        p.status = .dismissed
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                          now: now, horizonDays: 14)
        #expect(tasks.isEmpty)
    }

    @Test func desiredExcludesUnconfirmedUncategorizedResolvedAndBeyondHorizon() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "auto", state: .wantsToBook, source: .auto, setAt: now)
        lead(ctx, key: "needsState", state: nil, source: nil, setAt: nil)
        lead(ctx, key: "booked", state: .wantsToBook, source: .manual, outcome: .booked, setAt: now)
        lead(ctx, key: "farOff", state: .interested, source: .manual, setAt: now)  // interested = 10d > 3d horizon
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                          now: now, horizonDays: 3)
        #expect(tasks.isEmpty)
    }

    // A fake client records what the orchestrator asked OmniFocus to do, with a preset existing set.
    final class FakeClient: OmniFocusClient {
        var existing: [OmniFocusSync.ExistingTask]
        var created: [OmniFocusSync.DesiredTask] = []
        var completed: [String] = []
        init(existing: [OmniFocusSync.ExistingTask]) { self.existing = existing }
        func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { existing }
        func create(_ task: OmniFocusSync.DesiredTask) throws { created.append(task) }
        func complete(naturalKey: String) throws { completed.append(naturalKey) }
    }

    @Test func runCreatesDesiredAndCompletesStaleViaTheClient() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "warm-lead", state: .wantsToBook, source: .manual, setAt: now)  // desired, due in 7d
        // OmniFocus already has a stale task for a lead that's since resolved.
        let fake = FakeClient(existing: [OmniFocusSync.ExistingTask(naturalKey: "gone", dueDate: now)])
        try OmniFocusSync.run(prospects: try ctx.fetch(FetchDescriptor<Prospect>()),
                              now: now, client: fake, horizonDays: 14)
        #expect(fake.created.map(\.naturalKey) == ["warm-lead"])
        #expect(fake.completed == ["gone"])
    }

    @Test func deepLinkEncodesLeadKeyIntoOvertureScheme() {
        let link = OmniFocusSync.deepLink(for: "Choir A | 2026-07-01 | Weill Recital Hall")
        #expect(link.hasPrefix("overture://lead?key="))
        #expect(!link.contains(" "))   // spaces and separators percent-encoded so it's a valid URL
    }

    @Test func configDefaultsOffWith14DayHorizonAndRoundTrips() {
        let defaults = UserDefaults(suiteName: "of-sync-test-\(UUID().uuidString)")!
        let blank = OmniFocusSyncConfig.loaded(from: defaults)
        #expect(blank.enabled == false)   // opt-in: off until Dan turns it on
        #expect(blank.horizonDays == 14)
        OmniFocusSyncConfig(enabled: true, horizonDays: 21).save(to: defaults)
        let reloaded = OmniFocusSyncConfig.loaded(from: defaults)
        #expect(reloaded.enabled == true)
        #expect(reloaded.horizonDays == 21)
    }

    @Test func reconcileCreatesMissingAndCompletesStaleOrResolved() {
        let day1Defer = Date(timeIntervalSince1970: 20_000_000)
        let day1Due = day1Defer.addingTimeInterval(7 * 3_600)
        let dayOldDue = day1Due.addingTimeInterval(-7 * 86_400)
        let desired = [OmniFocusSync.DesiredTask(naturalKey: "a", title: "A", note: "", deferDate: day1Defer, dueDate: day1Due),
                       OmniFocusSync.DesiredTask(naturalKey: "c", title: "C", note: "", deferDate: day1Defer, dueDate: day1Due)]
        let existing = [OmniFocusSync.ExistingTask(naturalKey: "a", dueDate: day1Due),   // matches: leave
                        OmniFocusSync.ExistingTask(naturalKey: "b", dueDate: day1Due),   // resolved: complete
                        OmniFocusSync.ExistingTask(naturalKey: "c", dueDate: dayOldDue)] // stale due day: complete + recreate
        let plan = OmniFocusSync.reconcile(desired: desired, existing: existing)
        #expect(Set(plan.toComplete.map(\.naturalKey)) == ["b", "c"])
        #expect(Set(plan.toCreate.map(\.naturalKey)) == ["c"])
    }
}
