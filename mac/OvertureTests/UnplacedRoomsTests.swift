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

    // #2359: dated inside the queue's lead time window, against the pinned `today` below, rather than
    // parked in 2099. The room list rides on StageNavigation.queueKeys, which now stops at that window,
    // so a date far enough out to be "always in the future" is also far enough out to be in no stage.
    @discardableResult
    private func show(_ ctx: ModelContext, key: String, venue: String?, location: String? = nil,
                      title: String = "An evening of songs") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: title, discipline: "music", venue: venue,
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.location = location
        ctx.insert(p)
        return p
    }

    private func rooms(_ ctx: ModelContext) throws -> [UnplacedRooms.Room] {
        UnplacedRooms.from(try ctx.fetch(FetchDescriptor<Prospect>()), today: "2026-08-07")
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

// #1752 follow-up: the list is CACHED behind a signature, because building it walks every stored show
// and the Sources sheet re-evaluates its body on every keystroke and scroll tick. That is the defect
// #1356 and #1429 each fixed on this very sheet, and shipping the list inline reintroduced it.
//
// A signature is only worth anything if it MOVES when the list would. These pin exactly that, because a
// signature that never changes caches a stale list forever and one that always changes caches nothing.
@MainActor
@Suite("The unplaced-room list is not rebuilt on every redraw (#1752)")
struct UnplacedRoomsSignatureTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, WatchedSource.self,
                                        VenuePlaceAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // #2359: inside the lead time window measured from the pinned `today` these tests pass, for the same
    // reason as the suite above.
    @discardableResult
    private func show(_ ctx: ModelContext, key: String, venue: String?, location: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "A show", discipline: "music", venue: venue,
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.location = location
        ctx.insert(p)
        return p
    }

    private func all(_ ctx: ModelContext) throws -> [Prospect] {
        try ctx.fetch(FetchDescriptor<Prospect>())
    }

    // The whole point: an unrelated redraw must not move it, or the cache saves nothing.
    @Test func readingTheSameStoreTwiceGivesTheSameSignature() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", venue: "54 Below")

        #expect(UnplacedRooms.signature(try all(ctx), today: "2026-08-07") == UnplacedRooms.signature(try all(ctx), today: "2026-08-07"))
    }

    // The change that MUST move it: a room getting an answer fills its shows' locations, and a stale list
    // would keep asking Dan a question he has already answered.
    @Test func placingAShowMovesTheSignature() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, key: "k1", venue: "54 Below")
        let before = UnplacedRooms.signature(try all(ctx), today: "2026-08-07")

        p.location = "New York, NY"
        #expect(UnplacedRooms.signature(try all(ctx), today: "2026-08-07") != before)
    }

    @Test func aNewUnplacedShowMovesTheSignature() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", venue: "54 Below")
        let before = UnplacedRooms.signature(try all(ctx), today: "2026-08-07")

        show(ctx, key: "k2", venue: "Cherry Lane Theatre")
        #expect(UnplacedRooms.signature(try all(ctx), today: "2026-08-07") != before)
    }

    // A show that already knows where it is cannot change this list, so it must not invalidate the cache
    // either: every scout that places a show would otherwise rebuild it for nothing.
    @Test func changingAPlacedShowsRoomLeavesTheSignatureAlone() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", venue: "54 Below")
        let placed = show(ctx, key: "k2", venue: "Merkin Hall", location: "New York, NY")
        let before = UnplacedRooms.signature(try all(ctx), today: "2026-08-07")

        placed.venue = "Somewhere Else Entirely"
        #expect(UnplacedRooms.signature(try all(ctx), today: "2026-08-07") == before)
    }
}

