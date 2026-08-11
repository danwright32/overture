import Testing
import Foundation

// #2450 (Prospector P0.1(c)): the fold assertions the seed table depends on, driven from the COMMITTED
// fixture rather than from Dan's real export, so they run on every machine and in every checkout.
//
// The live-store half of P0.1 (`SeedTableCensusLiveStoreTests`) is where the census is measured, and it
// skips wherever there is no live store. That is the right place for a measurement and the wrong place
// for a regression guard: a guard that only runs on one Mac is a guard that mostly does not run. So the
// invariants live here, over `fixtures/shoot-history/v1.json`.
//
// The fixture holds SIX rows and cannot reproduce the census, deliberately: every row in it is a shape
// MEASURED in the real export (see its README), never one invented to make a rule fire, because a
// fabricated fixture makes a test appear to cover a case that cannot occur and then passes forever while
// protecting nothing (L48). Nothing was added to it here; these assertions are read off the shapes it
// already carries.
//
// Each of these was seen to FAIL first, by reverting one line of `VenuePlaces.sourceCleaned`: dropping
// the wrapping-quote strip reds the quote test, dropping the newline-to-comma rewrite reds the newline
// test and the two-spellings test with it.
@Suite("Shoot history folds, from the committed fixture (#2450)")
struct ShootHistoryFoldFixtureTests {

    private func fixtureShoots() throws -> [ShootRecord] {
        let url = RepoRoot.url.appendingPathComponent("fixtures/shoot-history/v1.json")
        return try JSONDecoder().decode(ShootHistoryFile.self, from: try Data(contentsOf: url)).shoots
    }

    // Every raw spelling folds to a non-empty key. A spelling that folds to nothing is a shoot that can
    // never seed a room and can never be counted against one, and it would be invisible: it simply would
    // not appear in the table at all.
    @Test func everyRawShootSpellingFoldsToANonEmptyKey() throws {
        for shoot in try fixtureShoots() {
            let key = VenuePlaces.canonicalKey(for: shoot.venue)
            #expect(key != nil && !(key ?? "").isEmpty,
                    "no key for \(shoot.venue.replacingOccurrences(of: "\n", with: "\\n"))")
        }
    }

    // A wrapping pair of double quotes is the calendar's formatting, not part of the room's name (40 of
    // 322 events in the real export carry it). Asserted against the fixture's own quoted row and the
    // exact same string with the pair removed, so the two can only agree if the fold removes it.
    @Test func aWrappingQuotePairFoldsToTheSameRoomAsTheBareSpelling() throws {
        let quoted = try #require(try fixtureShoots().first {
            $0.venue.hasPrefix("\"") && $0.venue.hasSuffix("\"")
        })
        let bare = String(quoted.venue.dropFirst().dropLast())
        #expect(VenuePlaces.canonicalKey(for: quoted.venue) == VenuePlaces.canonicalKey(for: bare))
    }

    // An address written after a NEWLINE rather than a comma (42 of 322 events). This is the artifact
    // that matters most: every clause-splitting rule downstream knows only about commas, so unfolded,
    // the room and the room-plus-address are two different rooms.
    @Test func anAddressAfterANewlineFoldsToTheSameRoomAsTheBareSpelling() throws {
        let withNewline = try #require(try fixtureShoots().first { $0.venue.contains("\n") })
        let firstLine = String(withNewline.venue.split(separator: "\n")[0])
        #expect(VenuePlaces.canonicalKey(for: withNewline.venue)
                == VenuePlaces.canonicalKey(for: firstLine))
    }

    // The two artifacts meeting on one room, which is what a seed table is actually made of: the fixture
    // holds The Green Room 42 spelled with a newline address and spelled with a comma address, and a
    // seed table that reads those as two rooms halves the count on the room that motivated #1887.
    @Test func theTwoSpellingsOfOneRoomFoldToOneSeedKey() throws {
        let greenRoom = try fixtureShoots().filter { $0.venue.contains("Green Room 42") }
        #expect(greenRoom.count == 2, "the fixture still carries both measured spellings of the room")
        #expect(Set(greenRoom.compactMap { VenuePlaces.canonicalKey(for: $0.venue) }).count == 1)
    }

    // A sub-room folds onto the building it sits in, which is why Carnegie is ONE seed key at the top of
    // the table rather than four small ones scattered through it.
    @Test func aCarnegieSubRoomFoldsOntoCarnegie() throws {
        let weill = try #require(try fixtureShoots().first { $0.venue.contains("Weill") })
        #expect(VenuePlaces.canonicalKey(for: weill.venue)
                == VenuePlaces.canonicalKey(for: "Carnegie Hall"))
    }
}
