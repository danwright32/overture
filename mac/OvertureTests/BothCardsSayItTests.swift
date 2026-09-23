import Testing
import Foundation
import SwiftData

// #4146: when a pair looks like one show, only the NEWER card said so.
//
// #3330 tags a show that ARRIVES looking like one already stored, and the tag is written in
// `ScoutService`'s `.insert` arm, which only ever runs for the row being written. So on a pair the
// second row carries a sentence and the first says nothing, and the pairing is one the other
// mechanisms cannot reach either: `storedMoreThanOnceNote` (#3282) draws on `ShowLink.group`, which
// joins rows whose FOLDED TITLE already matches, and #3330's tag fires precisely where the folded
// titles DIFFER ("Orli Shaham, piano" against "Orli Shaham: In Clara's Hands" fold apart).
//
// WHY IT MATTERS. Dan meets the older card as often as the newer one, and usually higher up his order,
// because it has been there longer and has been scored. A pairing one card admits and the other denies
// by silence is worse than neither saying it.
//
// THE FIX IS A READ, NOT A SECOND STORED FIELD. The tag is already a pointer naming both halves; all
// that was missing was reading it from the other end, which the card pass can do over the corpus table
// it already builds.
@MainActor
@Suite("Both cards say it when a pair looks like one show (#4146)")
struct BothCardsSayItTests {

    private static let night = "2026-10-06"
    private static let venue = "Merkin Hall"

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func row(_ ctx: ModelContext, _ title: String, seen: TimeInterval,
                     lookingLike: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title,
                                                            performanceDate: Self.night,
                                                            venue: Self.venue),
                         groupName: title, discipline: "classical", venue: Self.venue,
                         performanceDate: Self.night, sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        p.firstSeenAt = Date(timeIntervalSince1970: seen)
        p.arrivedLookingLike = lookingLike
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func card(_ items: [QueueItem], titled title: String) throws -> QueueItem {
        try #require(items.first { $0.groupName == title })
    }

    // THE CLAIM, with the live pair: pk 598 and pk 1589, one Orli Shaham concert at Merkin Hall on
    // 2026-10-06, two billings minted eight weeks apart (`SameVenueOneNightSweepTests`, 2026-09-21).
    @Test func theOlderCardNamesTheLaterListing() throws {
        let ctx = try context()
        let older = row(ctx, "Orli Shaham, piano", seen: 1_752_000_000)
        row(ctx, "Orli Shaham: In Clara's Hands", seen: 1_757_000_000, lookingLike: older.naturalKey)

        let items = QueueModel.items(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                     now: Date(timeIntervalSince1970: 1_758_000_000))
        let olderCard = try card(items, titled: "Orli Shaham, piano")
        #expect(QueueModel.laterLookalikeNote(olderCard)
                == "A later listing looks like the same show: \"Orli Shaham: In Clara's Hands\".",
                "the older card said nothing at all, which is the whole defect")
    }

    // AND THE NEWER CARD STILL SAYS ITS OWN HALF, unchanged. The two sentences are the two ends of one
    // pointer and each may claim only its own direction (L11).
    @Test func theNewerCardKeepsItsOwnSentenceAndNotTheOtherOne() throws {
        let ctx = try context()
        let older = row(ctx, "Orli Shaham, piano", seen: 1_752_000_000)
        row(ctx, "Orli Shaham: In Clara's Hands", seen: 1_757_000_000, lookingLike: older.naturalKey)

        let items = QueueModel.items(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                     now: Date(timeIntervalSince1970: 1_758_000_000))
        let newerCard = try card(items, titled: "Orli Shaham: In Clara's Hands")
        #expect(QueueModel.arrivedLookingLikeNote(newerCard)
                == "Looks like the same show as Orli Shaham, piano, already stored for this night.")
        #expect(QueueModel.laterLookalikeNote(newerCard) == nil,
                "the newer card is nobody's older half, so it must not claim to be")
    }

    // A THIRD ARRIVAL tags the same older row again. The sentence counts them and names the NEWEST,
    // rather than listing each, which is the wall of identical text #3282 and #4030 are both about.
    @Test func aThirdArrivalIsCountedAndTheNewestIsNamed() throws {
        let ctx = try context()
        let older = row(ctx, "Orli Shaham, piano", seen: 1_752_000_000)
        row(ctx, "Orli Shaham: In Clara's Hands", seen: 1_757_000_000, lookingLike: older.naturalKey)
        row(ctx, "Orli Shaham plays Clara Schumann", seen: 1_757_900_000, lookingLike: older.naturalKey)

        let items = QueueModel.items(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                     now: Date(timeIntervalSince1970: 1_758_000_000))
        let olderCard = try card(items, titled: "Orli Shaham, piano")
        #expect(QueueModel.laterLookalikeNote(olderCard)
                == "2 later listings look like the same show, the newest \"Orli Shaham plays Clara Schumann\".")
    }

    // A ROW NOBODY POINTED AT says nothing, which is almost every row in the store.
    @Test func aCardNothingArrivedLookingLikeSaysNothing() throws {
        let ctx = try context()
        row(ctx, "Danish String Quartet", seen: 1_752_000_000)

        let items = QueueModel.items(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                     now: Date(timeIntervalSince1970: 1_758_000_000))
        #expect(QueueModel.laterLookalikeNote(try card(items, titled: "Danish String Quartet")) == nil)
    }

    // RESOLVED AT READ TIME, so a pointer from a row the launch merge has since collapsed draws
    // nothing: the older card stops claiming a pair that no longer exists (L200). Asserted by building
    // the cards from a corpus the pointing row is not in, which is exactly what deleting it produces.
    @Test func aPointerFromARowThatIsGoneDrawsNothing() throws {
        let ctx = try context()
        let older = row(ctx, "Orli Shaham, piano", seen: 1_752_000_000)
        let newer = row(ctx, "Orli Shaham: In Clara's Hands", seen: 1_757_000_000,
                        lookingLike: older.naturalKey)
        ctx.delete(newer)
        try ctx.save()

        let items = QueueModel.items(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                                     now: Date(timeIntervalSince1970: 1_758_000_000))
        #expect(QueueModel.laterLookalikeNote(try card(items, titled: "Orli Shaham, piano")) == nil)
    }

    // The empty title case, for the same reason its mirror has one: a sentence naming nothing is worse
    // than no sentence.
    @Test func anEmptyTitleDrawsNothing() throws {
        let ctx = try context()
        var item = QueueItem(row(ctx, "Orli Shaham, piano", seen: 1_752_000_000))
        item.laterLookalikeTitles = [""]
        #expect(QueueModel.laterLookalikeNote(item) == nil)
        item.laterLookalikeTitles = []
        #expect(QueueModel.laterLookalikeNote(item) == nil)
    }
}
