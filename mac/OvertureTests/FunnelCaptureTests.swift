import Testing
import Foundation
import SwiftData

// #16/#6/#4 plumbing: the three facts about a show's journey that nothing recorded, and that no later
// build could recover, because the scout overwrites its own inputs on every run.
//
//   firstSeenAt   when a show first entered the store. `ingestedAt` looked like this and is not: the
//                 scout rewrites it every run (ScoutService.apply), including on shows already pitched,
//                 so a show found in November reads as found last week.
//   dismissedAt   when a show left the queue. The eight dismiss reasons are the whole drop-off side of
//                 the funnel and none of them carried a date, so a cut could be counted but never dated.
//   ...AtSend     the ranking features as they stood the moment Dan pitched, frozen like
//                 priorRelationshipAtSend already was, because the scout refreshes score, tier, profile,
//                 coverage, discipline and production forever after the email went out.
//
// Every assertion here is behavioral: each one drives the real path (a second scout run, a real dismissal,
// a real send) rather than reading the source, because the defect is that the wiring is missing.
@MainActor
@Suite("Funnel capture: first seen, dismissed, features at send")
struct FunnelCaptureTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self, ExcludedTown.self,
                                        AllowedSeedTown.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let liveEvents = [
        ExtractedEvent(title: "Indianapolis Children's Choir", presenter: "Indianapolis Children's Choir",
                       venue: "Stern Auditorium / Perelman Stage",
                       performanceDate: "2026-06-24", sourceUrl: "https://example.com/b"),
    ]

    private var choirKey: String {
        Prospect.makeNaturalKey(groupName: "Indianapolis Children's Choir",
                                performanceDate: "2026-06-24",
                                venue: "Stern Auditorium / Perelman Stage")
    }

    private func stored(_ ctx: ModelContext, key: String) throws -> Prospect {
        let k = key
        return try #require(try ctx.fetch(
            FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == k })).first)
    }

    @discardableResult
    private func show(_ ctx: ModelContext, key: String = "k1", status: ReviewStatus = .queued,
                      date: String = "2026-11-18", location: String? = nil,
                      group: String = "Vienna Philharmonic",
                      ingested: Date = Date(timeIntervalSince1970: 1_000)) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Stern Auditorium",
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status, ingestedAt: ingested)
        p.location = location
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // MARK: - firstSeenAt

    // The defect itself. A second scout run over the same calendar moves ingestedAt (that is its job:
    // it means "last read"), and must leave the first sighting untouched. Without this the Sankey's
    // opening node, "shows sourced this year", cannot be counted at all.
    @Test func aReScoutMovesIngestedAtAndLeavesFirstSeenAlone() throws {
        let ctx = ModelContext(try container())
        _ = ScoutService.apply(events: liveEvents, clients: [], history: [], blocked: .empty,
                               today: ScoutTestClock.beforeAllFixtures, into: ctx)
        let first = try stored(ctx, key: choirKey)
        let firstSeen = try #require(first.firstSeenAt)
        let firstIngest = first.ingestedAt

        _ = ScoutService.apply(events: liveEvents, clients: [], history: [], blocked: .empty,
                               today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let again = try stored(ctx, key: choirKey)
        #expect(again.firstSeenAt == firstSeen)      // the first sighting is a fact; it never moves
        #expect(again.ingestedAt > firstIngest)      // "last read" still tracks the latest run
    }

    // A show the scout has just inserted was first seen exactly when it was ingested.
    @Test func aNewlyScoutedShowRecordsItsFirstSighting() throws {
        let ctx = ModelContext(try container())
        _ = ScoutService.apply(events: liveEvents, clients: [], history: [], blocked: .empty,
                               today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let p = try stored(ctx, key: choirKey)
        #expect(p.firstSeenAt == p.ingestedAt)
    }

    // Dan's decision (2026-07-23): stamp the rows already in the store from their current ingestedAt
    // rather than leave them blank. For a show re-scouted since it was found that date is later than the
    // truth, so it is an upper bound, never an invention of a date nothing observed.
    @Test func theBackfillStampsExistingRowsFromIngestedAt() throws {
        let ctx = ModelContext(try container())
        let old = show(ctx, key: "old", ingested: Date(timeIntervalSince1970: 5_000))
        old.firstSeenAt = nil   // as every row predating this field looks
        try ctx.save()

        let changed = FirstSeenBackfill.run(in: ctx)

        #expect(changed == 1)
        #expect(old.firstSeenAt == Date(timeIntervalSince1970: 5_000))
    }

    // It runs on every launch, so a second pass must not re-stamp a row whose ingestedAt has since
    // moved on: that would walk the first sighting forward one launch at a time.
    @Test func theBackfillIsIdempotentAndNeverWalksTheDateForward() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, key: "old", ingested: Date(timeIntervalSince1970: 5_000))
        p.firstSeenAt = nil
        try ctx.save()
        _ = FirstSeenBackfill.run(in: ctx)

        p.ingestedAt = Date(timeIntervalSince1970: 9_000)   // a later scout read it again
        try ctx.save()

        #expect(FirstSeenBackfill.run(in: ctx) == 0)
        #expect(p.firstSeenAt == Date(timeIntervalSince1970: 5_000))
    }

    // MARK: - dismissedAt

    // Dan's own cut, through the one mutation every reason goes through.
    @Test func dismissingAShowRecordsWhenItLeftTheQueue() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)

        ProspectMutations.setStatus(QueueItem(p), .dismissed, .notAFit,
                                    prospects: [p], context: ctx, feedback: ActionFeedback())

        #expect(p.showOutcome == .notAFit)
        #expect(p.dismissedAt != nil)
    }

    // Changing his mind about WHY keeps when. The show left the queue once; a re-labelled reason is not
    // a second exit, and re-stamping would date the drop-off to whenever he last tidied it up.
    @Test func relabellingTheReasonKeepsTheOriginalExitDate() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        ProspectMutations.setStatus(QueueItem(p), .dismissed, .dateConflict,
                                    prospects: [p], context: ctx, feedback: ActionFeedback())
        let exited = try #require(p.dismissedAt)

        ProspectMutations.setStatus(QueueItem(p), .dismissed, .notAFit,
                                    prospects: [p], context: ctx, feedback: ActionFeedback())

        #expect(p.dismissedAt == exited)
    }

    // Restoring from Archive (#28) puts the show back in the queue, so it has no exit date any more.
    // Leaving one behind would count a live show as a drop-off.
    @Test func restoringFromArchiveClearsTheExitDate() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        ProspectMutations.setStatus(QueueItem(p), .dismissed, .notAFit,
                                    prospects: [p], context: ctx, feedback: ActionFeedback())

        DismissedProspects.restore(p)

        #expect(p.status == .new)
        #expect(p.dismissedAt == nil)
    }

    // Overture's own automatic cut: the last night passed while the show sat untriaged (#864). Dated
    // like any other exit, because "went by" is a real and separate arm of the funnel.
    @Test func aShowThatWentByRecordsWhenItWasRetired() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .new, date: "2026-01-05")

        _ = WentByRetirement.run(in: ctx, today: "2026-03-01")

        #expect(p.showOutcome == .wentBy)
        #expect(p.dismissedAt != nil)
    }

    // The other automatic cut: a town Dan blocked (#1238). Its Undo restores the show, so it must also
    // clear the date, exactly as Archive's restore does.
    @Test func aBlockedTownRetirementIsDatedAndItsUndoClearsIt() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .new, location: "Chautauqua, NY", group: "Chautauqua Opera")
        _ = ExcludedTownEditing.exclude(town: "Chautauqua", into: ctx)

        _ = ExcludedTownRetirement.run(in: ctx)
        #expect(p.showOutcome == .tooFar)
        #expect(p.dismissedAt != nil)

        ExcludedTownRetirement.restore(town: "chautauqua", in: ctx)
        #expect(p.status == .new)
        #expect(p.dismissedAt == nil)
    }

    // An org that asked Dan to stop emailing (#769). Its untouched shows are cut, and that is an exit.
    @Test func aDoNotContactCutIsDated() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, status: .new)

        OrgDoNotContact.mark(orgOf: p, in: [p])

        #expect(p.status == .dismissed)
        #expect(p.dismissedAt != nil)
    }

    // MARK: - features at send

    private func approved(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Aurora", performanceDate: "2026-07-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: "Aurora", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        p.draftSubject = "S"; p.draftBody = "Hello,\n\nBody."
        ctx.insert(p)
        if let id = Recipient.makeId(email: "to@org.org", formURL: nil) {
            p.setRecipients([Recipient(id: id, email: "to@org.org", name: nil, role: nil, provenance: .act)])
        }
        try? ctx.save()
        return p
    }

    // #4 wants to learn which features predicted a booking. Reading them off the row later reads whatever
    // the newest scout wrote, so the pitch is scored against a profile Dan never actually sent against.
    @Test func sendingFreezesTheRankingFeaturesAsTheyStood() async throws {
        let ctx = ModelContext(try container())
        let p = approved(ctx)

        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: FreezeTestSender())

        #expect(p.fitScoreAtSend == 7)
        #expect(p.tierAtSend == "high")
        #expect(p.profileAtSend == "strong")
        #expect(p.coverageAtSend == "likely_uncovered")
        #expect(p.disciplineAtSend == "choral")
        #expect(p.productionAtSend == "self")
    }

    // The whole point: a later scout re-scores the show, and the frozen snapshot does not move with it.
    @Test func aLaterRescoreLeavesTheFrozenSnapshotAlone() async throws {
        let ctx = ModelContext(try container())
        let p = approved(ctx)
        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: FreezeTestSender())

        p.fitScore = 2                  // as ScoutService.apply rewrites it on any later run
        p.tier = "longshot"
        p.profile = "weak"

        #expect(p.fitScoreAtSend == 7)
        #expect(p.tierAtSend == "high")
        #expect(p.profileAtSend == "strong")
    }

    // A show with two contacts sends twice. The snapshot belongs to the first pitch, like sentAt and
    // priorRelationshipAtSend beside it, so the second send must not re-stamp it from a drifted row.
    @Test func aSecondRecipientDoesNotRestampTheSnapshot() async throws {
        let ctx = ModelContext(try container())
        let p = approved(ctx)
        if let a = Recipient.makeId(email: "one@org.org", formURL: nil),
           let b = Recipient.makeId(email: "two@org.org", formURL: nil) {
            p.setRecipients([Recipient(id: a, email: "one@org.org", name: nil, role: nil, provenance: .act),
                             Recipient(id: b, email: "two@org.org", name: nil, role: nil, provenance: .act)])
        }
        try ctx.save()

        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 10), sender: FreezeTestSender())
        p.fitScore = 2   // a scout lands between the two sends
        p.tier = "longshot"
        _ = await SendService.sendOne(p, now: Date(timeIntervalSince1970: 20), sender: FreezeTestSender())

        #expect(p.fitScoreAtSend == 7)
        #expect(p.tierAtSend == "high")
    }

    // The freeze is write-once in its own right, not merely because the send path happens to call it
    // inside a once-only block. DebugStaging stamps a prospect as sent directly, and any future caller
    // gets the same protection, so the guard is pinned here rather than left to a caller's good manners.
    @Test func freezingTwiceKeepsTheFirstSnapshot() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)   // fitScore 9, tier "high"

        p.freezeFeaturesAtSend()
        p.fitScore = 1
        p.tier = "longshot"
        p.freezeFeaturesAtSend()

        #expect(p.fitScoreAtSend == 9)
        #expect(p.tierAtSend == "high")
    }

    // A show that was never sent has nothing to freeze, and must not pretend otherwise: an unsent row
    // carrying a snapshot would be counted as contacted by anything reading the AtSend fields.
    @Test func anUnsentShowCarriesNoSnapshot() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)

        #expect(p.fitScoreAtSend == nil)
        #expect(p.tierAtSend == nil)
    }
}

private struct FreezeTestSender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        SentReceipt(threadId: "t-freeze", messageID: "<freeze@x.org>")
    }
}
