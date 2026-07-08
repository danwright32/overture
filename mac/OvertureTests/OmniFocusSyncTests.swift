import Testing
import Foundation
import SwiftData
@testable import Overture

// #176 / #229 / #653: the pure core of the OmniFocus sync. `desired` builds the set of tasks that
// should exist now, ONE PER RECIPIENT (only remotely-actionable reminders, within a horizon), each
// carrying a defer date (11am Eastern on the due day) and a due date (6pm Eastern on the due day).
// `reconcile` diffs that against the existing Overture-tagged tasks (by naturalKey + recipientId +
// due day) into create/complete actions.
@MainActor
@Suite("OmniFocus sync")
struct OmniFocusSyncTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A show with ONE recipient carrying the given conversation state, mirroring the old lead-level
    // helper but seeding the state onto the contact directly (the #650/#652 model).
    @discardableResult
    private func lead(_ ctx: ModelContext, key: String, state: ConversationState?,
                      source: OutcomeSource?, replied: Bool = true,
                      setAt: Date?, performanceDate: String? = nil,
                      recipientName: String? = "Jane Doe") -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "choral", venue: "V",
                         performanceDate: performanceDate, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let r = Recipient(id: key + "@e.com", email: key + "@e.com", name: recipientName, provenance: .act)
        r.sendState = .sent
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.replied = replied
        r.conversationStateRaw = state?.rawValue
        r.conversationStateSourceRaw = source?.rawValue
        r.conversationStateSetAt = setAt
        ctx.insert(r)
        p.setRecipients([r])
        return (p, r)
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

    // The note layout is load-bearing: the AppleScript client reads paragraph 1 (lead key), paragraph
    // 2 (recipient id, #653), and paragraph 3 (due day) back. Lock that order/format.
    @Test func desiredNoteCarriesLeadKeyThenRecipientThenDueDayInFirstThreeLines() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "warm-lead", state: .wantsToBook, source: .manual, setAt: now)
        let t = try #require(OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                                   now: now, horizonDays: 14).first)
        let lines = t.note.components(separatedBy: "\n")
        #expect(lines[0] == "Overture lead: warm-lead")
        #expect(lines[1] == "Overture contact: warm-lead@e.com")
        #expect(lines[2] == "Due: " + EasternDate.dayString(from: t.dueDate))
    }

    // #653 (Dan's requirement): every task title includes both the show name and the contact.
    @Test func desiredTitleIncludesShowAndContactName() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "Aurora Strings", state: .wantsToBook, source: .manual, setAt: now, recipientName: "Jane Doe")
        let t = try #require(OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                                   now: now, horizonDays: 14).first)
        #expect(t.title.contains("Aurora Strings"))
        #expect(t.title.contains("Jane Doe"))
    }

    @Test func desiredExcludesDismissedLeads() throws {
        // #238: a lead Dan dismissed is a no-go and must not generate an OmniFocus task, even if it
        // still carries an active confirmed conversation state.
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        let (p, _) = lead(ctx, key: "dismissed-but-active", state: .wantsToBook, source: .manual, setAt: now)
        p.status = .dismissed
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                          now: now, horizonDays: 14)
        #expect(tasks.isEmpty)
    }

    @Test func desiredExcludesUnconfirmedUncategorizedResolvedAndBeyondHorizon() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        // No-reply contacts: an .auto suggestion and a needsState contact with nothing to triage stay
        // out of OmniFocus (the #271 triage only fires when there's an actual reply). A resolved
        // contact is closed; the confirmed contact's next reach-out is beyond the horizon.
        lead(ctx, key: "auto", state: .wantsToBook, source: .auto, replied: false, setAt: now)
        lead(ctx, key: "needsState", state: nil, source: nil, replied: false, setAt: nil)
        let (_, resolved) = lead(ctx, key: "booked", state: .wantsToBook, source: .manual, setAt: now)
        resolved.resolution = .booked
        lead(ctx, key: "farOff", state: .interested, source: .manual, setAt: now)  // interested = 10d > 3d horizon
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                          now: now, horizonDays: 3)
        #expect(tasks.isEmpty)
    }

    // #271 / Phase 7: a reply Dan hasn't categorized would otherwise leave NO trace in OmniFocus while
    // he's away (the needsState/.auto guards drop it). Emit a "triage" task instead, keyed by the same
    // (naturalKey, recipientId) so it dedupes against the eventual follow-up.
    @Test func desiredEmitsTriageTaskForRepliedUncategorizedRecipient() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        let (_, r) = lead(ctx, key: "fresh-reply", state: nil, source: nil, replied: true, setAt: nil)
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()), now: now, horizonDays: 3)
        #expect(tasks.count == 1)
        let t = try #require(tasks.first)
        #expect(t.naturalKey == "fresh-reply")   // same key → reconcile dedupes against the follow-up
        #expect(t.recipientId == r.id)
        #expect(t.title.contains("reply to"))
    }

    @Test func desiredTriagesAnAutoSuggestedRepliedRecipient() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "auto-reply", state: .wantsToBook, source: .auto, replied: true, setAt: now)
        let t = try #require(OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                                   now: now, horizonDays: 3).first)
        #expect(t.naturalKey == "auto-reply")
        #expect(t.title.contains("reply to"))
    }

    @Test func triageTaskDueIsStableAcrossReconcilesSoItDoesNotChurn() throws {
        // Anchored to a date on the recipient, not "now", so a still-uncategorized reply keeps the
        // SAME OmniFocus task day after day rather than completing+recreating it every reconcile.
        let ctx = ModelContext(try container())
        let day1 = Date(timeIntervalSince1970: 10_000_000)
        let day2 = day1.addingTimeInterval(3 * 86_400)
        lead(ctx, key: "fresh-reply", state: nil, source: nil, replied: true, setAt: nil)
        let prospects = try ctx.fetch(FetchDescriptor<Prospect>())
        let t1 = try #require(OmniFocusSync.desired(from: prospects, now: day1, horizonDays: 3).first)
        let t2 = try #require(OmniFocusSync.desired(from: prospects, now: day2, horizonDays: 3).first)
        #expect(t1.dueDate == t2.dueDate)
    }

    @Test func desiredDoesNotTriageARecipientWithNoReply() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "no-reply", state: nil, source: nil, replied: false, setAt: nil)
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()), now: now, horizonDays: 3)
        #expect(tasks.isEmpty)
    }

    @Test func desiredPrefersFollowUpOverTriageForAConfirmedRepliedRecipient() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "confirmed", state: .wantsToBook, source: .manual, replied: true, setAt: now)
        let t = try #require(OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                                   now: now, horizonDays: 14).first)
        #expect(t.title.contains("follow up"))      // confirmed → the normal follow-up, not a triage task
        #expect(!t.title.contains("reply to"))
    }

    // #653: the actual behavior change. A show with two contacts, one with a confirmed active state
    // and one with an uncategorized reply, must produce TWO separate tasks, not one for the whole show.
    @Test func aMultiContactShowProducesOneTaskPerRecipient() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        let p = Prospect(naturalKey: "multi", groupName: "Multi Show", discipline: "choral", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let confirmed = Recipient(id: "a@e.com", email: "a@e.com", name: "Confirmed Contact", provenance: .act)
        confirmed.sendState = .sent; confirmed.sentAt = Date(timeIntervalSince1970: 1); confirmed.replied = true
        confirmed.setConversationState(.wantsToBook, now: now)
        let uncategorized = Recipient(id: "b@e.com", email: "b@e.com", name: "Uncategorized Contact", provenance: .presenter)
        uncategorized.sendState = .sent; uncategorized.sentAt = Date(timeIntervalSince1970: 1); uncategorized.replied = true
        p.setRecipients([confirmed, uncategorized])

        let tasks = OmniFocusSync.desired(from: [p], now: now, horizonDays: 14)
        #expect(Set(tasks.map(\.recipientId)) == ["a@e.com", "b@e.com"])
        #expect(tasks.allSatisfy { $0.naturalKey == "multi" })
    }

    // A fake client records what the orchestrator asked OmniFocus to do, with a preset existing set.
    final class FakeClient: OmniFocusClient {
        var existing: [OmniFocusSync.ExistingTask]
        var created: [OmniFocusSync.DesiredTask] = []
        var completed: [(naturalKey: String, recipientId: String)] = []
        init(existing: [OmniFocusSync.ExistingTask]) { self.existing = existing }
        func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { existing }
        func create(_ task: OmniFocusSync.DesiredTask) throws { created.append(task) }
        func complete(naturalKey: String, recipientId: String) throws { completed.append((naturalKey, recipientId)) }
    }

    @Test func runCreatesDesiredAndCompletesStaleViaTheClient() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "warm-lead", state: .wantsToBook, source: .manual, setAt: now)  // desired, due in 7d
        // OmniFocus already has a stale task for a contact that's since resolved.
        let fake = FakeClient(existing: [OmniFocusSync.ExistingTask(naturalKey: "gone", recipientId: "gone@e.com", dueDate: now)])
        try OmniFocusSync.run(prospects: try ctx.fetch(FetchDescriptor<Prospect>()),
                              now: now, client: fake, horizonDays: 14)
        #expect(fake.created.map(\.naturalKey) == ["warm-lead"])
        #expect(fake.completed.map(\.naturalKey) == ["gone"])
    }

    // #307: the OmniFocus note's deep link is built by the single OvertureDeepLink builder, so the
    // embedded link and the app's parser can never drift. The note line must equal exactly what
    // OvertureDeepLink.leadURL produces (spaces/pipes/hyphens are the chars a naturalKey carries).
    @Test func noteDeepLinkIsBuiltByTheSingleOvertureDeepLinkBuilder() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        let key = "Choir A|2026-07-01|Weill Recital Hall"
        lead(ctx, key: key, state: .wantsToBook, source: .manual, setAt: now)
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                          now: now, horizonDays: 14)
        let note = try #require(tasks.first?.note)
        let linkLine = try #require(note.split(separator: "\n").first { $0.hasPrefix("Open in Overture: ") })
        let expected = try #require(OvertureDeepLink.leadURL(forKey: key)?.absoluteString)
        #expect(linkLine == "Open in Overture: \(expected)")
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
        let desired = [OmniFocusSync.DesiredTask(naturalKey: "a", recipientId: "a@e.com", title: "A", note: "", deferDate: day1Defer, dueDate: day1Due),
                       OmniFocusSync.DesiredTask(naturalKey: "c", recipientId: "c@e.com", title: "C", note: "", deferDate: day1Defer, dueDate: day1Due)]
        let existing = [OmniFocusSync.ExistingTask(naturalKey: "a", recipientId: "a@e.com", dueDate: day1Due),   // matches: leave
                        OmniFocusSync.ExistingTask(naturalKey: "b", recipientId: "b@e.com", dueDate: day1Due),   // resolved: complete
                        OmniFocusSync.ExistingTask(naturalKey: "c", recipientId: "c@e.com", dueDate: dayOldDue)] // stale due day: complete + recreate
        let plan = OmniFocusSync.reconcile(desired: desired, existing: existing)
        #expect(Set(plan.toComplete.map(\.naturalKey)) == ["b", "c"])
        #expect(Set(plan.toCreate.map(\.naturalKey)) == ["c"])
    }

    // #653: two contacts on the SAME show must be tracked as distinct tasks, not collapse onto one
    // naturalKey the way the pre-#653 keying would have.
    @Test func reconcileTreatsDifferentRecipientsOnTheSameShowAsDistinctTasks() {
        let due = Date(timeIntervalSince1970: 20_000_000)
        let desired = [OmniFocusSync.DesiredTask(naturalKey: "multi", recipientId: "a@e.com", title: "A", note: "", deferDate: due, dueDate: due),
                       OmniFocusSync.DesiredTask(naturalKey: "multi", recipientId: "b@e.com", title: "B", note: "", deferDate: due, dueDate: due)]
        let plan = OmniFocusSync.reconcile(desired: desired, existing: [])
        #expect(Set(plan.toCreate.map(\.recipientId)) == ["a@e.com", "b@e.com"])
    }
}
