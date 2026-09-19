import Testing
import Foundation
import SwiftData

// #3780: which live row a merge keeps, and why the answer must not depend on the order its caller
// happened to hand the members over in. That pick decides what `carryTheFeedIdentity` copies onto the
// survivor before the losers are DELETED, so an arbitrary one is an arbitrary `sourceListingURL`,
// `runSourceURLs` and `sourceIds` on the row that lives.
//
// THE FIX IS IN THE CALLER, NOT THE PICKER, and the first attempt at it got that backwards.
//
// `NaturalKeyVenueMigration.stillInTheFeed` is `members.first { $0.missedScoutCount == 0 }`, and its
// comment said "`members` is ordered oldest first by every caller". Half true, which is the worst
// kind:
//
//   `SameNightTitleVariantMerge` DOES sort, oldest `ingestedAt` first, and says at the sort that it
//   is so "the cluster representative and the fallback survivor are both stable and do not depend on
//   fetch order". #1886 then depends on the RESULT: the oldest live row is the one whose key the
//   scout will send next, so a survivor chosen any other way turns a rename into a re-key at the
//   following launch and the row stops being matchable.
//
//   `NaturalKeyVenueMigration.groupsOfOneShow` did NOT. It built `members` with
//   `anchors.flatMap { byAnchor[$0] ?? [] }` inside `for (_, anchors) in byDisplay`, and `byDisplay`
//   is a Dictionary, whose iteration order Swift randomises per process.
//
// So replacing the picker with a freshest-wins rule of its own, which is what #3780's write-up
// suggests, fixes the unordered caller by overriding the ordered one. It made
// `MergedRoomNameKeepsTheScoutsKeyTests` go red, which is #1886's guard doing its job (L252).
// `groupsOfOneShow` now sorts instead, so the invariant the comment asserted is true rather than assumed.
@MainActor
@Suite("Which live row a merge keeps, and the order it is chosen from (#3780)")
struct StillInTheFeedIsChosenTests {

