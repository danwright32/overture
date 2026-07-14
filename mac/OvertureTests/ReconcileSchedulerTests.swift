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
    func complete(naturalKey: String, recipientId: String) throws {}
}

private struct NoopNotifier: OmniFocusNotifier {
    func notifyPermissionNeeded() {}
    func notifySyncFailed(_ message: String) {}
}

@MainActor
@Suite("Reconcile scheduler (#265)")
struct ReconcileSchedulerTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @Test func hasNewReplyFollowsAContactNotJustTheLeadOutcome() throws {
        // Phase F: the away-alert "new reply" diff reads a contact replying, not the (deleted) lead
        // rollup. A replied contact counts even with the lead outcome still noResponse.
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.sentAt = Date(timeIntervalSince1970: 1)
        ctx.insert(p)
        #expect(ReconcileScheduler.hasNewReply(p) == false)

        let r = Recipient(id: "c@e.com", email: "c@e.com", provenance: .act)
        r.sendState = .sent
        r.replied = true
        p.setRecipients([r])
        #expect(ReconcileScheduler.hasNewReply(p))
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
        ctx.insert(p)
        // #653: the conversation state lives on the recipient, not the lead.
        let r = Recipient(id: "contact@warm-lead.example", email: "contact@warm-lead.example", provenance: .act)
        r.sendState = .sent
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.replied = true
        r.conversationState = .wantsToBook
        r.conversationStateSource = .manual
        r.conversationStateSetAt = now.addingTimeInterval(-30 * 86_400)
        p.setRecipients([r])
        try ctx.save()

        let fake = CapturingOmniFocusClient()
        let scheduler = ReconcileScheduler(context: ctx)
        // #268: inject granted permission so this exercises the apply path (the real silent probe would
        // skip under the test host); the gating decision itself is covered by OmniFocusSyncRunnerTests.
        scheduler.syncOmniFocus(now: now, client: fake, horizonDays: 14,
                                permission: .granted, notifier: NoopNotifier(), statusDefaults: freshDefaults())

