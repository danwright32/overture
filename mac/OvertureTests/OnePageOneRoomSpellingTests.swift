import Testing
import Foundation
import SwiftData

// #1848: one page, read on two days, naming its own room two ways.
//
// #1761 sweeps the duplicate up at every launch, forever, and does not touch the cause. The reading step
// is a prompt rather than code, so it gives a different answer on a different day: measured 2026-07-29,
// one source named its room "Jalopy Theatre" and six days later "Jalopy Theater", and 6 of the 25
// duplicate rows that measurement found had arrived in a single day's scout.
//
// The venue is one of the natural key's three fields, so a second spelling costs a second key, a second
// card, a second paid contact lookup and a place in the queue before anything merges it.
@MainActor
@Suite("One page, one spelling of its own room (#1848)")
struct OnePageOneRoomSpellingTests {

    private static let source = "jalopytheatre-com"
    private static let night = "2026-10-02"

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func ingest(_ ctx: ModelContext, title: String, venue: String, night: String = night,
                        source: String = source) -> ScoutService.Outcome {
        let e = ExtractedEvent(title: title, presenter: "Jalopy", venue: venue,
                               performanceDate: night, sourceUrl: "https://\(source)/events")
        let outcome = ScoutService.apply(events: [e], clients: [], history: [], blocked: .empty,
                                         today: "2026-09-21", sourceIds: [source], into: ctx)
        try? ctx.save()
        return outcome
    }

