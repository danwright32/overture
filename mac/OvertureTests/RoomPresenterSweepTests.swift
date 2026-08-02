import Testing
import Foundation
import SwiftData
@testable import Overture

// #1845: a room standing in as its own show's presenter, on rows ALREADY in the store.
//
// The boundary guard that strips one (ExtractedEventGuard.presenterThatIsNotTheRoom, #1766/#1788) runs
// when a show is read fresh, so it never reached a row written before it. That field decides two things
// a photographer cares about: the producer axes, because a name in it reads as a self-producing
// organisation worth 8 points, and the paid contact hunt, which is aimed at it and so goes looking for a
// building's own inbox.
//
// LIVE-STORE-CLAIM verified=2026-08-02 measure="stored rows whose presenter reduces to their own venue under ProducerGate.key, and what they score"
// Measured on the live Release store (723 rows) after #1663/#1948/#1950 shipped: 101 rows carry a
// presenter the shipped guard would strip today, among them Chain Theatre scoring 28, The Joyce Theater
// 9 and The Players Theatre 8, each read as a strong self-producing organisation. That is also where
// #1845's headline 8 point gap comes from: of the 6 same-night same-title groups left after #1761, the 3
// that disagree about the score all disagree because one copy carries the room as its presenter and the
// other carries none. Each row is scored correctly from what it holds, so the ranker is not at fault and
// the LOWER score is the honest one.
//
// The genre follows too, and that is not incidental: the classifier reads "title + presenter" for the
// genre word, so "Jalopy Theatre" in the presenter field is why a folk music venue's rows are stored as
// theater.
@MainActor
@Suite("A room standing in as the presenter, on rows already stored (#1845)")
struct RoomPresenterSweepTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func insert(_ ctx: ModelContext, title: String, presenter: String?, venue: String?,
                        discipline: String = "theater", production: String = "self",
                        profile: String = "strong", coverage: String = "likely_uncovered",
                        fitScore: Int = 10,
                        configure: (Prospect) -> Void = { _ in }) -> Prospect {
        let p = Prospect(naturalKey: "\(title)|2026-09-01|\(venue ?? "")", groupName: title,
                         discipline: discipline, venue: venue, performanceDate: "2026-09-01",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: production, profile: profile, coverage: coverage,
                         fitScore: fitScore, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        p.presenter = presenter
        configure(p)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // The live shape, and the whole point: the room is not a producer, so the row stops being read as one.
    @Test func aRoomStandingInAsThePresenterIsClearedAndTheShowScoredHonestly() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Chain Theatre Fall One Act Festival",
                         presenter: "Chain Theatre", venue: "Chain Theatre")
        let before = row.fitScore

        RoomPresenterSweep.run(in: ctx)
        try? ctx.save()

        #expect(row.presenter == nil, "the room's name leaves the field the paid contact hunt aims at")
        #expect(row.presenterWasTheRoom == true, "and says so, because a drained name and a page that named nobody are opposite facts")
        #expect(row.production != "self", "nothing on this row says anyone self-produces it")
        #expect(row.fitScore < before, "so it stops outranking shows that really are self-produced")
    }

    // The same room, spelled with its street address on the venue side, which is how most of the live
    // rows carry it. Compared through ProducerGate.key, the fold the app already uses for this question.
    @Test func theRoomIsRecognisedThroughItsStreetAddress() throws {
        let ctx = try context()
        let row = insert(ctx, title: "An Evening Of Short Plays", presenter: "The Players Theatre",
                         venue: "The Players Theatre, 115 MacDougal Street, New York, NY")

        RoomPresenterSweep.run(in: ctx)
        try? ctx.save()

        #expect(row.presenter == nil)
    }

    // The line this must not cross. A real company presenting at a room it does not own keeps its name,
    // or the sweep would delete the only thing Dan can pitch to.
    @Test func aRealCompanyPresentingAtAVenueKeepsItsName() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Shadow Puppetry", presenter: "Chinese Theatre Works",
                         venue: "Museum of Chinese in America")
        let before = row.fitScore

        RoomPresenterSweep.run(in: ctx)
        try? ctx.save()

        #expect(row.presenter == "Chinese Theatre Works")
        #expect(row.presenterWasTheRoom != true)
        #expect(row.fitScore == before, "an untouched row is not silently re-scored")
    }

    // A genre Dan corrected himself is his, and a sweep over the producer axes is not a licence to
    // re-read it. #1533's rule, kept here.
    @Test func aGenreDanCorrectedSurvivesTheSweep() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Roots n' Ruckus", presenter: "Jalopy Theatre",
                         venue: "Jalopy Theatre", discipline: "music") {
            $0.classificationOverriddenByDan = true
        }

        RoomPresenterSweep.run(in: ctx)
        try? ctx.save()

        #expect(row.presenter == nil, "the room still goes")
        #expect(row.discipline == "music", "but his genre stands")
    }

    // Where the genre is NOT his, the room's name stops deciding it. The classifier reads the presenter
    // for its genre word, which is how a folk venue's shows are stored as theater.
    @Test func theRoomsNameStopsDecidingTheGenre() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Roots n' Ruckus: a night of old time music",
                         presenter: "Jalopy Theatre", venue: "Jalopy Theatre", discipline: "theater")

        RoomPresenterSweep.run(in: ctx)
        try? ctx.save()

        #expect(row.discipline == "music")
    }

    // Runs on every launch, so it has to be a no-op the second time rather than walking a row down.
    @Test func asecondRunChangesNothing() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Chain Theatre Fall One Act Festival",
                         presenter: "Chain Theatre", venue: "Chain Theatre")

        let first = RoomPresenterSweep.run(in: ctx)
        try? ctx.save()
        let scoreAfterFirst = row.fitScore
        let second = RoomPresenterSweep.run(in: ctx)
        try? ctx.save()

        #expect(first.cleared == 1)
        #expect(second.cleared == 0)
        #expect(row.fitScore == scoreAfterFirst)
    }

    // Built is not wired (LESSONS L3). The sweep only reaches Dan's queue if the launch actually calls it.
    @Test func theSweepRunsAtLaunch() throws {
        let ctx = try context()
        let row = insert(ctx, title: "Chain Theatre Fall One Act Festival",
                         presenter: "Chain Theatre", venue: "Chain Theatre")

        LaunchMigrations.run(in: ctx, possibleMatchInputs: { _ in nil })

        #expect(row.presenter == nil)
    }
}
