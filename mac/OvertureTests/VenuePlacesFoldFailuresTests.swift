import Testing
import Foundation

// #2451 (Prospector P0.2): the four fold failures P0.1 measured, fixed in the file that already owns
// venue identity.
//
// Every spelling below is MEASURED, copied out of Dan's real Shoots export on 2026-08-10 with the shoot
// count it carries there, never invented to make a rule fire. A fixture shaped so the rule under test
// fires makes a test appear to cover a case that cannot occur, and then passes forever while protecting
// nothing (L48). The counts are in the comments as provenance; nothing here pins one, because a pinned
// count stays green while the thing it stands for moves (L63).
//
// SEEN RED FIRST, each by reverting exactly the line that fixes it:
//   - remove `" @ "` from `VenuePlaces.roomSeparators` and the `@` spelling of Merkin splits off again;
//   - remove `"merkin concert hall"` from the table, or the address-prefix arm from `candidates`, and
//     the run-on address spelling splits off again;
//   - remove `"stern auditorium"` from the table and the bare clause loses its Carnegie parent;
//   - remove `"milbank chapel"` and the chapel is two rooms again;
//   - remove `"david geffin hall"` and the misspelling is its own room.
@Suite("The four measured fold failures (#2451)")
struct VenuePlacesFoldFailuresTests {

    // MARK: - 1. Merkin split three ways, with its own building beside it as a fourth

    // The four spellings the export holds, and what each carried on 2026-08-10:
    //   "Merkin Hall, 129 W 67th St"                                    1
    //   "Merkin Hall at Kaufman Music Center\n129 west 67th street"     2
    //   "Merkin Hall @ Kaufman Music Center (129 west 67th street)"     1
    //   "Merkin Concert Hall 129 W. 67th St."                           2
    //   "Kaufman Music Center, 129 W 67th St, New York, NY 10023"       1
    //   "Kaufman Music Center, 29 W 67th St, New York, NY 10023"        2
    static let merkinSpellings = [
        "Merkin Hall, 129 W 67th St",
        "Merkin Hall at Kaufman Music Center\n129 west 67th street",
        "Merkin Hall @ Kaufman Music Center (129 west 67th street)",
        "Merkin Concert Hall 129 W. 67th St.",
        "Kaufman Music Center, 129 W 67th St, New York, NY 10023",
        "Kaufman Music Center, 29 W 67th St, New York, NY 10023",
    ]