// #1752, found by WALKING the app rather than by any test.
//
// The panel listed "Denny Farrell Riverbank State Park, 2 shows waiting on this" on the Debug store,
// and both of those shows were dated June 27 and July 11 against a clock reading August 7. Nothing was
// waiting on that room: the shows had already happened. The list counted every stored row, so it would
// have accumulated dead rooms forever and every count in it would drift upward, which is the exact
// opposite of the action list #1029 asked for.
//
// It also explains why no queue card could be found showing the ask: every unplaced show in that store
// was past, so none of them was in the queue at all. One fact, two symptoms.
@MainActor
@Suite("The unplaced-room list only counts shows still ahead (#1752)")
struct UnplacedRoomsStillAheadTests {
    private let today = "2026-08-07"

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, WatchedSource.self,
                                        VenuePlaceAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func show(_ ctx: ModelContext, key: String, venue: String?, date: String?,
                      runEnd: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "A show", discipline: "music", venue: venue,
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.runEndDate = runEnd
        ctx.insert(p)
        return p
    }

    private func rooms(_ ctx: ModelContext) throws -> [UnplacedRooms.Room] {
        UnplacedRooms.from(try ctx.fetch(FetchDescriptor<Prospect>()), today: today)
    }

    // The live shape from the Debug store: a room whose only shows have already happened.
    @Test func aRoomWhoseShowsHaveAllHappenedIsNotAsked() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", venue: "Denny Farrell Riverbank State Park", date: "2026-06-27")
        show(ctx, key: "k2", venue: "Denny Farrell Riverbank State Park", date: "2026-07-11")

        #expect(try rooms(ctx).isEmpty)
    }

    // And the count is of what is actually still waiting, not of everything the room ever held.
    @Test func onlyTheShowsStillAheadAreCounted() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", venue: "54 Below", date: "2026-06-27")
        show(ctx, key: "k2", venue: "54 Below", date: "2026-09-01")
        show(ctx, key: "k3", venue: "54 Below", date: "2026-09-02")

        #expect(try rooms(ctx).first?.showCount == 2)
    }

    // Today counts as still ahead: a show tonight is one Dan can still act on.
    @Test func aShowTodayStillCounts() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", venue: "54 Below", date: today)

        #expect(try rooms(ctx).first?.showCount == 1)
    }

    // A multi-night run is counted while it has not OPENED yet, not while any night of it is ahead.
    //
    // #1752 judged this on the run's LAST date, so a run that opened last week and plays for another
    // month stayed in the list. #2288 reversed it, because the Queue does not show Dan such a run at all
    // (#1540: once a run has started he will not pitch it), so the panel was asking him to place a room
    // whose only show he would never see. The room list follows the Queue now, and this is the case where
    // the two rules genuinely disagreed. The underway half is pinned in UnplacedRoomsFollowTheQueueTests,
    // beside the other two shapes that disagreed.
    @Test func aRunNotYetOpenedCounts() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", venue: "54 Below", date: "2026-08-20", runEnd: "2026-09-06")

        #expect(try rooms(ctx).first?.showCount == 1)
    }

    // A show carrying no date at all cannot be proved past, so it is still asked about. The failure
    // direction matters: a room wrongly listed costs Dan one glance, a room wrongly dropped costs him
    // the geography rule on every show in it, silently.
    @Test func aShowWithNoDateIsStillAsked() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", venue: "54 Below", date: nil)

        #expect(try rooms(ctx).first?.showCount == 1)
    }

    // The signature has to move on the same rule, or the cached list goes stale the moment a show ages
    // out and the panel keeps naming a room nothing is waiting on.
    @Test func theSignatureMovesWhenTheLastShowInARoomPasses() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", venue: "54 Below", date: "2026-09-01")
        let onTheDay = UnplacedRooms.signature(try ctx.fetch(FetchDescriptor<Prospect>()), today: today)
        let afterwards = UnplacedRooms.signature(try ctx.fetch(FetchDescriptor<Prospect>()),
                                                 today: "2026-09-02")
        #expect(onTheDay != afterwards)
    }
}

