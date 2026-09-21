import Testing
import Foundation
import SwiftData

// #4067: a human verdict about a pair of rows must survive the thing this milestone does to rows.
//
// Both live-store sweeps (`TwoShowsOneTitleOneNightTests`, `SameVenueOneNightSweepTests`) hold a set of
// pairs somebody read by eye and settled. Both keyed those verdicts on `Prospect.naturalKey` until now,
// and that key is what every re-key arm and three launch passes rewrite. The failure is silent and
// arrives as a sweep naming a pair as UNJUDGED, which invites either re-judging work already done or
// deleting the entry as residue, throwing the judgement away rather than the key.
@MainActor
@Suite("A settled verdict survives a re-key (#4067)")
struct JudgedPairTests {

    private func container() throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func row(_ ctx: ModelContext, _ title: String, venue: String, opens: String,
                     night: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title, performanceDate: opens,
                                                             venue: venue),
                         groupName: title, discipline: "theater", venue: venue,
                         performanceDate: opens, sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "unknown",
                         coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: nil, partOfRelatedRun: false, runSourceURLs: [],
                         runNights: [night ?? opens])
        ctx.insert(p)
        return p
    }

    // THE CLAIM, and it is the test #4067 says fails today. A pair is judged; a pass then re-keys one of
    // its rows the way `NaturalKeyVenueMigration` does at launch, on the venue axis these very pairs
    // differ on; the verdict must still match.
    @Test func aVerdictStillMatchesAfterOneRowIsReKeyed() throws {
        let ctx = ModelContext(try container())
        let building = row(ctx, "Orbit", venue: "Abrons Arts Center", opens: "2026-08-09")
        let room = row(ctx, "Orbit", venue: "Experimental Theater at Abrons Arts Center",
                       opens: "2026-08-09")
        let verdict = JudgedPair.of(building, room, night: "2026-08-09")

        // What a re-key does: a new natural key on the stored row, the card's own fields untouched.
        let keyBefore = room.naturalKey
        room.naturalKey = Prospect.makeNaturalKey(groupName: "Orbit", performanceDate: "2026-08-10",
                                                  venue: "Abrons Arts Center")
        #expect(room.naturalKey != keyBefore, "the fixture did not actually re-key anything (L159)")

        #expect(JudgedPair.of(building, room, night: "2026-08-09") == verdict,
                """
                the verdict stopped matching because a row was re-keyed, so a settled pair comes back \
                as unjudged and the judgement is the thing at risk of being deleted
                """)
    }

    // The property that makes it a verdict about a PAIR rather than about an ordered one.
    //
    // The titles here fold DIFFERENTLY on purpose, and the first version of this test did not. It used
    // `MacMccarty +KiddTwist` against `MacMccarty + KiddTwist`, which are two different strings in the
    // store and fold to ONE today, so the test passed whichever title the key was built from and
    // `scripts/mutate.sh` reported SURVIVED when the second title was dropped from the key entirely. The
    // judged pair in `SameVenueOneNightSweepTests` that this property exists for is the subtitle one, so
    // that is the shape asserted here (L159, L104).
    @Test func thePairIsTheSameVerdictReadInEitherOrder() throws {
        let ctx = ModelContext(try container())
        let short = row(ctx, "Kinstillatory Mappings in Light and Dark Matter", venue: "Abrons Arts Center",
                        opens: "2026-09-17")
        let long = row(ctx, "Kinstillatory Mappings in Light and Dark Matter (Emily Johnson and Kai Recollet)",
                       venue: "Abrons Arts Center", opens: "2026-09-17")
        #expect(JudgedPair.of(short, long, night: "2026-09-17")
                == JudgedPair.of(long, short, night: "2026-09-17"),
                """
                the same two rows judged in the other order are a different verdict, so half the \
                entries in a sweep's list would match and half would not
                """)
    }

    // And the property that stops it being a verdict about everything: two genuinely different pairs
    // must not collapse onto one entry, or one judgement would silently settle a pair nobody looked at.
    @Test func twoDifferentPairsAreTwoVerdicts() throws {
        let ctx = ModelContext(try container())
        let a1 = row(ctx, "Orbit", venue: "Abrons Arts Center", opens: "2026-08-09")
        let a2 = row(ctx, "Orbit", venue: "Experimental Theater at Abrons Arts Center", opens: "2026-08-09")
        let b1 = row(ctx, "Orbit", venue: "Abrons Arts Center", opens: "2026-08-16")
        let b2 = row(ctx, "Orbit", venue: "Experimental Theater at Abrons Arts Center", opens: "2026-08-16")
        #expect(JudgedPair.of(a1, a2, night: "2026-08-09") != JudgedPair.of(b1, b2, night: "2026-08-16"),
                "one night's verdict also settled another night's pair")

        let other = row(ctx, "Silsila", venue: "Abrons Arts Center", opens: "2026-08-09")
        #expect(JudgedPair.of(a1, a2, night: "2026-08-09") != JudgedPair.of(a1, other, night: "2026-08-09"),
                "a verdict about one pair also settled a different show at the same venue and night")
    }

    // The venue fold is part of the key, so the two spellings of one room that these verdicts are ABOUT
    // do not make two verdicts. This is what makes the key survive `NaturalKeyVenueMigration`.
    @Test func twoSpellingsOfOneRoomAreOneVerdict() throws {
        let ctx = ModelContext(try container())
        let plain = row(ctx, "Orbit", venue: "Jalopy Theatre", opens: "2026-08-09")
        let withAddress = row(ctx, "Orbit", venue: "Jalopy Theatre, Red Hook, Brooklyn, NY",
                              opens: "2026-08-09")
        let bare = row(ctx, "Orbit", venue: "Jalopy Theatre", opens: "2026-08-09")
        #expect(JudgedPair.of(plain, withAddress, night: "2026-08-09")
                == JudgedPair.of(plain, bare, night: "2026-08-09"),
                "the venue fold is not being applied, so a re-spelled room reads as a new pair")
    }
}
