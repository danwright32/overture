import Testing
import Foundation
import SwiftData

// #4106 Step C (plan v7 on discussion #4267): two whole-corpus answers the render pass already holds were
// being derived a second and third time inside the same pass, from identical inputs.
//
//   ContradictedCancellation.contradictedKeys. `QueueModel.scope` takes it over `corpus ?? prospects`,
//   which the pass hands `everyProspect`, and `FeedBreakEvent.events(among: everyProspect, ...)` took it
//   again over that same list because nobody passed it in.
//
//   ReachedOutQueue.activeWithDates. The pass takes it over `inQueue.all` at `context.now`, and
//   `AgentInputs.from` walked it twice more over the same list at the same instant: once for the pill's
//   show count and once for its due count.
//
// Measured on the 4x corpus (5,376 shows) in Phase 0b: 143.2 ms for the second contradiction sweep. The
// reached-out walks fault every show's recipients each time.
//
// COUNTED, NEVER TIMED, for the reason `StagePlacedOncePerPassTests` records: a sweep count is the quantity,
// and it cannot move with the machine's load (L63, L224). And the EQUALITY halves below are what make
// sharing safe: the pass's answer must equal the one each consumer computes for itself when handed nothing,
// with a positive control in the same fixture showing that comparison can see a wrong set (L342, L159).
@MainActor
@Suite("A pass derives its contradicted and reached-out sets once and shares them (#4106 Step C)")
struct SharedSetsOncePerPassTests {
    // Both ends of every date relationship pinned (L130): the flagged rows play after `today`, one pitch's
    // nudge has come due by `now`, the other show performs tonight with nothing owed.
    private let today = "2026-08-16"
    private var now: Date { EasternDate.date(from: "2026-08-16")!.addingTimeInterval(15 * 3_600) }

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ title: String, venue: String, day: String,
                      missed: Int = 0, status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: "\(title.lowercased())|\(day)|\(venue.lowercased())",
                         groupName: title, discipline: "music", venue: venue,
                         performanceDate: day, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.missedScoutCount = missed
        ctx.insert(p)
        return p
    }

    // A contact genuinely pitched, as `hasProvenOutreach` demands: sent, addressed, stamped with a message id.
    @discardableResult
    private func pitched(_ ctx: ModelContext, on p: Prospect, id: String, sentOn day: String) -> Recipient {
        let r = Recipient(id: id, email: id, provenance: .act)
        r.sentAt = EasternDate.date(from: day)!
        r.sendState = .sent
        r.gmailMessageId = "msg-\(id)"
        p.setRecipients(p.recipients + [r])
        ctx.insert(r)
        return r
    }

    // Invented names throughout (L155, L222). One venue carries a source-wide break of three flagged rows on
    // one count, one of which has a live twin, so the event's covered count is 1 and depends on the
    // contradicted set. Two pitched shows: one owed a nudge (due), one performing tonight (not due), so the
    // due count is 1 and depends on which rows the reached-out list holds.
    private func seed(_ ctx: ModelContext) throws -> [Prospect] {
        let hall = "Harrowgate Hall"
        show(ctx, "Lantern Parade", venue: hall, day: "2026-10-03", missed: 4)
        show(ctx, "Ninefold Quartet", venue: hall, day: "2026-10-10", missed: 4)
        show(ctx, "Copper Moth Revue", venue: hall, day: "2026-10-17", missed: 4)
        // The live twin: still listed, and its run covers the flagged row's night.
        show(ctx, "Lantern Parade", venue: hall, day: "2026-10-02").runEndDate = "2026-10-06"
        let owed = show(ctx, "Birchlight Ensemble", venue: "Saltmarsh Room", day: "2026-09-30",
                        status: .contacted)
        pitched(ctx, on: owed, id: "birchlight@example.org", sentOn: "2026-08-06")
        let tonight = show(ctx, "Quillon Trio", venue: "Saltmarsh Room", day: "2026-08-16", status: .contacted)
        pitched(ctx, on: tonight, id: "quillon@example.org", sentOn: "2026-08-15")
        return try ctx.fetch(FetchDescriptor<Prospect>())
    }

    private func inputs(_ rows: [Prospect], today: String, now: Date) -> QueueRenderPass.Inputs {
        QueueRenderPass.Inputs(allProspects: QueueRenderPass.Corpus(rows), inquiries: [], orgAnswers: [],
                               context: .at(today, now: now), focusedStage: .scout)
    }

    // The fixture must actually exercise both shared answers, or every equality below is vacuous (L159).
    @Test("the fixture holds a covered feed break and a due reached-out row")
    func theFixtureExercisesBothSets() throws {
        let all = try seed(try context())
        let events = FeedBreakEvent.events(among: all, asOf: today)
        #expect(events.count == 1)
        #expect(events.first?.coveredByAnotherCard == 1)
        let reached = ReachedOutQueue.activeWithDates(from: all, now: now)
        #expect(reached.count == 2)
        #expect(reached.filter { ReachedOutQueue.isDueNow(for: $0.recipient, of: $0.prospect, now: now) }.count == 1)
    }

    // THE TWO THAT MATTER.
    @Test("one pass sweeps the corpus for contradicted cancellations exactly once")
    func onePassSweepsForContradictionsOnce() throws {
        let all = try seed(try context())
        let work = QueueRenderPass.WorkTally.measure { _ = QueueRenderPass.make(inputs(all, today: today, now: now)) }
        #expect(work.contradictionSweeps == 1,
                Comment(rawValue: "the pass swept for contradicted cancellations \(work.contradictionSweeps) times; "
                        + "the feed break check must read the set the scope already took (#4106 Step C)"))
    }

    @Test("one pass builds the reached-out list exactly once")
    func onePassBuildsReachedOutOnce() throws {
        let all = try seed(try context())
        let work = QueueRenderPass.WorkTally.measure { _ = QueueRenderPass.make(inputs(all, today: today, now: now)) }
        #expect(work.reachedOutSweeps == 1,
                Comment(rawValue: "the pass built the reached-out list \(work.reachedOutSweeps) times; "
                        + "the pill counts must read the list the pass already built (#4106 Step C)"))
    }

    // The pass's shared answers equal what each consumer derives for itself when handed nothing.
    @Test("the pass's feed breaks and pill counts equal the unshared derivations")
    func thePassAgreesWithTheUnsharedDerivations() throws {
        let all = try seed(try context())
        try assertPassAgrees(all, today: today, now: now)
    }

    // POSITIVE CONTROLS, in the same fixture, so the equalities above are known to be able to fail (L159, L1).
    @Test("a contradicted set missing a covered key changes the feed break's sentence")
    func aWrongContradictedSetIsVisible() throws {
        let all = try seed(try context())
        let right = ContradictedCancellation.contradictedKeys(among: all)
        let covered = try #require(right.first)
        let wrong = right.subtracting([covered])
        let a = FeedBreakEvent.events(among: all, asOf: today, contradicted: right)
        let b = FeedBreakEvent.events(among: all, asOf: today, contradicted: wrong)
        #expect(a != b)
        #expect(a.map(\.sentence) != b.map(\.sentence))
    }

    @Test("a reached-out list missing the due row changes the due count")
    func aWrongReachedOutListIsVisible() throws {
        let all = try seed(try context())
        let list = ReachedOutQueue.activeWithDates(from: all, now: now)
        let wrong = list.filter { !ReachedOutQueue.isDueNow(for: $0.recipient, of: $0.prospect, now: now) }
        let ctx = StageContext.at(today, now: now)
        let a = AgentInputs.from(prospects: all, allProspects: all, context: ctx, gmailConnected: true,
                                 runInFlight: nil, replyRunAlive: false, reachedOut: list)
        let b = AgentInputs.from(prospects: all, allProspects: all, context: ctx, gmailConnected: true,
                                 runInFlight: nil, replyRunAlive: false, reachedOut: wrong)
        #expect(a.reachedOutDue == 1)
        #expect(b.reachedOutDue == 0)
    }

    // The same agreement over a copy of the live store, where the shapes are real rather than chosen.
    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func thePassAgreesOnTheLiveStore() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("step-c-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: dir) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let url = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let schema = Schema([Prospect.self, Recipient.self])
            let ctx = ModelContext(try ModelContainer(
                for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]))
            let shows = try ctx.fetch(FetchDescriptor<Prospect>())
            #expect(!shows.isEmpty, "the copied store holds no shows, so nothing below measured anything")
            let now = Date()
            try assertPassAgrees(shows, today: EasternDate.today(now), now: now)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    private func assertPassAgrees(_ all: [Prospect], today: String, now: Date) throws {
        let data = QueueRenderPass.make(inputs(all, today: today, now: now))
        let inQueue = QueueModel.queueScope(all)

        // Feed breaks: the sentence carries the covered count, which is the only thing the set decides.
        let unshared = FeedBreakEvent.events(among: all, asOf: today)
        #expect(data.feedBreaks.map(\.text) == unshared.map(\.sentence))

        // Pill counts: the two fields the reached-out list decides.
        let ownList = AgentInputs.from(prospects: inQueue, allProspects: all, context: .at(today, now: now),
                                       gmailConnected: false, runInFlight: nil, replyRunAlive: false)
        #expect(data.agentInputs.reachedOut == ownList.reachedOut)
        #expect(data.agentInputs.reachedOutDue == ownList.reachedOutDue)
    }
}
