import Testing
@testable import Overture

// #970 Phase 2. Every string in these tests is VERBATIM from a real page. That is deliberate: the
// first version of this feature was designed against reasoning rather than data, and its parser fired
// on zero rows of the real target. See #979.

@Suite("Event place: reading a location string")
struct EventPlaceReadingTests {
    // The shape the target pages actually use, from smokeringquartet.com/gigs.
    @Test func readsCityAndStateCode() {
        #expect(EventPlace.resolve(location: "New York, NY", discipline: .theater).verdict == .inRange)
        #expect(EventPlace.resolve(location: "Louisville, KY", discipline: .theater).verdict == .outOfRange)
    }

    // "Baltimore, Maryland" spells the state out. A resolver that only knows two-letter codes reads
    // this as unknown and keeps a Maryland show forever.
    @Test func readsASpelledOutStateName() {
        #expect(EventPlace.resolve(location: "Baltimore, Maryland", discipline: .theater).verdict == .outOfRange)
        #expect(EventPlace.resolve(location: "Yonkers, New York", discipline: .theater).verdict == .inRange)
    }

    // Dan's rule: the loose disciplines take anything in NY, NJ or CT.
    @Test func theLooseRuleTakesTheThreeStates() {
        for l in ["Newark, NJ", "Stamford, CT", "White Plains, NY"] {
            #expect(EventPlace.resolve(location: l, discipline: .theater).verdict == .inRange, "\(l)")
        }
    }

    // A country that is not the US is out of range, whatever the town.
    @Test func readsACityAndCountry() {
        #expect(EventPlace.resolve(location: "Harrogate, UK", discipline: .theater).verdict == .outOfRange)
        #expect(EventPlace.resolve(location: "Berlin Germany", discipline: .theater).verdict == .outOfRange)
    }

    // A bare city with no state or country, verbatim from rainercrosett.com/schedule. It LOOKS obviously
    // European and it must still be UNKNOWN, because Amsterdam, New York is a real town in Montgomery
    // County. The resolver cannot tell them apart, and Dan's spec is explicit that it must not guess:
    // an unknown place is kept and flagged, and a confident wrong place is the only failure that hides
    // a real show. Reading "obviously Dutch" here is exactly the reasoning-instead-of-evidence that
    // cost this feature its first plan.
    @Test func aBareCityThatCouldBeEitherIsUnknown() {
        #expect(EventPlace.resolve(location: "Amsterdam", discipline: .theater).verdict == .unknown)
    }

    // A region is not a city and names no state. It must NOT read as unknown-and-kept: "southern
    // Norway" is plainly not somewhere Dan is shooting, and treating it as unknown would flood the
    // queue with exactly the touring dates #970 exists to remove.
    @Test func readsARegionThatIsPlainlyNotHere() {
        #expect(EventPlace.resolve(location: "southern Norway", discipline: .theater).verdict == .outOfRange)
    }

    // A full street address, verbatim from a real listing. The state and country are in there.
    @Test func readsAStreetAddress() {
        #expect(EventPlace.resolve(
            location: "26 Thorwaldsenstraße Berlin, BE, 12157 Germany", discipline: .theater).verdict == .outOfRange)
        #expect(EventPlace.resolve(
            location: "11 Lange Begijnestraat Haarlem, NH, 2011 HH Netherlands", discipline: .theater).verdict == .outOfRange)
    }

    // A comma-joined LIST of cities, verbatim. A person reads this as obviously California; the
    // resolver cannot, without a database of every US city name, and it names no state. So it is
    // UNKNOWN and kept. That is the design working, not a gap: Dan sees one flagged row, and if he
    // never wants it again the exclude list is how he says so. The important half of this test is
    // the NEGATIVE: a naive comma-split would read "Orange County" as a city and "Santa Barbara" as
    // its state code, and must not.
    @Test func aListOfCitiesIsNotMisreadAsCityAndState() {
        let r = EventPlace.resolve(
            location: "Orange County, Santa Barbara, Pasadena, and Santa Monica", discipline: .theater)
        #expect(r.verdict == .unknown)
        #expect(r.reason == .couldNotPlace)
    }
}

@Suite("Event place: the discipline split")
struct EventPlaceDisciplineTests {
    // Dan's rule: music (and band) stop at the five boroughs. He will not travel for a band or choir.
    @Test func musicStopsAtTheFiveBoroughs() {
        for l in ["Brooklyn, NY", "Staten Island, NY", "Bronx, NY", "Queens, NY", "New York, NY"] {
            #expect(EventPlace.resolve(location: l, discipline: .music).verdict == .inRange, "\(l)")
        }
        // Real sources: Larchmont Music Academy (Westchester) and The Masterwork Chorus (NJ).
        #expect(EventPlace.resolve(location: "Larchmont, NY", discipline: .music).verdict == .outOfRange)
        #expect(EventPlace.resolve(location: "Morristown, NJ", discipline: .music).verdict == .outOfRange)
        #expect(EventPlace.resolve(location: "Larchmont, NY", discipline: .band).verdict == .outOfRange)
    }