    private func memoryContext() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema,
                                                                isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func row(_ ctx: ModelContext, key: String, ingested: Double, missed: Int = 0,
                     venue: String = "A Room", scoutVenue: String? = nil,
                     date: String = "2026-10-02") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "A Show", discipline: "theater",
                         venue: venue, performanceDate: date, sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "unknown",
                         coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.ingestedAt = Date(timeIntervalSince1970: ingested)
        p.missedScoutCount = missed
        p.scoutVenue = scoutVenue
        ctx.insert(p)
        return p
    }

    // MARK: the picker's contract

    @Test func aRowWithMissesIsNeverChosen() throws {
        let ctx = try memoryContext()
        let stale = row(ctx, key: "stale", ingested: 9_000, missed: 4)
        let live = row(ctx, key: "live", ingested: 1_000)
        #expect(NaturalKeyVenueMigration.stillInTheFeed([stale, live])?.naturalKey == "live")
    }

    @Test func nothingIsChosenWhenNoMemberIsLive() throws {
        let ctx = try memoryContext()
        let a = row(ctx, key: "a", ingested: 1_000, missed: 2)
        let b = row(ctx, key: "b", ingested: 2_000, missed: 9)
        #expect(NaturalKeyVenueMigration.stillInTheFeed([a, b]) == nil)
    }

    // It takes the FIRST live row, deliberately, so the caller's own ordering decides. Asserted rather
    // than left implicit, because the whole of #3780 is that one caller was not exercising that
    // choice, and a later reader must be able to tell the contract from an oversight.
    @Test func itHonoursTheOrderTheCallerGivesIt() throws {
        let ctx = try memoryContext()
        let first = row(ctx, key: "first", ingested: 1_000)
        let second = row(ctx, key: "second", ingested: 9_000)
        #expect(NaturalKeyVenueMigration.stillInTheFeed([first, second])?.naturalKey == "first")
        #expect(NaturalKeyVenueMigration.stillInTheFeed([second, first])?.naturalKey == "second")
    }

    // MARK: the caller that was not ordering, which is the defect

    // THE ONE THAT CATCHES #3780. `groupsOfOneShow` is handed rows in whatever order the fetch and a
    // Dictionary's iteration produced, and every order of the same rows must come back grouped the
    // same way, or which row survives a merge differs between two launches on identical data.
    @Test func groupsOfOneShowHandsItsMembersOverInAFixedOrder() throws {
        let ctx = try memoryContext()
        // Rows sharing ONE anchor, which is the second of the function's two branches: the one that
        // walks `byAnchor` for anchors no display group claimed. Named, because the two branches build
        // their member list separately and a fixture covering one says nothing about the other. The
        // test below covers the first.
        let rows = [
            row(ctx, key: "c", ingested: 4_000, venue: "The Cutting Room"),
            row(ctx, key: "a", ingested: 4_000, venue: "The Cutting Room, 44 East 32nd Street"),
            row(ctx, key: "b", ingested: 4_000, venue: "the cutting room"),
        ]

        let orders = (0..<30).map { _ in
            NaturalKeyVenueMigration.groupsOfOneShow(rows.shuffled())
                .map { (g: (key: String, members: [Prospect])) in g.members.map(\Prospect.naturalKey) }
                .sorted { ($0.first ?? "") < ($1.first ?? "") }
        }
        #expect(Set(orders.map { "\($0)" }).count == 1,
                Comment(rawValue: "the grouping depends on the order it is handed: "
                        + "\(Set(orders.map { "\($0)" }))"))
    }

    // And the order it fixes is OLDEST FIRST, which is the one `stillInTheFeed`'s comment always
    // claimed and the one `SameNightTitleVariantMerge` chose for itself, so the two callers now agree
    // rather than each meaning something different by the same call.
    @Test func groupsOfOneShowOrdersItsMembersOldestFirst() throws {
        let ctx = try memoryContext()
        let rows = [
            row(ctx, key: "newest", ingested: 9_000, venue: "The Cutting Room"),
            row(ctx, key: "oldest", ingested: 1_000, venue: "The Cutting Room, 44 East 32nd Street"),
            row(ctx, key: "middle", ingested: 5_000, venue: "the cutting room"),
        ]
        let group = try #require(NaturalKeyVenueMigration.groupsOfOneShow(rows)
            .first { $0.members.count > 1 })
        #expect(group.members.map(\Prospect.naturalKey) == ["oldest", "middle", "newest"])
    }

    // THE OTHER BRANCH, and it needed its own fixture. Removing the sort from the branch that collects
    // SEVERAL anchors under one display key left the suite green (measured with `scripts/mutate.sh`:
    // SURVIVED), because every row above shares one anchor and so never reaches it. A fixture that
    // cannot reach the code it is named for guards nothing (L159).
    //
    // Reaching it needs rows whose SCOUT-ANCHORED keys differ while their DISPLAY keys agree, which is
    // the real shape this function exists for: the scout spells the room one way per listing and the
    // card carries Dan's spelling, so several anchors describe one show in one room.
    @Test func itAlsoOrdersAGroupCollectedFromSeveralAnchors() throws {
        let ctx = try memoryContext()
        let rows = [
            row(ctx, key: "newest", ingested: 9_000, venue: "The Cutting Room",
                scoutVenue: "The Cutting Room, 44 East 32nd Street"),
            row(ctx, key: "oldest", ingested: 1_000, venue: "The Cutting Room",
                scoutVenue: "the cutting room nyc"),
            row(ctx, key: "middle", ingested: 5_000, venue: "The Cutting Room",
                scoutVenue: "Cutting Room Manhattan"),
        ]
        let group = try #require(NaturalKeyVenueMigration.groupsOfOneShow(rows)
            .first { $0.members.count > 1 },
            "the fixture must reach the several-anchors branch, or it tests the other one again")
        #expect(group.members.count == 3, "all three anchors belong to one display group")
        #expect(group.members.map(\Prospect.naturalKey) == ["oldest", "middle", "newest"])
    }

    // A tie on the stamp falls to the natural key, which is unique by construction, so the order is
    // total rather than merely usually settled. Without this the shuffle above passes on distinct
    // stamps and says nothing about the case that actually varies.
    @Test func aTieOnTheStampFallsToTheNaturalKey() throws {
        let ctx = try memoryContext()
        let rows = [
            row(ctx, key: "charlie", ingested: 4_000, venue: "The Cutting Room"),
            row(ctx, key: "alpha", ingested: 4_000, venue: "The Cutting Room, 44 East 32nd Street"),
            row(ctx, key: "bravo", ingested: 4_000, venue: "the cutting room"),
        ]
        let group = try #require(NaturalKeyVenueMigration.groupsOfOneShow(rows)
            .first { $0.members.count > 1 })
        #expect(group.members.map(\Prospect.naturalKey) == ["alpha", "bravo", "charlie"])
    }
}