    private func rows(_ ctx: ModelContext) -> [Prospect] {
        (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
    }

    // THE CLAIM, with the live pair. The same page, the same show, the room spelled one letter
    // differently on the second read: one card, not two.
    @Test func thesamePageSpellingItsRoomOneLetterDifferentlyIsOneCard() throws {
        let ctx = try context()
        ingest(ctx, title: "Jalopy Open Mic", venue: "Jalopy Theatre")
        ingest(ctx, title: "Jalopy Open Mic", venue: "Jalopy Theater")

        let stored = rows(ctx)
        #expect(stored.count == 1,
                "the second reading minted a second card: \(stored.map { $0.venue ?? "?" })")
        #expect(stored.first?.venue == "Jalopy Theatre",
                "the spelling the source used first is the one that stands")
    }

    // THE PRECONDITION, so a green above cannot come from the two spellings folding to one key anyway
    // (L159). If they did, #1761 would have had nothing to sweep.
    @Test func thetwoSpellingsReallyDoProduceDifferentKeys() {
        let a = Prospect.makeNaturalKey(groupName: "Jalopy Open Mic", performanceDate: Self.night,
                                        venue: "Jalopy Theatre")
        let b = Prospect.makeNaturalKey(groupName: "Jalopy Open Mic", performanceDate: Self.night,
                                        venue: "Jalopy Theater")
        #expect(a != b, "the venue fold already joins these, so this issue would not exist")
    }

    // A DIFFERENT SOURCE is not locked to this one's spelling. The claim is that THIS page has already
    // said how it spells its own room, and it says nothing about anybody else's page.
    @Test func adifferentSourceKeepsItsOwnSpelling() throws {
        let ctx = try context()
        ingest(ctx, title: "Jalopy Open Mic", venue: "Jalopy Theatre")
        ingest(ctx, title: "Jalopy Open Mic", venue: "Jalopy Theater", source: "aggregator-example-org")

        #expect(rows(ctx).contains { $0.venue == "Jalopy Theater" },
                "another source's spelling was rewritten to this one's, which this rule never claims")
    }

    // A ROOM WITH AN EXTRA WORD IS NOT A TYPO, and this is the half deliberately left alone: a building
    // names its second room by adding a word, so folding them would merge two real rooms. The other live
    // pair from the same measurement, "Roulette" against "Roulette Intermedium", is therefore still two
    // cards, and #4020 owns that question.
    @Test func aroomSpelledWithAnExtraWordIsNotLocked() throws {
        let ctx = try context()
        ingest(ctx, title: "Nate Wooley", venue: "Roulette", source: "roulette-org")
        ingest(ctx, title: "Nate Wooley", venue: "Roulette Intermedium", source: "roulette-org")

        #expect(rows(ctx).count == 2,
                "an added word was treated as a typo, which merges a building's two rooms")
    }

    // THE RULE ITSELF, as a pure function, including the case the ingest fixtures cannot reach: two
    // stored spellings both one slip from the incoming one. The answer may not depend on which row the
    // store happened to return first (L343).
    @Test func thelockIsDeterministicWhenTwoStoredSpellingsQualify() {
        // "Theatrr" is one slip from BOTH stored spellings, which is what makes this a tie rather than a
        // single qualifier answering by default. The fixture this test was first written with ("Theatte")
        // was two slips from "Theater", so only one arm could ever qualify and the case the test is named
        // for was never reached (L159).
        #expect(GroupNameMatch.differsByOneSlipInOneWord("Jalopy Theater", "Jalopy Theatrr"))
        #expect(GroupNameMatch.differsByOneSlipInOneWord("Jalopy Theatre", "Jalopy Theatrr"))

        let used = ["Jalopy Theater", "Jalopy Theatre", "Jalopy Theatre"]
        #expect(VenueSpellingLock.locked("Jalopy Theatrr", spellingsUsedBySource: used)
                == "Jalopy Theatre", "the most used spelling wins")
        #expect(VenueSpellingLock.locked("Jalopy Theatrr", spellingsUsedBySource: used.reversed())
                == "Jalopy Theatre", "and the order the rows arrived in may not change the answer")
        #expect(VenueSpellingLock.locked("Jalopy Theatrr",
                                         spellingsUsedBySource: ["Jalopy Theater", "Jalopy Theatre"])
                == "Jalopy Theater", "an exact tie is broken alphabetically rather than by arrival")
    }

    // THE BOUNDARY between the two distances, which is the thing a later sweep is most likely to
    // "tidy" into one rule. The venue lock tolerates a transposition; the same-night TITLE rule does
    // not, because its calibration against the live store was taken with the narrower distance and
    // nothing has re-taken it (L220).
    @Test func atranspositionIsASlipForARoomAndNotForATitle() {
        #expect(GroupNameMatch.differsByOneSlipInOneWord("Jalopy Theatre", "Jalopy Theater"),
                "the live pair this issue is about is a swap, so the venue rule has to see it")
        #expect(!GroupNameMatch.isSameNightVariant("Jalopy Theatre", "Jalopy Theater"),
                "the title rule was widened as a side effect, which re-aims a calibration nobody re-took")
        #expect(GroupNameMatch.isSameNightVariant("Greely Square Series", "Greeley Square Series"),
                "and the one character case the title rule was calibrated on still holds")
    }

    // A SWAP IS STILL ONE WORD AND STILL NOT A NUMBER: the guards the two distances share are not
    // loosened by the arm that was added beside them.
    @Test func aswapDoesNotReachPastTheGuardsItSharesWithTheNarrowerRule() {
        #expect(!GroupNameMatch.differsByOneSlipInOneWord("Studio 12", "Studio 21"),
                "a room numbered two ways is two rooms, and digits are refused before any distance")
        #expect(!GroupNameMatch.differsByOneSlipInOneWord("Jalopy Theatre", "Jalopy Theatre Annex"),
                "an added word is how a building names a second room, which #4020 owns")
        #expect(!GroupNameMatch.differsByOneSlipInOneWord("Jalopy Theatre Hall", "Jalopy Theater Halls"),
                "two words differing is two slips, whichever kind each one is")
    }

    // AND IT LEAVES EVERYTHING ELSE ALONE: a spelling the source has used exactly, a room it has never
    // named, and an empty venue.
    @Test func thelockChangesNothingItHasNoAnswerFor() {
        #expect(VenueSpellingLock.locked("Jalopy Theatre", spellingsUsedBySource: ["Jalopy Theatre"])
                == "Jalopy Theatre")
        #expect(VenueSpellingLock.locked("Merkin Hall", spellingsUsedBySource: ["Jalopy Theatre"])
                == "Merkin Hall")
        #expect(VenueSpellingLock.locked(nil, spellingsUsedBySource: ["Jalopy Theatre"]) == nil)
        #expect(VenueSpellingLock.locked("  ", spellingsUsedBySource: ["Jalopy Theatre"]) == "  ")
    }
}