        #expect(fake.created.contains { $0.naturalKey == "warm-lead" })
    }

    @Test func tickRecordsSyncSuccessSoTheFailureWarningClears() throws {
        let ctx = ModelContext(try container())
        let defaults = freshDefaults()
        OmniFocusSyncStatus.recordFailure("stale", at: Date(timeIntervalSince1970: 1), into: defaults)

        let scheduler = ReconcileScheduler(context: ctx)
        scheduler.syncOmniFocus(now: Date(timeIntervalSince1970: 100),
                                client: CapturingOmniFocusClient(), horizonDays: 14,
                                permission: .granted, notifier: NoopNotifier(), statusDefaults: defaults)

        #expect(OmniFocusSyncStatus.lastFailure(from: defaults) == nil)   // a clean sync clears the warning
    }

    // #301/#308: the while-away alert threads the new leads' keys onto the notification so a tap deep-
    // links — to the sole lead when one is new, and to the filtered set when several are.
    @Test func whileAwayAlertCarriesTheDeepLinkKeyForASoleNewLead() {
        let scheduler = ReconcileScheduler(context: ModelContext(try! container()))
        var captured: (body: String, keys: [String])?
        scheduler.notifyIfNewWhileAway(
            ReconcileSummary(omniFocusChanged: 0, newReplies: ["Carnegie Hall"], newReplyKeys: ["carnegie|2026|hall"]),
            post: { captured = (body: $0, keys: $1) })
        #expect(captured?.keys == ["carnegie|2026|hall"])
    }

    @Test func whileAwayAlertCarriesEveryNewKeyWhenSeveralLeadsAreNew() {
        let scheduler = ReconcileScheduler(context: ModelContext(try! container()))
        var captured: (body: String, keys: [String])?
        scheduler.notifyIfNewWhileAway(
            ReconcileSummary(omniFocusChanged: 0, newReplies: ["A", "B"], newReplyKeys: ["a|2026|v", "b|2026|v"]),
            post: { captured = (body: $0, keys: $1) })
        #expect(captured != nil)                                  // a message was posted
        #expect(captured?.keys == ["a|2026|v", "b|2026|v"])       // carrying the whole set
    }

    // #617: a real save() failure (not just the source-scan guard in
    // ReconcileSchedulerSaveGuardTests), via ImmutableStoreFixture. reconcileBookings takes its
    // own injectable `from url:` (mirroring DownbeatBridge.loadWithHealth's existing `from url:`
    // parameter) so a real export file drives a genuine n>0 booking match without touching Dan's
    // actual Downbeat export path.
    @Test func reconcileBookingsReportsSaveFailedOnAGenuineSaveFailure() async throws {
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("downbeat-export-\(UUID().uuidString).json")
        let json = """
        {"version":2,"clients":[],"venues":[],"bookings":[
          {"id":"B1","clientId":"C1","clientDisplayName":"Acme Festival Chorus","shootName":"Gala",
           "startDate":"2026-07-01","endDate":"2026-07-01","venueName":"V"}
        ],"blockedDates":[]}
        """
        try json.write(to: exportURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let result = try await ImmutableStoreFixture.withFailingSave(
            schema: Schema([Prospect.self, Recipient.self]),
            seed: { ctx in
                let p = Prospect(naturalKey: "k", groupName: "Acme Festival Chorus", discipline: "choral",
                                 venue: "V", performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                                 priorRelationship: "none", production: "self", profile: "strong",
                                 coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                                 status: .approved)
                p.sentAt = Date(timeIntervalSince1970: 1_735_689_600)   // 2025-01-01, well before the booking
                p.downbeatClientId = "C1"
                ctx.insert(p)
            },
            body: { ctx in
                let scheduler = ReconcileScheduler(context: ctx)
                return scheduler.reconcileBookings(now: Date(), from: exportURL)
            })

        #expect(result.count == 1)
        #expect(result.saveFailed)
    }

    // #923: a booking is one of the two inputs to a conflict, and Downbeat changes it, not Dan. The scout
    // judges a show's conflict when the show arrives; the day-off sheet re-judges on Dan's edits (#901/#922).
    // Neither fires when a NEW booking lands in the export, so until the next scout a show on a newly booked
    // night carries no flag and stays sendable. The reconcile tick already reads the export to mark bookings;
    // it now re-judges conflicts on the same trigger (launch, timer, export-change), closing that hole.
    @Test func reapplyConflictsFlagsAShowOnANewlyBookedNight() throws {
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("downbeat-export-\(UUID().uuidString).json")
        let json = """
        {"version":2,"clients":[],"venues":[],"bookings":[
          {"id":"B1","clientId":"C1","clientDisplayName":"A Client","shootName":"Nguyen Recital",
           "startDate":"2026-11-18","endDate":"2026-11-18","venueName":"V"}
        ],"blockedDates":[]}
        """
        try json.write(to: exportURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, DayOff.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "k", groupName: "Vienna Philharmonic", discipline: "music",
                         venue: "Stern Auditorium", performanceDate: "2026-11-18", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        try ctx.save()
        #expect(p.hasUnclearedConflict == false)   // the scout ran before the booking existed

        let scheduler = ReconcileScheduler(context: ctx)
        scheduler.reapplyConflicts(now: Date(), from: exportURL)

        #expect(p.hasUnclearedConflict)                                          // flagged, no scout needed
        #expect(p.conflictNote == "You're already shooting Nguyen Recital on Nov 18.")
    }

    // #923, the other direction: a booking cancelled in Downbeat drops out of the export, and the show it
    // was blocking has to become sendable again on the next tick. A flag that only ever turns ON is a slow
    // leak of dead leads. This also covers the export-read edge: an export with no bookings must not leave a
    // stale conflict standing, and must not fabricate a new one.
    @Test func reapplyConflictsClearsAShowWhenItsBookingLeavesTheExport() throws {
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("downbeat-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, DayOff.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "k", groupName: "Vienna Philharmonic", discipline: "music",
                         venue: "Stern Auditorium", performanceDate: "2026-11-18", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        ctx.insert(p)
        try ctx.save()
        let scheduler = ReconcileScheduler(context: ctx)

        // A booking on the show's night flags it.
        try """
        {"version":2,"clients":[],"venues":[],"bookings":[
          {"id":"B1","clientId":"C1","clientDisplayName":"A Client","shootName":"Nguyen Recital",
           "startDate":"2026-11-18","endDate":"2026-11-18","venueName":"V"}
        ],"blockedDates":[]}
        """.write(to: exportURL, atomically: true, encoding: .utf8)
        scheduler.reapplyConflicts(now: Date(), from: exportURL)
        #expect(p.hasUnclearedConflict)

        // The booking is cancelled: it is gone from the next export, and the flag must lift.
        try """
        {"version":2,"clients":[],"venues":[],"bookings":[],"blockedDates":[]}
        """.write(to: exportURL, atomically: true, encoding: .utf8)
        scheduler.reapplyConflicts(now: Date(), from: exportURL)

        #expect(p.hasUnclearedConflict == false)
        #expect(p.conflictNote == nil)
    }

    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "sched-\(UUID().uuidString)")! }
}