    // The same towns, for a discipline Dan WILL travel for. This is the whole point of the split, and
    // it has never been exercised on a real row: every hideable row today is genuinely music.
    @Test func theatreAndDanceTravelWhereMusicDoesNot() {
        for d in [Discipline.theater, .dance, .opera, .comedy, .other] {
            #expect(EventPlace.resolve(location: "Larchmont, NY", discipline: d).verdict == .inRange, "\(d)")
        }
    }

    // #980 made `.other` reachable and Dan ruled it takes the LOOSE rule, so an unreadable title is
    // erred toward showing rather than hiding.
    @Test func anUnreadDisciplineTakesTheLooseRule() {
        #expect(EventPlace.resolve(location: "Newark, NJ", discipline: .other).verdict == .inRange)
    }
}

@Suite("Event place: the exclude list")
struct EventPlaceExcludeTests {
    // Dan's design: start permissive at NY/NJ/CT, and let a refusal narrow it. The list is pre-seeded
    // with places that are in-state but plainly not an hour away.
    @Test func aSeededFarTownIsOutOfRangeEvenInState() {
        for l in ["Buffalo, NY", "Albany, NY", "Rochester, NY", "Syracuse, NY", "Montauk, NY"] {
            #expect(EventPlace.resolve(location: l, discipline: .theater).verdict == .outOfRange, "\(l)")
        }
    }

    // The list is the ONLY thing that narrows the loose rule, and it is town-level, not state-level.
    // Excluding Buffalo must not take the rest of New York with it.
    @Test func excludingATownDoesNotExcludeItsState() {
        #expect(EventPlace.resolve(location: "Buffalo, NY", discipline: .theater).verdict == .outOfRange)
        #expect(EventPlace.resolve(location: "Yonkers, NY", discipline: .theater).verdict == .inRange)
    }

    // "Never show me this town again" reads as absolute, so it holds for every discipline rather than
    // only the one Dan happened to be looking at.
    @Test func anExcludedTownIsExcludedForEveryDiscipline() {
        for d in [Discipline.theater, .dance, .opera, .music, .band, .comedy, .other] {
            #expect(EventPlace.resolve(location: "Buffalo, NY", discipline: d).verdict == .outOfRange, "\(d)")
        }
    }
}

@Suite("Event place: what it refuses to decide")
struct EventPlaceUnknownTests {
    // Dan's spec #5: unknown KEEPS and flags, always. A show whose page named no place is not hidden.
    @Test func noLocationIsUnknownNotOutOfRange() {
        #expect(EventPlace.resolve(location: nil, discipline: .theater).verdict == .unknown)
        #expect(EventPlace.resolve(location: "", discipline: .theater).verdict == .unknown)
        #expect(EventPlace.resolve(location: "   ", discipline: .theater).verdict == .unknown)
    }

    // A real row: "Carnegie Hall Debut Recital" on rainercrosett.com/schedule names a venue and no
    // city. It is the one show on that page Dan wants, and it survives because unknown keeps.
    @Test func aPageThatNamesNoPlaceKeepsItsShow() {
        #expect(EventPlace.resolve(location: nil, discipline: .music).verdict == .unknown)
    }

    // A string the resolver cannot place must be unknown, NEVER out of range. Guessing wrong here is
    // the only failure that HIDES a real show, which is the one thing the runbook and Dan's spec both
    // say must not happen.
    @Test func anUnplaceableStringIsUnknown() {
        for l in ["Info coming soon", "TBD", "the usual spot", "Zzyzx"] {
            #expect(EventPlace.resolve(location: l, discipline: .theater).verdict == .unknown, "\(l)")
        }
    }

    // Provenance survives, so the UI can tell Dan WHY a show was placed, and so a wrong hide is
    // traceable to the rule that made it rather than being a bare verdict.
    @Test func theVerdictSaysWhy() {
        #expect(EventPlace.resolve(location: "Buffalo, NY", discipline: .theater).reason == .excludedTown)
        #expect(EventPlace.resolve(location: "Larchmont, NY", discipline: .music).reason == .outsideTheBoroughs)
        #expect(EventPlace.resolve(location: "Harrogate, UK", discipline: .theater).reason == .outsideTheRegion)
        #expect(EventPlace.resolve(location: "Zzyzx", discipline: .theater).reason == .couldNotPlace)
    }
}

// #1744. A borough named as part of a larger phrase is still that borough. Until this, the boroughs
// were matched by EXACT token equality, which was safe while `location` only ever arrived as the
// page's own words. #1744 fills the gap from the venue instead, and the live store's own venue text
// includes "downtown Brooklyn, NY", so exact matching would have read a Red Hook folk festival as
// music outside the five boroughs and hidden it. That is the confident wrong place this whole area
// exists to avoid, and this change closes it in the one predicate both callers share.
@Suite("Event place: a borough inside a longer phrase (#1744)")
struct EventPlaceBoroughPhraseTests {

