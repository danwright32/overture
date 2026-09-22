import Testing
import Foundation
import SwiftData

// #4030 phases 2 and 3: the group is drawn as ONE card, and an action on that card reaches the rows it
// stands for.
//
// Phase 1 (`ShowLink.collapse`) decided which row FRONTS a group and which are hidden; nothing read it.
// This is the reader: the one place rows and cards are built skips a hidden row, so the queue and the
// archive collapse identically rather than each deciding for itself (L613).
//
// WHY THE DISPLAY AND THE ACTION HAD TO LAND TOGETHER, which is phase 1's own note: collapsing the
// display alone would leave the hidden copies untriaged when Dan dismisses the card, which is worse than
// the duplicate it hides and is the complaint that started this milestone.
//
// DAN'S DECISIONS, and none of them follows from the rule:
//   - the card is fronted by a row the feed still lists, earliest opening night among those (2026-09-20);
//   - a DISMISS takes its scope from its REASON, through `RunNightDrop`'s existing classification: a
//     reason about the show closes every row, a reason about one night closes only this one (2026-09-20);
//   - a KEEP keeps every row (2026-09-22), because the card is the only one drawn and a kept duplicate
//     costs nothing while an undecided one comes back untriaged.
@MainActor
@Suite("One card for a group, acting on all of it (#4030)")
struct ACollapsedCardActsOnItsGroupTests {

    private static let venue = "Asylum NYC"
    private static let title = "The New York Neo-Futurists: The Infinite Wrench"

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // Each row is a weekly run whose nights OVERLAP its neighbours', which is what `ShowLink` joins on
    // and the live shape of the archive's twelve row group. A fixture giving each row one distinct night
    // groups nothing at all and would test nothing (L159).
    @discardableResult
    private func row(_ ctx: ModelContext, opening: String, inFeed: Bool = true,
                     title: String = title) -> Prospect {
        let nights = [opening, "2026-10-16", "2026-10-23"]
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title,
                                                            performanceDate: opening,
                                                            venue: Self.venue),
                         groupName: title, discipline: "theater", venue: Self.venue,
                         performanceDate: opening, sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        p.runNights = nights
        p.runEndDate = nights.max()
        p.partOfRelatedRun = true
        p.missedScoutCount = inFeed ? 0 : 20
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func cards(_ ctx: ModelContext) throws -> [QueueItem] {
        QueueModel.items(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                         now: Date(timeIntervalSince1970: 1_758_000_000))
    }

    // THE CLAIM. Three stored rows of one show are ONE card, and it carries every member.
    @Test func agroupIsDrawnAsOneCardThatNamesItsMembers() throws {
        let ctx = try context()
        let first = row(ctx, opening: "2026-10-02")
        let second = row(ctx, opening: "2026-10-09")
        let third = row(ctx, opening: "2026-10-16")

        let built = try cards(ctx)
        #expect(built.count == 1, "the group drew \(built.count) cards: \(built.map(\.id))")
        let card = try #require(built.first)
        #expect(card.id == first.naturalKey, "the earliest listed night fronts the card")
        #expect(Set(card.collapsedMemberKeys)
                == Set([first.naturalKey, second.naturalKey, third.naturalKey]),
                "the card must name every row it stands for, or an action cannot reach them")
    }

    // AND THE COUNT SENTENCE IS STILL SAID, once, on the one card. #3282's sentence was never wrong; it
    // was said on every member, which at twelve rows is the wall of identical text this issue is about.
    @Test func theCountSentenceIsSaidOnceOnTheSurvivingCard() throws {
        let ctx = try context()
        row(ctx, opening: "2026-10-02")
        row(ctx, opening: "2026-10-09")
        row(ctx, opening: "2026-10-16")

        let card = try #require(try cards(ctx).first)
        #expect(QueueModel.storedMoreThanOnceNote(card) == "This show is stored 3 times.")
    }

    // A ROW THAT STANDS ALONE is untouched, which is almost every row in the store.
    @Test func arowThatStandsAloneIsStillItsOwnCard() throws {
        let ctx = try context()
        row(ctx, opening: "2026-10-02")
        row(ctx, opening: "2026-10-02", title: "Gross Prophets")

        let built = try cards(ctx)
        #expect(built.count == 2)
        #expect(built.allSatisfy { $0.collapsedMemberKeys.isEmpty },
                "a card standing for nobody must carry no members, or every action reaches for nothing")
    }

    // KEEP reaches every row (Dan, 2026-09-22).
    @Test func keepingTheCardKeepsEveryRowBehindIt() throws {
        let ctx = try context()
        let first = row(ctx, opening: "2026-10-02")
        let second = row(ctx, opening: "2026-10-09")
        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        let card = try #require(try cards(ctx).first)

        ProspectMutations.setStatus(card, .queued, nil, prospects: stored, context: ctx,
                                    feedback: ActionFeedback())
        #expect(first.status == .queued)
        #expect(second.status == .queued,
                "the hidden copy stayed undecided and comes back untriaged the day the grouping changes")
    }

    // A DISMISS ABOUT THE SHOW closes every row.
    @Test func adismissAboutTheShowClosesEveryRowBehindIt() throws {
        let ctx = try context()
        let first = row(ctx, opening: "2026-10-02")
        let second = row(ctx, opening: "2026-10-09")
        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        let card = try #require(try cards(ctx).first)

        #expect(ProspectMutations.recordOutcome(card, .notAFit, prospects: stored, context: ctx,
                                                feedback: ActionFeedback()))
        #expect(first.status == .dismissed)
        #expect(second.status == .dismissed)
        #expect(second.showOutcome == .notAFit)
    }

    // A DISMISS ABOUT ONE NIGHT closes only the row it was taken on. "I am shooting something else that
    // night" says nothing about the other copies, and closing them would record a judgement Dan never
    // made (L11).
    @Test func adismissAboutOneNightClosesOnlyThisRow() throws {
        let ctx = try context()
        let first = row(ctx, opening: "2026-10-02")
        let second = row(ctx, opening: "2026-10-09")
        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        let card = try #require(try cards(ctx).first)

        #expect(ProspectMutations.recordOutcome(card, .pitchingOtherShows, prospects: stored,
                                                context: ctx, feedback: ActionFeedback()))
        #expect(first.status == .dismissed)
        #expect(second.status != .dismissed,
                "a reason about one night closed a row it never judged")
    }

    // THE PRECONDITION for the two above, so a green cannot come from a classification that has moved
    // under them (L159).
    @Test func theTwoReasonsAreClassifiedTheWayTheseTestsAssume() {
        #expect(!RunNightDrop.isAboutOneNight(.notAFit))
        #expect(RunNightDrop.isAboutOneNight(.pitchingOtherShows))
    }

    // THE ARCHIVE COLLAPSES THE SAME WAY, because both surfaces build their cards through one function.
    // Asserted by building over DISMISSED rows, which is what the Archive hands in.
    @Test func theArchiveCollapsesThroughTheSameBuild() throws {
        let ctx = try context()
        let first = row(ctx, opening: "2026-10-02")
        let second = row(ctx, opening: "2026-10-09")
        for p in [first, second] { p.markDismissed(reason: .notAFit) }
        try ctx.save()

        let built = try cards(ctx)
        #expect(built.count == 1, "the archive drew one card per stored row rather than per show")
    }
}
