import Testing
import Foundation
import SwiftData

// #1752: the rooms Overture cannot place, and Dan saying where they are.
//
// LIVE-STORE-CLAIM verified=2026-08-07 measure="stored prospects with a blank location, and the distinct rooms they name"
// Measured on the live store before building: 78 of 845 shows carry no location across 18 distinct room
// spellings, and 56 of the 78 are ONE room, 54 Below, which the curated table has never heard of. Those
// spellings are used verbatim below rather than invented, because a fixture shaped to make the rule fire
// tests nothing (L48). The two 54 Below spellings really do both sit in the store today.
@MainActor
@Suite("Naming a room Overture cannot place (#1752)")
struct UnplacedRoomsTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, WatchedSource.self,
                                        VenuePlaceAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @discardableResult
    private func show(_ ctx: ModelContext, key: String, venue: String?, location: String? = nil,
                      title: String = "An evening of songs") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: title, discipline: "music", venue: venue,
                         performanceDate: "2099-05-05", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.location = location
        ctx.insert(p)
        return p
    }

    private func rooms(_ ctx: ModelContext) throws -> [UnplacedRooms.Room] {
        UnplacedRooms.from(try ctx.fetch(FetchDescriptor<Prospect>()))
    }

    // MARK: - The list

    // The live shape: one room, two spellings, and the list must not offer it twice. Asking the same
    // question in two rows is asking Dan to answer it twice for the same answer.
    @Test func twoSpellingsOfOneRoomAreOneQuestion() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", venue: "54 Below")
        show(ctx, key: "k2", venue: "54 Below, 254 W 54th St. Cellar, NYC 10019")

        let list = try rooms(ctx)
        #expect(list.count == 1)
        #expect(list.first?.showCount == 2)
    }

    // And it names the room in the words he would recognise and type, not the one carrying an address.
    @Test func theRoomIsNamedByItsBareSpelling() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", venue: "54 Below, 254 W 54th St. Cellar, NYC 10019")
        show(ctx, key: "k2", venue: "54 Below")

        #expect(try rooms(ctx).first?.name == "54 Below")
    }

    // Most shows first, because one answer to the biggest room is worth more than fifteen to the rest.
    @Test func theRoomHoldingTheMostShowsLeads() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", venue: "Cherry Lane Theatre")
        show(ctx, key: "k2", venue: "54 Below")
        show(ctx, key: "k3", venue: "54 Below")

        #expect(try rooms(ctx).map(\.name) == ["54 Below", "Cherry Lane Theatre"])
    }

    // A room that already knows where it is has nothing to ask about.
    @Test func aPlacedRoomIsNotListed() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", venue: "54 Below", location: "New York, NY")

        #expect(try rooms(ctx).isEmpty)
    }

    // A show with no venue at all is left out: its card already reads "Venue TBD", there is no room to
    // name, and listing it would ask a question with no answer.
    @Test func aShowWithNoVenueIsNotAQuestion() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", venue: nil)
        show(ctx, key: "k2", venue: "   ")

        #expect(try rooms(ctx).isEmpty)
    }

    // MARK: - Answering

    @Test func answeringARoomPlacesEveryShowInIt() throws {
        let ctx = ModelContext(try container())
        let a = show(ctx, key: "k1", venue: "54 Below")
        let b = show(ctx, key: "k2", venue: "54 Below, 254 W 54th St. Cellar, NYC 10019")

        #expect(VenuePlaceAnswering.record(venue: "54 Below", location: "New York, NY",
                                           in: ctx, now: now) == 2)
        #expect(a.location == "New York, NY")
        #expect(b.location == "New York, NY")
        #expect(try rooms(ctx).isEmpty)
    }

    @Test func answeringOneRoomLeavesAnotherAlone() throws {
        let ctx = ModelContext(try container())
        let mine = show(ctx, key: "k1", venue: "54 Below")
        let other = show(ctx, key: "k2", venue: "Cherry Lane Theatre")

        #expect(VenuePlaceAnswering.record(venue: "54 Below", location: "New York, NY",
                                           in: ctx, now: now) == 1)
        #expect(mine.location == "New York, NY")
        #expect(other.location == nil)
    }

    // The answer outlives the shows it was given for: a room answered once places the next show that
    // arrives in it, which is the whole point of keying on the room rather than the card.
    @Test func theAnswerReachesAShowThatArrivesLater() throws {
        let ctx = ModelContext(try container())
        VenuePlaceAnswering.record(venue: "54 Below", location: "New York, NY", in: ctx, now: now)

        let later = show(ctx, key: "k9", venue: "54 Below")
        #expect(LocationBackfill.run(in: ctx) == 1)
        #expect(later.location == "New York, NY")
    }

    // Answering again corrects it rather than leaving two answers for one room to disagree.
    @Test func answeringTwiceCorrectsTheOneAnswer() throws {
        let ctx = ModelContext(try container())
        VenuePlaceAnswering.record(venue: "54 Below", location: "Newark, NJ", in: ctx, now: now)
        VenuePlaceAnswering.record(venue: "54 Below", location: "New York, NY", in: ctx, now: now)

        let stored = try ctx.fetch(FetchDescriptor<VenuePlaceAnswer>())
        #expect(stored.count == 1)
        #expect(stored.first?.location == "New York, NY")
    }

    // A blank answer withdraws the entry rather than storing one that says nothing, and does not reach
    // back into shows an earlier answer already placed: that is a larger action than the one taken.
    @Test func clearingAnAnswerRemovesItWithoutUnplacingAnything() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, key: "k1", venue: "54 Below")
        VenuePlaceAnswering.record(venue: "54 Below", location: "New York, NY", in: ctx, now: now)

        #expect(VenuePlaceAnswering.record(venue: "54 Below", location: "  ", in: ctx, now: now) == 0)
        #expect(try ctx.fetch(FetchDescriptor<VenuePlaceAnswer>()).isEmpty)
        #expect(p.location == "New York, NY")
    }

    // MARK: - Where the answer sits among the other rules

    // Above the curated table, because a room Dan has answered for is by definition one the table got
    // wrong or never knew. Weill Recital Hall IS in the table, so this is a real override, not a gap.
    @Test func hisAnswerOutranksTheCuratedTable() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, key: "k1", venue: "Weill Recital Hall")
        p.location = nil

        VenuePlaceAnswering.record(venue: "Weill Recital Hall", location: "Somewhere Else, ZZ",
                                   in: ctx, now: now)
        #expect(p.location == "Somewhere Else, ZZ")
    }

    // Below everything that reads text about THIS show. A touring date whose own title says where it is
    // keeps that, because his answer is a standing fact about the room and the title is first-hand about
    // the night.
    @Test func theShowsOwnWordsStillOutrankHisAnswer() throws {
        let ctx = ModelContext(try container())
        VenuePlaceAnswering.record(venue: "54 Below", location: "New York, NY", in: ctx, now: now)
        let touring = show(ctx, key: "k1", venue: "54 Below",
                           title: "NYO2 in Santo Domingo, Dominican Republic")

        #expect(LocationBackfill.run(in: ctx) == 1)
        #expect(touring.location?.contains("Santo Domingo") == true)
    }

    // MARK: - What it says

    @Test func theAcknowledgementSaysHowManyShowsTookIt() {
        #expect(UnplacedRoomCopy.savedAck(room: "54 Below", placed: 56).contains("56"))
        #expect(UnplacedRoomCopy.savedAck(room: "54 Below", placed: 1).contains(" 1 show"))
    }

    @Test func placingNothingSaysSoRatherThanClaimingANumber() {
        let none = UnplacedRoomCopy.savedAck(room: "54 Below", placed: 0)
        #expect(none.contains("0") == false)
        #expect(none != UnplacedRoomCopy.savedAck(room: "54 Below", placed: 1))
    }

    // The count beside a room is a promise about what answering it reaches, so it is stated as shows
    // waiting, never as a coverage score (#1029: Dan does not want "N of M shows say where they are").
    @Test func theRoomLineNamesTheRoomAndWhatIsWaitingOnIt() {
        let line = UnplacedRoomCopy.waiting(showCount: 56)
        #expect(line.contains("56"))
        // Singular, so the line never reads "1 shows". Asserted on the whole sentence rather than a
        // fragment, since a fragment match here would pass on "21 shows" too.
        #expect(UnplacedRoomCopy.waiting(showCount: 1) == "1 show waiting on this")
        #expect(UnplacedRoomCopy.waiting(showCount: 2) == "2 shows waiting on this")
    }
}