    // The live-store string. As music (Dan's boroughs-only rule) it has to stay.
    @Test func aBoroughInsideALongerPhraseIsStillThatBorough() {
        let r = EventPlace.resolve(location: "downtown Brooklyn, NY", discipline: .music)
        #expect(r.verdict == .inRange)
        #expect(r.reason == .insideTheBoroughs)
    }

    // The same widening must not offer Dan a refusal for a borough he lives on. "Never show me shows
    // in downtown Brooklyn" would quietly cut real work, so the offer is withheld exactly as it is for
    // the bare borough name.
    @Test func noTownRefusalIsOfferedForAPhraseNamingABorough() {
        #expect(EventPlace.excludableTown(from: "downtown Brooklyn, NY") == nil)
        #expect(EventPlace.excludableTown(from: "Brooklyn, NY") == nil)
    }

    // THE LIMIT. A borough name has to appear as a WORD, not as a fragment inside another word, and a
    // town that merely ends in a borough's name is a different town. Both of these are still refused.
    @Test func aFragmentInsideAWordIsNotABorough() {
        #expect(EventPlace.resolve(location: "Brooklynville, NY", discipline: .music).verdict == .outOfRange)
        #expect(EventPlace.excludableTown(from: "Brooklynville, NY") == "Brooklynville")
    }

    // And the state still governs: a Brooklyn outside New York is not one of Dan's boroughs.
    @Test func aBoroughNameInAnotherStateIsNotABorough() {
        #expect(EventPlace.resolve(location: "Brooklyn, OH", discipline: .music).verdict == .outOfRange)
    }
}

// #1656. The two shows that issue names, by the string the live store actually holds for each.
//
// LIVE-STORE-CLAIM verified=2026-07-29 measure="untriaged music shows whose stored location is the phrase New York City"
// Both are status `new`, both stored `music`, both Manhattan, both upcoming, and both carry the location
// `New York City` verbatim: "Handel Messiah 2026" on 2026-12-23 and the "KYHS Music Competition Winners'
// Concert" on 2026-12-05. Music is the only discipline that stays inside the five boroughs, so music is
// the only genre that can lose a show this way, and these two were being taken off the queue entirely.
//
// They come back with NO RE-SCOUT. The gate resolves the stored location string every time the queue is
// built, so nothing about the rows themselves has to change: the phrase is simply read correctly now.
@Suite("New York City is the five boroughs (#1656)")
struct NewYorkCityIsTheBoroughsTests {

    @Test func theTwoLiveShowsAreInsideTheBoroughs() {
        for show in ["Handel Messiah 2026", "KYHS Music Competition Winners' Concert"] {
            let r = EventPlace.resolve(location: "New York City", discipline: .music)
            #expect(r.verdict == .inRange, "\(show)")
            #expect(r.reason == .insideTheBoroughs, "\(show)")
        }
    }

    // The complaint was not about a verdict in the abstract: the shows were GONE from the queue. This is
    // the predicate every queue surface goes through (#1570), asserted at that level.
    @Test func neitherShowIsHiddenFromTheQueue() {
        #expect(GeoRefusals.none.hidesFromQueue(location: "New York City", discipline: .music) == false)
    }

    // The other whole-borough phrasings a page can write, which must read the same way.
    @Test func theOtherWholeBoroughPhrasingsReadTheSameWay() {
        for phrase in ["New York City, NY", "New York City, New York", "Manhattan, New York City"] {
            #expect(EventPlace.resolve(location: phrase, discipline: .music).verdict == .inRange, "\(phrase)")
        }
    }

    // THE LIMIT, and the reason the state match had to be tightened to fix this issue at all.
    //
    // "New York Mills, MN" is a real Minnesota town, and it has a regional cultural centre, so a touring
    // page can genuinely name it. Its own state is right there in the string, and it must win over the
    // "New York" sitting inside the town's name. A borough phrase only decides the state when NOTHING
    // else names one.
    @Test func aTownWhoseNameContainsNewYorkStaysInItsOwnState() {
        let r = EventPlace.resolve(location: "New York Mills, MN", discipline: .music)
        #expect(r.verdict == .outOfRange)
        #expect(r.reason == .outsideTheRegion)
        // And the two readers agree about it, which they did not before: the gate places it out of the
        // region, and the town refusal is correctly withheld because the state already excludes it.
        #expect(EventPlace.excludableTown(from: "New York Mills, MN") == nil)
    }

    // The same flaw, on the string that shows it is not a one-off: a state name inside a longer town name
    // was beating the town's actual state code. Both readings are out of range, so nothing was visibly
    // wrong, which is why it sat there.
    @Test func aCityNamedAfterAnotherStateStaysInItsOwnState() {
        #expect(EventPlace.resolve(location: "Kansas City, MO", discipline: .theater).reason
                == .outsideTheRegion)
    }
}
