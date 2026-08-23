import Testing
import Foundation
import SwiftData

// #2790: five rows in the live store hold a location the CURRENT rules would not write, and nothing
// reaches them.
//
// #2568 and #2566 both changed what `EventLocationFill` will write, and both are forward only.
// `LocationBackfill` fills a BLANK location and never rewrites one, which is deliberate and right on its
// own terms (a page's own words and anything Dan corrected must survive every launch), so a row holding
// a WRONG location is exactly the row it skips. `ScoutService`'s upsert does rewrite on re-emit, but a
// source whose page bytes are unchanged is skipped entirely, so a listing that has stopped changing, or
// a show already past, is never re-read.
//
// TWO OF THE FIVE ARE HIDDEN SHOWS, which is the failure this whole area exists to prevent: a location
// read out of a venue's own name put one in Georgia, and a park description read as Indiana put another
// out of range, so both are off Dan's queue right now for a reason that is not true.
//
// THIS IS THE MEASUREMENT, run against a COPY of the live store and writing nothing. The repair beside
// it is justified by what this reports, and it reports the count on every run so the question can be
// asked again rather than answered once in a closed issue.
@MainActor
@Suite("Stored locations the current rules would refuse (#2790)")
struct LocationsTheRulesWouldRefuseTests {
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }
    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    // The same shape `ReplyInvariantsLiveStoreTests` uses, and through the same shared clone: copying the
    // store and its sidecars by hand races a live writer, and a clone whose -wal does not match the
    // .store beside it makes whatever this concludes a statement about a torn copy rather than about
    // Dan's data (#1672). `LiveStoreClone` takes it through SQLite's online backup.
    private func withLiveShows(_ body: ([Prospect]) throws -> Void) async throws {
        guard Self.liveStoreExists else { return }
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("location-repair-\(UUID().uuidString)",
                                                                   isDirectory: true)
            defer { try? fm.removeItem(at: dir) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                await RealStoreTestLock.shared.release()
                return
            }
            let schema = Schema([Prospect.self, Recipient.self])
            let context = ModelContext(try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: clone, cloudKitDatabase: .none)]))
            let shows = try context.fetch(FetchDescriptor<Prospect>())
            // A store that reads as empty is a failed open, not a clean bill of health (L98).
            #expect(!shows.isEmpty, "the copied store holds no shows, so nothing below measured anything")
            try body(shows)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // The count, printed every run. A rule that examined zero rows and one that examined every row must
    // not look alike, so the POPULATION is on the line beside the finding (L98).
    @Test func thestoreReportsHowManyLocationsTheRulesWouldNoLongerWrite() async throws {
        try await withLiveShows { shows in
            let placed = shows.filter { !($0.location ?? "").isEmpty }
            let refused = placed.filter { LocationRepair.wouldNotBeWrittenToday($0) }
            print("LIVE STORE LOCATIONS: \(shows.count) shows, \(placed.count) with a location, "
                  + "\(refused.count) holding one the current rules would not write. "
                  + "A zero population means this measured nothing.")
            // Every refused row is one this pass would touch, and the repair must never touch more than
            // it can justify, so the two counts are asserted against each other rather than separately.
            #expect(refused.count <= placed.count)
        }
    }

    // MARK: - The rule, on shapes rather than on the live store

    // The narrow rule that makes a repair safe: a stored location is a candidate ONLY when the shipping
    // predicate now refuses it. A location the rules still accept, however odd it looks, is left alone,
    // because re-deriving those is a second opinion nobody asked for.
    @Test func alocationTheRulesStillAcceptIsNotACandidate() {
        #expect(!LocationRepair.wouldNotBeWritten(location: "New York, NY"))
        #expect(!LocationRepair.wouldNotBeWritten(location: "Brooklyn, NY"))
    }

    // The two live shapes the issue names. A room description carrying a street clause and no readable
    // city is exactly what #2566 stopped writing, and it is what the gate read as Indiana.
    @Test func aroomDescriptionWithNoReadableCityIsACandidate() {
        #expect(LocationRepair.wouldNotBeWritten(
            location: "The Soldiers' and Sailors' Monument, on the North Patio, behind the monument. W. 89th St. & Riverside Drive, in Riverside Park"))
        #expect(LocationRepair.wouldNotBeWritten(
            location: "The Sanctuary of Brick Presbyterian Church, 1144 Park Avenue"))
    }

    // A blank is not a candidate. `LocationBackfill` owns those and always has, and claiming them here
    // would give one row two passes writing it (L83).
    @Test func ablankLocationIsLeftToTheBackfill() {
        #expect(!LocationRepair.wouldNotBeWritten(location: ""))
        #expect(!LocationRepair.wouldNotBeWritten(location: "   "))
    }
}