    @Test("every measured Merkin and Kaufman spelling is one room")
    func merkinAndKaufmanAreOneRoom() {
        let keys = Set(Self.merkinSpellings.compactMap { VenuePlaces.canonicalKey(for: $0) })
        #expect(keys.count == 1, "Merkin still splits: \(keys.sorted())")
        #expect(keys.first == VenuePlaces.canonicalKey(for: "Kaufman Music Center"),
                "the room folds onto something other than the building that runs it")
    }

    // The `@` on its own, so a regression in the separator list names itself rather than arriving as
    // "Merkin split again".
    @Test("an at-sign separates a room from its building exactly as the word does")
    func anAtSignSeparatesARoomFromItsBuilding() {
        #expect(VenuePlaces.canonicalKey(for: "Merkin Hall @ Kaufman Music Center")
                == VenuePlaces.canonicalKey(for: "Merkin Hall at Kaufman Music Center"))
    }

    // And the run-on address on its own. This is the spelling no clause rule could reach: no comma, no
    // newline, so `sourceCleaned` had nothing to rewrite and the whole string became a room.
    @Test("a street address run straight on with no comma is not part of the room's name")
    func aRunOnStreetAddressIsNotPartOfTheName() {
        #expect(VenuePlaces.canonicalKey(for: "Merkin Concert Hall 129 W. 67th St.")
                == VenuePlaces.canonicalKey(for: "Merkin Concert Hall"))
    }

    // The narrowness that arm needs, and the reason it is not "a leading digit": three real rooms carry
    // a number in their own names and must keep it.
    @Test("a room whose own name carries a number keeps it", arguments: [
        "54 Below", "48 Lounge", "Theatre 71", "The Green Room 42", "92nd Street Y",
    ])
    func aRoomNamedWithANumberKeepsIt(_ name: String) {
        let folded = VenuePlaces.canonicalKey(for: name) ?? ""
        #expect(folded.contains(where: { $0.isNumber }),
                "\(name) lost the number that is part of its name: \(folded)")
    }

    // MARK: - 2. Stern Auditorium missing its Carnegie parent

    // "Stern Auditorium, 161 West 56th Street"       7
    // "Stern Auditorium, Carnegie Hall"              1
    // "stern auditorium/Perelman stage, Carnegie hall"  1
    @Test("every measured Stern spelling folds onto Carnegie", arguments: [
        "Stern Auditorium, 161 West 56th Street",
        "Stern Auditorium, Carnegie Hall",
        "stern auditorium/Perelman stage, Carnegie hall",
        "Stern Auditorium",
    ])
    func sternFoldsOntoCarnegie(_ spelling: String) {
        #expect(VenuePlaces.canonicalKey(for: spelling)
                == VenuePlaces.canonicalKey(for: "Carnegie Hall"))
    }

    // MARK: - 3. Milbank Chapel as two rooms, neither of them known

    // "Milbank Chapel"                                                              1
    // "Milbank Chapel  (525 W. 120th, TC, Columbia., New York, NY 10029)"           1
    // "Milbank Chapel, 525 W. 120th, New York, NY 10027 on"                         1
    // "Milbank Chapel at Teachers College, 525 West 120th Street, New York, NY 10027"  1
    static let milbankSpellings = [
        "Milbank Chapel",
        "Milbank Chapel  (525 W. 120th, TC, Columbia., New York, NY 10029)",
        "Milbank Chapel, 525 W. 120th, New York, NY 10027 on",
        "Milbank Chapel at Teachers College, 525 West 120th Street, New York, NY 10027",
    ]

    @Test("every measured Milbank spelling is one room")
    func milbankIsOneRoom() {
        let keys = Set(Self.milbankSpellings.compactMap { VenuePlaces.canonicalKey(for: $0) })
        #expect(keys.count == 1, "Milbank still splits: \(keys.sorted())")
    }

    // The chapel is now a room the table knows, which is what puts it inside the geography gate rather
    // than only inside the seed table.
    @Test("Milbank Chapel is placed as well as folded")
    func milbankIsPlaced() {
        #expect(VenuePlaces.location(for: "Milbank Chapel at Teachers College") == "New York, NY")
    }

    // MARK: - 4. A typo variant standing as its own room

    // "David Geffen Hall"                                             1
    // "David Geffen Hall\n10 Lincoln Center Plz\nNew York NY 10023"   4 (and 1 with a country line)
    // "David Geffin Hall, 161 West 56th Street"                       2
    static let geffenSpellings = [
        "David Geffen Hall",
        "David Geffen Hall\n10 Lincoln Center Plz\nNew York NY 10023",
        "David Geffen Hall\n10 Lincoln Center Plz\nNew York NY 10023\nUnited States",
        "David Geffin Hall, 161 West 56th Street",
        "Wu Tsai Theater",
    ]

    @Test("the misspelling and the hall's own rooms are one room")
    func geffenSpellingsAreOneRoom() {
        let keys = Set(Self.geffenSpellings.compactMap { VenuePlaces.canonicalKey(for: $0) })
        #expect(keys.count == 1, "David Geffen Hall still splits: \(keys.sorted())")
    }

    // MARK: - What must NOT have moved

    // Adding table rows and candidate arms can only ever add lookups, and the first hit wins, so no room
    // that already resolved may resolve anywhere else. These are the rooms nearest the change: the
    // building Merkin now folds into is not Lincoln Center's, and Carnegie's other halls are untouched.
    @Test("rooms next to the change keep the identity they had", arguments: [
        ("Weill Recital Hall", "Carnegie Hall"),
        ("Zankel Hall", "Carnegie Hall"),
        ("Carnegie Hall, 161 West 56th Street", "Carnegie Hall"),
        ("Jalopy's Classroom", "Jalopy Theatre"),
        ("The Green Room 42", "Green Room 42"),
    ])
    func neighbouringRoomsKeepTheirIdentity(_ spelling: String, _ expectedSameAs: String) {
        #expect(VenuePlaces.canonicalKey(for: spelling)
                == VenuePlaces.canonicalKey(for: expectedSameAs))
    }

    // Lincoln Center stays its own room. David Geffen Hall sits inside it, and giving it that parent
    // would have merged seven more shoots on a judgment #2451 was not asked to make.
    @Test("Lincoln Center and David Geffen Hall are still two rooms")
    func lincolnCentreIsNotSweptIn() {
        #expect(VenuePlaces.canonicalKey(for: "Lincoln Center")
                != VenuePlaces.canonicalKey(for: "David Geffen Hall"))
    }
}
