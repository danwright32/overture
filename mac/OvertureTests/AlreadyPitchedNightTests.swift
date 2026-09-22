import Testing
import Foundation
import SwiftData

// #4130: a card lands on a night a presenter was already written to about, and nothing says so.
//
// THE CASE, measured on the live store 2026-09-21 and re-read from a WAL inclusive clone on 2026-09-22.
// Prospect 344 "Morahan Arts End of Year Showcase (6th Annual)", presenter Morahan Arts, is `contacted`
// and was sent on 2026-07-18. The scout then inserted prospect 1561 "Sixth Annual End of Year Showcase",
// the same presenter, the same night (2027-05-23), the same room. Neither card mentions the other.
//
// WHY THE ISSUE'S OWN RULE IS NOT THE RULE BUILT. It asks for the same night and the same folded venue
// and nothing else. Measured over that clone, that tags 39 rows, of which 30 are at The Green Room 42
// and 6 at 54 Below: cabaret rooms running several different acts a night, where a duplicate warning is
// simply false. Adding the presenter, who is the person written to and therefore the whole of the harm,
// takes it to exactly ONE row, the case above. The measurement is in this suite as a live store report
// so the next person does not have to take the paragraph on trust.
@MainActor
@Suite("A card landing on a night already pitched (#4130)")
struct AlreadyPitchedNightTests {
    private let sandboxes = TemporarySandboxes()

    private static let night = "2027-05-23"
    private static let venue = "Five Angels Theater at the 52nd Street Project"
    private static let presenter = "Morahan Arts"
    private static let sentTitle = "Morahan Arts End of Year Showcase (6th Annual)"
    private static let arrivingTitle = "Sixth Annual End of Year Showcase"

    nonisolated private static var liveStoreExists: Bool {
        FileManager.default.fileExists(
            atPath: StoreLocation.storeURL(appSupport: StoreLocation.appSupport,
                                           isDebugBuild: false).path)
    }