// #2790's repair, on shapes rather than on the live store, so every branch can be driven.
@MainActor
@Suite("The location repair moves only what the rules would refuse (#2790)")
struct LocationRepairTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, VenuePlaceAnswer.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, key: String, venue: String?, location: String?) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: venue,
                         performanceDate: "2026-12-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.location = location
        ctx.insert(p)
        return p
    }

    // The live shape: a room description carrying a street clause and no readable city, which the gate
    // read as a state Dan is not in, so the show is hidden right now.
    @Test func aroomDescriptionIsWithdrawn() throws {
        let ctx = try context()
        let p = show(ctx, key: "brick", venue: "Brick Presbyterian Church",
                     location: "The Sanctuary of Brick Presbyterian Church, 1144 Park Avenue")

        #expect(LocationRepair.run(in: ctx) == 1)
        #expect(p.location != "The Sanctuary of Brick Presbyterian Church, 1144 Park Avenue",
                "the row kept the location the rules would refuse (#2790)")
    }

    // A location the rules still accept is left alone, however ordinary it looks. Re-deriving those is a
    // second opinion nobody asked for.
    @Test func alocationTheRulesAcceptIsNeverTouched() throws {
        let ctx = try context()
        let p = show(ctx, key: "weill", venue: "Weill Recital Hall", location: "New York, NY")

        #expect(LocationRepair.run(in: ctx) == 0)
        #expect(p.location == "New York, NY")
    }

    // A blank belongs to `LocationBackfill` and always has. One row with two passes writing it is a field
    // with two homes (L83).
    //
    // This holds for TWO reasons today, and only one of them is this pass's own: the published-location
    // rule also accepts an empty string, so removing the explicit guard leaves this green. That is
    // recorded in `LocationRepair` beside the guard rather than left for somebody to rediscover.
    @Test func ablankIsLeftToTheBackfill() throws {
        let ctx = try context()
        let p = show(ctx, key: "blank", venue: "Weill Recital Hall", location: nil)

        #expect(LocationRepair.run(in: ctx) == 0)
        #expect(p.location == nil)
    }

    // Dan's own answer for the room outranks every rule, including this one, and is checked BEFORE the
    // refusal so the pass never overrules him on the strength of a predicate about a string he did not
    // write.
    @Test func aroomDanHasAnsweredForIsSkipped() throws {
        let ctx = try context()
        let venue = "Brick Presbyterian Church"
        let p = show(ctx, key: "answered", venue: venue,
                     location: "The Sanctuary of Brick Presbyterian Church, 1144 Park Avenue")
        if let key = VenuePlaces.canonicalKey(for: venue) {
            ctx.insert(VenuePlaceAnswer(venueKey: key, venueName: venue, location: "New York, NY",
                                       answeredAt: Date(timeIntervalSince1970: 1_780_000_000)))
        }

        #expect(LocationRepair.run(in: ctx) == 0,
                "the pass overruled an answer Dan gave for this room (#2790)")
        #expect(p.location == "The Sanctuary of Brick Presbyterian Church, 1144 Park Avenue")
    }

    // Assume it runs twice. A second launch must move nothing, or every launch rewrites the same rows.
    @Test func asecondRunMovesNothing() throws {
        let ctx = try context()
        show(ctx, key: "brick", venue: "Brick Presbyterian Church",
             location: "The Sanctuary of Brick Presbyterian Church, 1144 Park Avenue")

        #expect(LocationRepair.run(in: ctx) == 1)
        #expect(LocationRepair.run(in: ctx) == 0, "the pass moves the same row on every launch")
    }

    // Built is not wired (L3): it runs at launch, and BEFORE the backfill, so a row it clears is refilled
    // in the same launch rather than waiting for the next one.
    @Test func itrunsAtLaunchBeforeTheBackfill() {
        let source = SourceGuardHelper.source("Overture/Domain/LaunchMigrations.swift")
        #expect(!source.isEmpty)
        guard let repair = source.range(of: "LocationRepair.run(in: context)"),
              let backfill = source.range(of: "LocationBackfill.run(in: context)") else {
            Issue.record("the launch pass does not run the location repair (#2790)")
            return
        }
        #expect(repair.lowerBound < backfill.lowerBound,
                "the repair runs after the backfill, so a row it clears waits a launch to be refilled")
    }
}
