import Testing
import Foundation
import SwiftData

// #4337, step A8 of the scout landing plan (discussion #4326, revision 5): is there a PRESENT race between
// a reconcile tick and a scout landing?
//
// Why it can happen at all. The tick reads the store ONCE (`StoreRows.fetch`, ReconcileScheduler's
// `rows`) and then hands the main actor back between every pass (#4107). It takes no landing token
// (`LandingSingleFlight`, #4330, gates landings against each other only), so a landing waiting on the main
// actor can run its whole synchronous block at any of those hand backs, and every pass after it reads a
// snapshot taken before the landing.
//
// THE NAMED WRONG WRITE, stated before running (L681): a tick pass acting on that snapshot, writing through
// a row whose `naturalKey` the landing changed with `.reKeyJoiningNights`. The plan's expected result was
// that it does NOT reproduce, because `StoreRows` holds the row OBJECTS rather than their keys, so a write
// through one reaches the re-keyed row with its post-landing values.
//
// THE POSITIVE CONTROL (L248): the tick's own hand back counter (`afterHandBack`), stamped at each hand
// back. The landing runs at hand back 1, straight after the tick's read, and the control passes only when
// the landing re-keyed the row the tick had read, at least one later hand back followed it, and the
// tick's closing read ran after it. A "no race" verdict counts only when that control passed.
//
// The landing is the real per source apply both landing paths call (`ScoutService.apply`, as
// `ProductionTokenJoinTests` drives it) followed by a save, on the live Nihao Broadway shape #4029 measured:
// two nights of one production sharing only the venue's production token. The stored row holds the LATER
// night and the arrival brings the EARLIER one, so the joined row lands on a new opening night and its key
// genuinely moves (asserted, not assumed: an unmoved key would make the whole probe vacuous).
//
// The DELETE half of the plan's question (a tick holding a pending insert that A5's revert deletes) is not
// reachable on today's main: nothing a landing does today deletes a row it inserted, and A5 (#4334) is what
// adds that. It is added here once A5 lands.
private let venue = "The Green Room 42"
private let token = "zGbL9oImamvWwHF3ti5i"
private let host = "https://thegreenroom42.venuetix.com/showdetails/"
private let storedTitle = "Nihao Broadway"
private let storedNight = "2026-09-29"
private let storedURL = host + token + "/zJ35Qa2LPGbqLyShab5f"
private let arrivingTitle = "Nihao Broadway!"
private let arrivingNight = "2026-09-11"
private let arrivingURL = host + token + "/5oHZXAxwUToPOZdBXMNY"
private let landingDay = "2026-08-19"
private let tickNow = Date(timeIntervalSince1970: 1_787_000_000)

// What the landing owns on the row, read as values so a stale write back is visible as a difference.
private struct LandedFields: Equatable {
    let naturalKey: String
    let groupName: String
    let performanceDate: String?
    let runEndDate: String?
    let runNights: [String]
    let runSourceURLs: [String]
    let status: String
    let outcome: String

    init(_ p: Prospect) {
        naturalKey = p.naturalKey
        groupName = p.groupName
        performanceDate = p.performanceDate
        runEndDate = p.runEndDate
        runNights = p.runNights.sorted()
        runSourceURLs = p.runSourceURLs.sorted()
        status = p.statusRaw
        outcome = p.outcomeRaw
    }
}

// The control's record of when things happened, in the order they happened.
private enum Event: Equatable {
    case handBack(Int)
    case landed(keyBefore: String, keyAfter: String, savedCleanly: Bool)
    case closingRead
}