    private func container(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, url: url,
                                                                      cloudKitDatabase: .none)])
    }

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func stored(_ ctx: ModelContext, _ title: String, presenter: String? = presenter,
                        night: String = night, venue: String = venue, sent: Bool) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title, performanceDate: night,
                                                            venue: venue),
                         groupName: title, discipline: "theater", venue: venue,
                         performanceDate: night, sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        p.presenter = presenter
        if sent {
            p.sentAt = Date(timeIntervalSince1970: 1_752_800_000)
            p.statusRaw = ReviewStatus.contacted.rawValue
        }
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func ingest(_ ctx: ModelContext, _ title: String, presenter: String = presenter,
                        night: String = night, venue: String = venue) {
        let e = ExtractedEvent(title: title, presenter: presenter, venue: venue,
                               performanceDate: night, sourceUrl: "https://morahanarts.com/classes")
        _ = ScoutService.apply(events: [e], clients: [], history: [], blocked: .empty,
                               today: "2026-09-21", sourceIds: ["morahanarts-com"], into: ctx)
        try? ctx.save()
    }

    private func all(_ ctx: ModelContext) -> [Prospect] {
        (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
    }

    // THE CLAIM, driven through the real `ScoutService.apply`. Both rows survive, and the arriving one
    // knows which card already carries a pitch for that night.
    @Test func anArrivalOnAPitchedNightIsTagged() throws {
        let ctx = try context()
        let sent = stored(ctx, Self.sentTitle, sent: true)
        ingest(ctx, Self.arrivingTitle)

        let rows = all(ctx)
        #expect(rows.count == 2, "tagging must never cost a row: \(rows.map(\.groupName).sorted())")
        let arrived = try #require(rows.first { $0.groupName == Self.arrivingTitle })
        #expect(arrived.arrivedOnAPitchedNight == sent.naturalKey,
                "the arriving row carries no tag, so the queue invites a second pitch in silence")
    }

    // THE PRECONDITION, so a green above cannot come from a fixture where something else joined the two
    // rows or where a title rule would have caught it anyway (L159). Every title predicate in the app
    // refuses this pair, which is exactly why neither the merge nor #3330's tag can cover it.
    @Test func everyTitleRuleRefusesThisPair() {
        #expect(!GroupNameMatch.isSameShowTitle(Self.sentTitle, Self.arrivingTitle))
        #expect(!GroupNameMatch.isSameNightVariant(Self.sentTitle, Self.arrivingTitle),
                "if the same-night rule accepted this pair, #3330's tag would already say it")
    }

    // WHAT MUST NOT BE TAGGED, and it is the commonest shape in the store rather than a corner case
    // (L104). The Green Room 42 runs several different acts on one night, each with its own producer,
    // and Dan pitches them separately. The titles and presenters below are the live store's own.
    @Test func aDifferentPresenterInTheSameRoomOnTheSameNightIsNotTagged() throws {
        let ctx = try context()
        stored(ctx, "The ATF Cabaret", presenter: "ATF Productions", night: "2026-10-03",
               venue: "The Green Room 42", sent: true)
        ingest(ctx, "Legends: A New Musical", presenter: "Legends Company", night: "2026-10-03",
               venue: "The Green Room 42")

        let arrived = try #require(all(ctx).first { $0.groupName == "Legends: A New Musical" })
        #expect(arrived.arrivedOnAPitchedNight == nil,
                "a cabaret room's second act of the night was called a duplicate pitch")
    }

    // A ROW THAT HAS NOT BEEN SENT is not a pitch. A drafted row has had a contact check paid for and
    // nothing has left the Mac, so a card claiming it was already pitched would claim more than the
    // check measured (L11).
    @Test func aStoredRowThatWasNeverSentTagsNothing() throws {
        let ctx = try context()
        stored(ctx, Self.sentTitle, sent: false)
        ingest(ctx, Self.arrivingTitle)

        let arrived = try #require(all(ctx).first { $0.groupName == Self.arrivingTitle })
        #expect(arrived.arrivedOnAPitchedNight == nil)
    }

    // A DIFFERENT NIGHT at the same room is a different engagement, and a DIFFERENT ROOM on the same
    // night is a different pitch. Both are what the sentence claims, so both are asserted.
    @Test func anotherNightOrAnotherRoomIsNotTagged() throws {
        let other = try context()
        stored(other, Self.sentTitle, sent: true)
        ingest(other, Self.arrivingTitle, night: "2027-05-24")
        #expect(try #require(all(other).first { $0.groupName == Self.arrivingTitle })
                    .arrivedOnAPitchedNight == nil)

        let elsewhere = try context()
        stored(elsewhere, Self.sentTitle, sent: true)
        ingest(elsewhere, Self.arrivingTitle, venue: "The Duke on 42nd Street")
        #expect(try #require(all(elsewhere).first { $0.groupName == Self.arrivingTitle })
                    .arrivedOnAPitchedNight == nil)
    }

    // AN UNNAMED PRESENTER matches every other unnamed row, and 443 of the store's 1,333 rows have had
    // theirs drained to nil because it WAS the room (#1766). Without this guard the note would land on
    // every second show at every busy venue.
    @Test func anUnnamedPresenterTagsNothing() {
        let sentRow = AlreadyPitchedNight.Stored(key: "sent", presenter: nil,
                                                 performanceDate: Self.night, venue: Self.venue,
                                                 sentAt: Date(timeIntervalSince1970: 1_752_800_000))
        #expect(AlreadyPitchedNight.amongStored([sentRow], presenter: nil,
                                                performanceDate: Self.night, venue: Self.venue,
                                                excludingKey: "arriving") == nil)
        #expect(AlreadyPitchedNight.amongStored([sentRow], presenter: "  ",
                                                performanceDate: Self.night, venue: Self.venue,
                                                excludingKey: "arriving") == nil)
    }

    // A PRESENTER WHOSE NAME MERELY CONTAINS ANOTHER'S is a different organisation, and one of them has
    // not been written to. This is why the presenter test is exact folded equality rather than
    // `GroupNameMatch.isConfident`, which accepts token containment.
    @Test func aPresenterWhoseNameContainsAnothersIsNotTheSamePresenter() {
        let sentRow = AlreadyPitchedNight.Stored(key: "sent", presenter: "Morahan Arts Center",
                                                 performanceDate: Self.night, venue: Self.venue,
                                                 sentAt: Date(timeIntervalSince1970: 1_752_800_000))
        #expect(AlreadyPitchedNight.amongStored([sentRow], presenter: Self.presenter,
                                                performanceDate: Self.night, venue: Self.venue,
                                                excludingKey: "arriving") == nil)
        #expect(GroupNameMatch.isConfident("Morahan Arts", "Morahan Arts Center"),
                "the looser predicate WOULD have joined them, which is what this rule declines to use")
    }

    // The row never points at ITSELF, which a rule reading the store after the row is written would do.
    @Test func aRowNeverTagsItself() {
        let itself = AlreadyPitchedNight.Stored(key: "arriving", presenter: Self.presenter,
                                                performanceDate: Self.night, venue: Self.venue,
                                                sentAt: Date(timeIntervalSince1970: 1_752_800_000))
        #expect(AlreadyPitchedNight.amongStored([itself], presenter: Self.presenter,
                                                performanceDate: Self.night, venue: Self.venue,
                                                excludingKey: "arriving") == nil)
    }

    // An undated arrival has no night to collide on.
    @Test func anUndatedArrivalTagsNothing() {
        let sentRow = AlreadyPitchedNight.Stored(key: "sent", presenter: Self.presenter,
                                                 performanceDate: nil, venue: Self.venue,
                                                 sentAt: Date(timeIntervalSince1970: 1_752_800_000))
        #expect(AlreadyPitchedNight.amongStored([sentRow], presenter: Self.presenter,
                                                performanceDate: nil, venue: Self.venue,
                                                excludingKey: "arriving") == nil)
    }

    // THE SENTENCE. Dan's wording, chosen 2026-09-22 with the three alternatives and their worst case in
    // front of him: name the presenter and name the other show.
    @Test func theCardNamesThePresenterAndTheShowAlreadyPitched() throws {
        let ctx = try context()
        var item = QueueItem(stored(ctx, Self.arrivingTitle, sent: false))
        item.arrivedOnAPitchedNightTitle = Self.sentTitle
        #expect(QueueModel.alreadyPitchedNightNote(item)
                == "Morahan Arts was already pitched for this night, as "
                   + "\"Morahan Arts End of Year Showcase (6th Annual)\".")
    }

    // Resolved at READ time, so a card whose pitched twin has since been deleted or merged away says
    // NOTHING rather than naming a row that is no longer stored (L200).
    @Test func aCardWhosePitchedTwinIsGoneSaysNothing() throws {
        let ctx = try context()
        var item = QueueItem(stored(ctx, Self.arrivingTitle, sent: false))
        item.arrivedOnAPitchedNightTitle = nil
        #expect(QueueModel.alreadyPitchedNightNote(item) == nil)
        item.arrivedOnAPitchedNightTitle = ""
        #expect(QueueModel.alreadyPitchedNightNote(item) == nil,
                "an empty title drew a sentence naming nothing")
    }

    // And a card with no presenter of its own draws nothing, because the sentence begins with the
    // presenter's name and a sentence starting with an empty string is not a sentence.
    @Test func aCardWithNoPresenterSaysNothing() throws {
        let ctx = try context()
        var item = QueueItem(stored(ctx, Self.arrivingTitle, presenter: nil, sent: false))
        item.arrivedOnAPitchedNightTitle = Self.sentTitle
        #expect(QueueModel.alreadyPitchedNightNote(item) == nil)
    }

    // THE POPULATION, over the live store, REPORTING and never refusing. It prints what the rule as
    // built would tag BESIDE what the issue's own weaker rule (night plus room, no presenter) would
    // tag, because the gap between those two numbers is the whole reason the presenter is in the rule.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theRuleAndTheRuleWithoutThePresenterTagTheseManyRows() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "already-pitched-night")
            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                // SAYS SO rather than returning quietly: this test passes either way, so a silent
                // return would be indistinguishable from a walk that found nothing (L11, L98).
                print("Already pitched night: UNMEASURED, the live store could not be cloned.")
                await RealStoreTestLock.shared.release()
                return
            }
            let ctx = ModelContext(try container(at: clone))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            let rows = all.map {
                AlreadyPitchedNight.Stored(key: $0.naturalKey, presenter: $0.presenter,
                                           performanceDate: $0.performanceDate, venue: $0.venue,
                                           sentAt: $0.sentAt)
            }

            var tagged = 0
            var withoutPresenter = 0
            var roomsWithoutPresenter: [String: Int] = [:]
            for row in rows {
                if AlreadyPitchedNight.amongStored(rows, presenter: row.presenter,
                                                   performanceDate: row.performanceDate,
                                                   venue: row.venue, excludingKey: row.key) != nil {
                    tagged += 1
                }
                // The issue's own rule, spelled out here rather than built, so the number it would
                // produce is on the record beside the number the rule as built produces.
                let collides = rows.contains { other in
                    other.key != row.key && other.sentAt != nil
                        && other.performanceDate == row.performanceDate
                        && (other.venue ?? "").lowercased() == (row.venue ?? "").lowercased()
                }
                if let date = row.performanceDate, !date.isEmpty, collides {
                    withoutPresenter += 1
                    roomsWithoutPresenter[row.venue ?? "(no venue)", default: 0] += 1
                }
            }
            let rooms = roomsWithoutPresenter.sorted { $0.value > $1.value }
                .prefix(3).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            print("Already pitched night over \(all.count) rows: \(tagged) tagged by the rule as built, "
                  + "\(withoutPresenter) by night and room alone. Busiest rooms without the presenter "
                  + "test: \(rooms)")

            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
