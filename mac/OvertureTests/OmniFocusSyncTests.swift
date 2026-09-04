import Testing
import Foundation
import SwiftData

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

    // #2397: a show with ONE sent recipient. What earns an OmniFocus task is no longer a conversation
    // state Dan set (those are retired) but one of two things: a post-event prompt, which needs
    // `performanceDate` in the past, or a reply he has not answered.
    @discardableResult
    // The default show date is in the PAST, because the post-event prompt is what most of these tests are
    // about: it is the one thing that now earns a task on a date Overture computes.
    private func lead(_ ctx: ModelContext, key: String, replied: Bool = true,
                      performanceDate: String? = "1970-04-25",
                      recipientName: String? = "Jane Doe") -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "choral", venue: "V",
                         performanceDate: performanceDate, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let r = Recipient(id: key + "@e.com", email: key + "@e.com", name: recipientName, provenance: .act)
        r.sendState = .sent
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.gmailMessageId = "m-" + key
        if replied { r.reopenOnReply(at: Date(timeIntervalSince1970: 2)) }
        ctx.insert(r)
        p.setRecipients([r])
        return (p, r)
    }

    @Test func desiredCarriesDeferElevenAmAndDueSixPmEasternOnTheDueDay() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        // #2397: the task lands on the day AFTER the show, which is when the prompt starts being owed.
        lead(ctx, key: "warm-lead", replied: false, performanceDate: "1970-04-25")
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                          now: now, horizonDays: 14)
        #expect(tasks.count == 1)
        let t = try #require(tasks.first)
        let cal = EasternDate.calendar
        let dueDay = try #require(EasternDate.date(from: "1970-04-26"))
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
        lead(ctx, key: "warm-lead")
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
        lead(ctx, key: "Aurora Strings", recipientName: "Jane Doe")
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
        let (p, _) = lead(ctx, key: "dismissed-but-active", replied: false)
        p.status = .dismissed
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                          now: now, horizonDays: 14)
        #expect(tasks.isEmpty)
    }

    @Test func desiredExcludesUnconfirmedUncategorizedResolvedAndBeyondHorizon() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        // #2397: three ways to earn nothing. A show still AHEAD has no post-event prompt and, with no
        // reply, nothing to answer. A resolved contact is closed. And a show whose prompt is real but
        // falls outside the horizon stays out until it is near.
        lead(ctx, key: "ahead", replied: false, performanceDate: "2030-01-01")
        let (_, resolved) = lead(ctx, key: "booked")
        resolved.resolution = .booked
        lead(ctx, key: "farOff", replied: false, performanceDate: "1999-01-01")
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                          now: now, horizonDays: 3)
        #expect(tasks.isEmpty)
    }

    // #271: a reply Dan has not answered would otherwise leave NO trace in OmniFocus while he is away from
    // his desk: only an in-app badge he cannot see. Emit a triage task, keyed by the same
    // (naturalKey, recipientId) so reconcile dedupes it against the eventual follow-up.
    //
    // #2397: the show is still AHEAD here, so the post-event prompt does not apply and the unanswered reply
    // is what earns the task. With the date passed the prompt wins, which the suite above covers.
    @Test func desiredEmitsTriageTaskForAnUnansweredReply() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        let (_, r) = lead(ctx, key: "fresh-reply", replied: true, performanceDate: "2030-01-01")
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()), now: now, horizonDays: 3)
        #expect(tasks.count == 1)
        let t = try #require(tasks.first)
        #expect(t.naturalKey == "fresh-reply")   // same key → reconcile dedupes against the follow-up
        #expect(t.recipientId == r.id)
        #expect(t.title.contains("reply to"))
    }

    @Test func desiredTriagesAnUnansweredReplyOnAShowStillAhead() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "auto-reply", replied: true, performanceDate: "2030-01-01")
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
        lead(ctx, key: "fresh-reply", replied: true, performanceDate: "2030-01-01")
        let prospects = try ctx.fetch(FetchDescriptor<Prospect>())
        let t1 = try #require(OmniFocusSync.desired(from: prospects, now: day1, horizonDays: 3).first)
        let t2 = try #require(OmniFocusSync.desired(from: prospects, now: day2, horizonDays: 3).first)
        #expect(t1.dueDate == t2.dueDate)
    }

    @Test func desiredDoesNotTriageARecipientWithNoReply() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "no-reply", replied: false, performanceDate: "2030-01-01")
        let tasks = OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()), now: now, horizonDays: 3)
        #expect(tasks.isEmpty)
    }

    // #2397: the post-event prompt outranks the reply triage, because once the show is over the thing Dan
    // owes is an ending rather than an answer. Both are keyed on the same (naturalKey, recipientId), so
    // reconcile replaces one with the other rather than leaving him two chores for one show.
    @Test func desiredPrefersThePostEventPromptOverTheReplyTriage() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "passed", replied: true, performanceDate: "1970-04-25")
        let t = try #require(OmniFocusSync.desired(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                                   now: now, horizonDays: 14).first)
        #expect(t.title.contains("follow up"))
        #expect(!t.title.contains("reply to"))
    }

    // #653: the actual behavior change. A show with two contacts, one with a confirmed active state
    // and one with an uncategorized reply, must produce TWO separate tasks, not one for the whole show.
    @Test func aMultiContactShowProducesOneTaskPerRecipient() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        let p = Prospect(naturalKey: "multi", groupName: "Multi Show", discipline: "choral", venue: "V",
                         performanceDate: nil, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let confirmed = Recipient(id: "a@e.com", email: "a@e.com", name: "Confirmed Contact", provenance: .act)
        confirmed.sendState = .sent; confirmed.sentAt = Date(timeIntervalSince1970: 1); confirmed.replied = true
        confirmed.reopenOnReply(at: Date())
        let uncategorized = Recipient(id: "b@e.com", email: "b@e.com", name: "Uncategorized Contact", provenance: .presenter)
        uncategorized.sendState = .sent; uncategorized.sentAt = Date(timeIntervalSince1970: 1); uncategorized.replied = true
        p.setRecipients([confirmed, uncategorized])

        let tasks = OmniFocusSync.desired(from: [p], now: now, horizonDays: 14)
        #expect(Set(tasks.map(\.recipientId)) == ["a@e.com", "b@e.com"])
        #expect(tasks.allSatisfy { $0.naturalKey == "multi" })
    }

    // A fake client records what the orchestrator asked OmniFocus to do, with a preset existing set.
    final class FakeClient: OmniFocusClient, @unchecked Sendable {
        var existing: [OmniFocusSync.ExistingTask]
        var created: [OmniFocusSync.DesiredTask] = []
        var completed: [OmniFocusSync.ExistingTask] = []
        init(existing: [OmniFocusSync.ExistingTask]) { self.existing = existing }
        func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { existing }
        func completedOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { [] }
        func create(_ task: OmniFocusSync.DesiredTask) throws { created.append(task) }
        func complete(_ task: OmniFocusSync.ExistingTask) throws { completed.append(task) }
    }

    @Test func runCreatesDesiredAndCompletesStaleViaTheClient() throws {
        let ctx = ModelContext(try container())
        let now = Date(timeIntervalSince1970: 10_000_000)
        lead(ctx, key: "warm-lead")  // desired, due in 7d
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
        lead(ctx, key: key, replied: false)
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
        let desired = [OmniFocusSync.DesiredTask(kind: .replyTriage, naturalKey: "a", recipientId: "a@e.com", title: "A", note: "", deferDate: day1Defer, dueDate: day1Due),
                       OmniFocusSync.DesiredTask(kind: .replyTriage, naturalKey: "c", recipientId: "c@e.com", title: "C", note: "", deferDate: day1Defer, dueDate: day1Due)]
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
        let desired = [OmniFocusSync.DesiredTask(kind: .replyTriage, naturalKey: "multi", recipientId: "a@e.com", title: "A", note: "", deferDate: due, dueDate: due),
                       OmniFocusSync.DesiredTask(kind: .replyTriage, naturalKey: "multi", recipientId: "b@e.com", title: "B", note: "", deferDate: due, dueDate: due)]
        let plan = OmniFocusSync.reconcile(desired: desired, existing: [])
        #expect(Set(plan.toCreate.map(\.recipientId)) == ["a@e.com", "b@e.com"])
    }
}