@MainActor
@Suite("A reconcile tick racing a scout landing (#4337, A8)")
struct ReconcileTickLandingRaceTests {

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory([Prospect.self, Recipient.self, Inquiry.self, DayOff.self])
    }

    @discardableResult
    private func storedRow(in ctx: ModelContext, booked: Bool) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: storedTitle, performanceDate: storedNight, venue: venue)
        let p = Prospect(naturalKey: key, groupName: storedTitle, discipline: "music",
                         venue: venue, performanceDate: storedNight,
                         sourceListingURL: storedURL, priorRelationship: "none",
                         production: "unknown", profile: "unknown", coverage: "unknown",
                         fitScore: 3, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: nil, partOfRelatedRun: false, runSourceURLs: [storedURL],
                         runNights: [storedNight])
        if booked { p.outcome = .booked }
        ctx.insert(p)
        return p
    }

    // The landing: the real per source apply, then the save that carries it.
    private func land(into ctx: ModelContext) -> Bool {
        _ = ScoutService.apply(
            events: [ExtractedEvent(title: arrivingTitle, presenter: venue, venue: venue,
                                    performanceDate: arrivingNight, sourceUrl: arrivingURL)],
            clients: [], history: [], blocked: .empty, today: landingDay,
            sourceIds: ["thegreenroom42-venuetix-com"], into: ctx)
        do { try ctx.save(); return true } catch { return false }
    }

    private struct Run {
        let summary: ReconcileSummary
        let events: [Event]
        let landedFields: LandedFields?
    }

    // One tick with a landing at hand back `landAt`. Only Gmail is stubbed out (the two injected Gmail
    // passes do nothing); every other pass is the tick's own, and the closing read is the real one.
    private func tick(_ ctx: ModelContext, row: Prospect, landAt: Int, label: String) async -> Run {
        var events: [Event] = []
        var landedFields: LandedFields?
        let summary = await ReconcileScheduler(context: ctx, replyRunAlive: { _ in false }).runSafeReconcilesOnce(
            now: tickNow, defaults: ScratchDefaults.make("4337-\(label)"),
            repairThreading: { _, _ in nil },
            sweepProposals: { _, _, _ in .notConnected },
            readClosing: { context, at, alive in
                events.append(.closingRead)
                return await DueReading.read(from: context, now: at, replyRunAlive: alive)
            },
            recordTimeline: { _ in },
            afterHandBack: { n in
                events.append(.handBack(n))
                guard n == landAt else { return }
                let before = row.naturalKey
                let saved = land(into: ctx)
                events.append(.landed(keyBefore: before, keyAfter: row.naturalKey, savedCleanly: saved))
                landedFields = LandedFields(row)
            })
        return Run(summary: summary, events: events, landedFields: landedFields)
    }

    // L248: the race was actually staged, or no verdict below means anything.
    private func controlPassed(_ run: Run, storedKey: String) -> Bool {
        guard let at = run.events.firstIndex(where: { if case .landed = $0 { return true }; return false }),
              case .landed(let keyBefore, let keyAfter, let saved) = run.events[at] else { return false }
        let laterHandBacks = run.events[(at + 1)...].contains { if case .handBack = $0 { return true }; return false }
        let closingAfter = run.events[(at + 1)...].contains(.closingRead)
        return keyBefore == storedKey && keyAfter != storedKey && saved && laterHandBacks && closingAfter
    }

    // MARK: the positive control, on its own

    @Test func theLandingRunsInsideTheTickAfterItsReadAndBeforeItsLaterPasses() async throws {
        let ctx = ModelContext(try container())
        let row = storedRow(in: ctx, booked: false)
        try ctx.save()
        let storedKey = row.naturalKey

        let run = await tick(ctx, row: row, landAt: 1, label: "control")

        #expect(run.events.first == .handBack(1), "the first hand back is not the first thing the tick reported")
        #expect(controlPassed(run, storedKey: storedKey),
                "the landing did not re-key the row the tick had read, between its read and a later pass")
    }

    // MARK: the named wrong write

    // Measured: does NOT reproduce. Every pass after the landing holds the same row object, so whatever it
    // writes lands on the re-keyed row, and nothing it does writes the snapshot's key or nights back.
    @Test func noPassWritesTheSnapshotsKeyOrNightsBackThroughTheReKeyedRow() async throws {
        let container = try container()
        let ctx = ModelContext(container)
        let row = storedRow(in: ctx, booked: false)
        try ctx.save()
        let storedKey = row.naturalKey

        let run = await tick(ctx, row: row, landAt: 1, label: "write")
        try ctx.save()

        #expect(controlPassed(run, storedKey: storedKey), "the race was not staged, so this verdict is void")
        let fresh = try ModelContext(container).fetch(FetchDescriptor<Prospect>())
        #expect(fresh.count == 1, "the tick and the landing left \(fresh.count) rows for one production")
        #expect(!fresh.contains { $0.naturalKey == storedKey },
                "a row still carries the key the tick read before the landing re-keyed it")
        #expect(fresh.first.map(LandedFields.init) == run.landedFields,
                "the tick changed what the landing wrote to the re-keyed row")
    }

    // MARK: what the tick REPORTS from its snapshot

    // Measured: REPRODUCES. The tick keeps the snapshot's booked and replied shows by KEY (`bookedBefore`,
    // `repliedBefore`) to tell what is new this tick, and its closing read is a fresh one. A show that was
    // already booked, re-keyed by a landing in between, is not in the "before" set under its new key, so the
    // away alert names it as a new booking. No store write is wrong; the notification is.
    //
    // Recorded as a known issue rather than asserted green, so this goes red by itself the day the follow
    // up (#4417) fixes it, and the known issue is deleted then rather than left defending the defect (L252).
    @Test func aBookedShowReKeyedMidTickIsNotReportedAsANewBooking() async throws {
        let ctx = ModelContext(try container())
        let row = storedRow(in: ctx, booked: true)
        try ctx.save()
        let storedKey = row.naturalKey

        let run = await tick(ctx, row: row, landAt: 1, label: "alert")

        #expect(controlPassed(run, storedKey: storedKey), "the race was not staged, so this verdict is void")
        withKnownIssue("#4417: a re-key between the tick's read and its closing read reads as a new booking") {
            #expect(run.summary.newBookings.isEmpty,
                    "an already booked show was named a new booking: \(run.summary.newBookings)")
        }
    }

    // L159: the same show, the same landing, but landed BEFORE the tick reads. Nothing is new, so the alert
    // must be silent: this is what separates the race above from a fixture that always alerts.
    @Test func theSameLandingBeforeTheTickIsNotReportedAsANewBooking() async throws {
        let ctx = ModelContext(try container())
        let row = storedRow(in: ctx, booked: true)
        try ctx.save()
        #expect(land(into: ctx))
        #expect(row.outcome == .booked, "the landing itself changed the booking, so the fixture is wrong")

        let run = await tick(ctx, row: row, landAt: 0, label: "before")

        #expect(run.summary.newBookings.isEmpty,
                "a show booked before the tick began was named a new booking: \(run.summary.newBookings)")
    }
}
