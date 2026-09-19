import Testing
import Foundation
import SwiftData

// #3326, #3285, #3312: which nights a pitch may name, how, and who wins when chronology and a tick disagree.
@MainActor
@Suite("The nights a pitch may name (#3326, #3285, #3312)")
struct KeptNightsTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // The rule's threshold is read from the constant, never written as a literal at its edge (L401).
    @Test func aSpanNeedsContiguousNightsAndMoreThanTheThreshold() {
        let four = ["2026-03-10", "2026-03-11", "2026-03-12", "2026-03-13"]
        let atThreshold = Array(four.prefix(KeptNights.spanThreshold))
        #expect(KeptNights.namesAsSpan(Array(four.prefix(KeptNights.spanThreshold + 1))))
        #expect(!KeptNights.namesAsSpan(atThreshold), "three nights are named one by one")
        #expect(!KeptNights.namesAsSpan(["2026-03-10", "2026-03-11", "2026-03-13", "2026-03-14"]),
                "a gap means the span would offer a night that is not kept")
        #expect(KeptNights.isContiguous(["2026-02-28", "2026-03-01"]), "across a month end")
    }

    @Test func keptIsEveryUpcomingNightNotSkipped() {
        let playing = PlayingNights.recorded(["2026-03-10", "2026-03-17", "2026-03-24", "2026-03-31"])
        #expect(KeptNights.of(playing, skipped: ["2026-03-24"], today: "2026-03-11")
                == ["2026-03-17", "2026-03-31"])
        // Nothing judged at all: the default is pitch every night (answer 1).
        #expect(KeptNights.of(playing, skipped: [], today: "2026-03-01")?.count == 4)
    }

    @Test func singleNightsAndUnrecordedRunsKeepTheOldRule() {
        #expect(KeptNights.of(.recorded(["2026-03-10"]), skipped: [], today: "2026-03-01") == nil)
        #expect(KeptNights.of(.spanOnly(opening: "2026-03-10", lastNight: "2026-03-14"),
                              skipped: [], today: "2026-03-01") == nil)
        #expect(KeptNights.of(.undated, skipped: [], today: "2026-03-01") == nil)
        #expect(KeptNights.of(.recorded(["2026-03-10", "2026-03-17"]), skipped: [], today: "2026-04-01") == nil,
                "a run with nothing ahead has nothing to keep")
    }

    // #3312, THE AGREEMENT. Chronology wins, and `openingNightPassed` and the kept nights are the same fact:
    // walked across every day of a run's life, a passed opening is never kept, a kept night is never behind
    // us, and whenever the opening has passed the kept set is exactly what is left.
    @Test func theKeptNightsAndOpeningNightPassedNeverDisagree() {
        let nights = ["2026-03-10", "2026-03-12", "2026-03-14", "2026-03-20"]
        let playing = PlayingNights.recorded(nights)
        for day in EasternDate.days(from: "2026-03-05", through: "2026-03-25") {
            let passed = PrepQueueBuilder.openingNightPassed(performanceDate: nights.first,
                                                             runEndDate: nights.last, today: day)
            let kept = KeptNights.of(playing, skipped: [], today: day) ?? []
            #expect(kept.allSatisfy { $0 >= day }, "\(day): a kept night is already behind us")
            if passed {
                #expect(!kept.contains(nights[0]), "\(day): the passed opening is still kept")
                #expect(kept == nights.filter { $0 >= day })
            } else if day <= nights[0] {
                #expect(kept == nights, "\(day): before the run opens every night is kept")
            }
        }
    }

    // What reaches the drafter: v15's two fields, set from the one rule, absent together.
    @Test func theQueueCarriesTheKeptNightsAndHowToNameThem() throws {
        let ctx = ModelContext(try ModelContainer(for: AppSchema.schema,
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let nights = ["2026-10-06", "2026-10-13", "2026-10-20"]
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: "Kept Revue", performanceDate: nights[0],
                                                             venue: "Room"),
                         groupName: "Kept Revue", discipline: "theater", venue: "Room",
                         performanceDate: nights[0], sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "medium", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        p.runNights = nights
        p.runEndDate = nights.last
        ctx.insert(p)
        try p.recordNightDecisions(pitched: [NightDecision(night: nights[0], at: now, origin: .chosen),
                                             NightDecision(night: nights[2], at: now, origin: .chosen)],
                                   skipped: [NightDecision(night: nights[1], at: now, origin: .chosen)])
        try ctx.save()
        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "t", today: "2026-10-01",
                                                venueHistory: VenueShootHistory(shoots: [], bookings: [], today: "2026-10-01"))
        let item = try #require(queue.items.first { $0.naturalKey == p.naturalKey })
        #expect(item.keptNights == ["2026-10-06", "2026-10-20"])
        #expect(item.keptNightsAsSpan == false)
        #expect(queue.version == 15)
    }

    // MARK: the send block (plan 2.8)

    @Test func aDraftNamingASkippedNightIsTheBlockingFinding() {
        let finding = EventDateInDraft.finding(subject: nil, body: "your shows on March 10 and March 17",
                                               performanceDate: "2026-03-10", runEndDate: "2026-03-24",
                                               today: "2026-03-01", kept: ["2026-03-10", "2026-03-24"],
                                               skipped: ["2026-03-17"])
        #expect(finding == .namesASkippedNight(named: "March 17", night: "2026-03-17"))
        #expect(finding?.blocksTheSend == true)
        // Every other finding is advisory, as it always was.
        #expect(EventDateFinding.namesNoDate(show: "x").blocksTheSend == false)
        #expect(EventDateFinding.namesADifferentDate(named: "a", show: "b").blocksTheSend == false)
        #expect(EventDateFinding.omitsAKeptNight(show: "x").blocksTheSend == false)
    }
}