// #2288: the panel asks the QUEUE whether a show is still waiting, rather than answering it again here.
//
// The count beside a room is a promise about what answering it reaches, and the room list used to keep
// that promise with a date comparison of its own (the run's LAST night against today) while every other
// surface asked StageNavigation, which folds status, reached-out state and geography into the same
// question. Two implementations of one question is the drift milestone #1575 exists to stop, and these
// are the cases where the two genuinely disagree: a show Dan has cut, a show he has already pitched, and
// a run that has already opened. In each one the old rule named a room whose shows the Queue will not
// show him.
@MainActor
@Suite("The unplaced-room list counts exactly what the Queue will show (#2288)")
struct UnplacedRoomsFollowTheQueueTests {
    private let today = "2026-08-07"
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, WatchedSource.self,
                                        VenuePlaceAnswer.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func show(_ ctx: ModelContext, key: String, venue: String = "54 Below",
                      date: String? = "2026-09-01", runEnd: String? = nil,
                      status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "A show", discipline: "music", venue: venue,
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.runEndDate = runEnd
        ctx.insert(p)
        return p
    }

    private func rooms(_ ctx: ModelContext) throws -> [UnplacedRooms.Room] {
        UnplacedRooms.from(try ctx.fetch(FetchDescriptor<Prospect>()), today: today, now: now)
    }

    // A show Dan has cut sits in no stage, so nothing on it is waiting on an answer. The date rule kept
    // counting it, because by the calendar it is still ahead.
    @Test func aCutShowIsNotWaitingOnTheRoom() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", status: .dismissed)

        #expect(try rooms(ctx).isEmpty)
    }

    // #1540: once a run has opened Dan will not pitch it, so no stage renders it. The date rule kept it,
    // because it judged the run's LAST night, so the panel asked him to place a room whose only show the
    // Queue would never put in front of him.
    @Test func aRunAlreadyUnderwayIsNotWaitingOnTheRoom() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "k1", date: "2026-08-01", runEnd: "2026-09-06")

        #expect(try rooms(ctx).isEmpty)
    }

    // A show already pitched is out of the Queue's own count: the work left on it is a reply, not a
    // place, and the geography gate never cuts a contacted show anyway. It carries a send error here on
    // purpose, because that is a show a stage still renders, so only the reached-out half of the shared
    // rule can take it out, and that is precisely the input the panel never had.
    @Test func aPitchedShowIsNotWaitingOnTheRoom() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, key: "k1", status: .contacted)
        p.sendError = "Gmail refused the message"
        let r = Recipient(id: "info@example.org", email: "info@example.org", provenance: .presenter)
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-3 * 86_400)
        r.gmailMessageId = "msg-1"
        r.gmailThreadId = "t-1"
        p.addRecipient(r)

        #expect(try rooms(ctx).isEmpty)
    }

    // And what it does count is the Queue's own set, over a store holding one show of each kind. The
    // expectation is resolved by asking StageNavigation over EVERY stored show, so this cannot pass by
    // the panel and the queue sharing one narrowed input.
    @Test func theCountIsTheQueuesOwnAnswer() throws {
        let ctx = ModelContext(try container())
        show(ctx, key: "live-1")
        show(ctx, key: "live-2", date: "2026-09-02")
        show(ctx, key: "cut", status: .dismissed)
        show(ctx, key: "underway", date: "2026-08-01", runEnd: "2026-09-06")
        show(ctx, key: "placed", date: "2026-09-03").location = "New York, NY"

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        let inQueue = StageNavigation.queueKeys(in: stored, reachedOutKeys: [], today: today, now: now)
        let waiting = stored.filter { ($0.location ?? "").isEmpty && inQueue.contains($0.naturalKey) }

        #expect(waiting.count == 2, "the fixture must hold shows the queue shows, or this proves nothing")
        #expect(try rooms(ctx).map(\.showCount).reduce(0, +) == waiting.count)
    }

    // The cached list is only worth what its signature is worth. A show leaving the Queue for a reason
    // that is not the calendar has to move it too, or the panel keeps naming a room nothing is waiting
    // on until something unrelated happens to change.
    @Test func cuttingTheLastShowInARoomMovesTheSignature() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, key: "k1")
        let before = UnplacedRooms.signature(try ctx.fetch(FetchDescriptor<Prospect>()),
                                             today: today, now: now)

        p.status = .dismissed
        #expect(UnplacedRooms.signature(try ctx.fetch(FetchDescriptor<Prospect>()),
                                        today: today, now: now) != before)
    }
}
