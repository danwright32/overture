import Testing
@testable import Overture

// #1064: a dedicated venue-normalization pass folds the formatting variance that denotes the SAME
// physical venue, so two spellings of one venue produce ONE natural key. These tests pin the six real
// duplicate shapes the live-store audit confirmed, guard against over-normalizing genuinely different
// venues together, and check the individual folds.
@Suite("Venue normalization for the natural key (#1064)")
struct VenueNormalizationTests {

    private func key(_ group: String, _ date: String, _ venue: String) -> String {
        Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: venue)
    }

    // LIVE-STORE-CLAIM verified=2026-07-28 measure="stored prospect pairs whose keys differ only by a parenthetical clause in the venue half"
    // #1686: the neighbourhood in PARENTHESES had no comma to split on, so #1498's reduction never
    // reached it and one venue stayed two. Five pairs on the live store, ten rows, and Dan sees the
    // Aug 4 sing twice. The runbook asks for the neighbourhood in `location`, and the extract model
    // obeys on some days and bakes it into `venue` on others; that variance is permanent (it is a
    // prompt, not code), so the key is what has to absorb it, exactly as it now absorbs a respelled
    // title.
    //
    // Whatever follows the venue's own name in brackets says WHERE it is or what it is ALSO CALLED,
    // never which venue it is: the live store's five are two neighbourhoods, one alternate name
    // ("(MASS MoCA)"), one street address, and one note the model wrote to itself. Every consumer of
    // this key also carries the date and the group, so dropping it cannot collide two real venues.
    @Test func aVenueWrittenWithAndWithoutAParentheticalIsOneShow() {
        // The live pairs, exactly as stored.
        #expect(key("Summer Community Sings", "2026-08-04", "St. Paul's Episcopal Church (Carroll Gardens)")
                == key("Summer Community Sings", "2026-08-04", "St. Paul's Episcopal Church"))
        #expect(key("Holiday Modulations", "2026-12-11", "The Church of St. Mary the Virgin (Times Square)")
                == key("Holiday Modulations", "2026-12-11", "The Church of St. Mary the Virgin"))
        // An alternate name in brackets, not a location, folds the same way and for the same reason.
        #expect(key("Annie Gosfield: Emma", "2026-07-31",
                    "Massachusetts Museum of Contemporary Art (MASS MoCA)")
                == key("Annie Gosfield: Emma", "2026-07-31", "Massachusetts Museum of Contemporary Art"))
        // Two genuinely different rooms are still two shows: the fold drops the bracket, not the name.
        #expect(key("G", "2026-07-01", "St. Paul's Episcopal Church (Carroll Gardens)")
                != key("G", "2026-07-01", "St. Peter's Episcopal Church"))
    }

    // The DISPLAY string is untouched, the same way #1498's comma reduction deliberately left it alone.
    // A card still reads the venue as the source wrote it, brackets and all; this fold is identity only.
    @Test func theParentheticalFoldDoesNotChangeWhatACardShows() {
        #expect(VenueNormalization.strippingEmbeddedAddress("St. Paul's Episcopal Church (Carroll Gardens)")
                == "St. Paul's Episcopal Church (Carroll Gardens)")
    }

    // The six confirmed duplicate pairs from the audit: the same show, once with a bare venue name and
    // once with the venue's own street address appended. Each pair must now produce ONE natural key.
    @Test func theSixConfirmedDuplicateShapesNowKeyAsOne() {
        let pairs: [(group: String, date: String, bare: String, withAddress: String)] = [
            ("GATA Jazz Trio", "2026-07-18",
             "The Cutting Room", "The Cutting Room, 44 East 32nd Street, New York, NY"),
            ("NorthEast Band/Sweet Melissa Band/RYT Stuff/Blindspot", "2026-07-17",
             "The Cutting Room", "The Cutting Room, 44 East 32nd Street, New York, NY"),
            ("Off the Chart", "2026-07-22",
             "The Cutting Room", "The Cutting Room, 44 East 32nd Street, New York, NY"),
            ("STEVEN MAGLIO & HIS BIG BAND ORCHESTRA", "2026-07-19",
             "The Cutting Room", "The Cutting Room, 44 East 32nd Street, New York, NY"),
            ("LOL! The Players Theatre Short Play Festival 2026", "2026-07-17",
             "The Players Theatre", "The Players Theatre, 115 MacDougal Street, New York, NY"),
            ("Love Is Live", "2026-08-01",
             "The Players Theatre", "The Players Theatre, 115 MacDougal Street, New York, NY"),
        ]
        for p in pairs {
            #expect(key(p.group, p.date, p.bare) == key(p.group, p.date, p.withAddress),
                    "\(p.group): bare and address-appended venue must key as one")
        }
    }

    // Guard against over-normalization: genuinely different venues, and different shows at one venue, must
    // still produce DIFFERENT keys.
    @Test func genuinelyDifferentVenuesStayDistinct() {
        // Two different Carnegie rooms.
        #expect(key("G", "2026-07-01", "Weill Recital Hall")
                != key("G", "2026-07-01", "Zankel Hall"))
        // A leading "St" that means Saint must NOT be expanded to "Street" (which would mangle, and could
        // collide two unrelated saints' venues).
        #expect(key("G", "2026-07-01", "St Patrick's Cathedral")
                != key("G", "2026-07-01", "Street Patrick's Cathedral"))
        // Two different streets are two different venues.
        #expect(key("G", "2026-07-01", "The Foo, 10 First Ave")
                != key("G", "2026-07-01", "The Bar, 10 First Ave"))
        // Same venue, different date: still distinct (the date half of the key is untouched).
        #expect(key("G", "2026-07-01", "The Cutting Room")
                != key("G", "2026-07-02", "The Cutting Room"))
    }

    // A comma before a two-letter state code folds away, so "Chatham, NJ" and "Chatham NJ" agree, while a
    // bare venue name (no city at all) is deliberately left distinct rather than have its city guessed.
    @Test func aCommaBeforeAStateCodeFoldsAway() {
        let comma = key("Chatham UMC Concert", "2026-09-01",
                        "Chatham United Methodist Church, Chatham, NJ")
        let noComma = key("Chatham UMC Concert", "2026-09-01",
                          "Chatham United Methodist Church, Chatham NJ")
        #expect(comma == noComma)
    }

    // LIVE-STORE-CLAIM verified=2026-07-25 measure="shows fragmented into extra queue rows by a venue spelling variant"
    // #1498: the same venue written with and without its trailing location or parent building is ONE
    // venue, and until now was two shows. Measured on the live store 2026-07-25: 34 shows had fragmented
    // into 71 queue rows, "Jalopy Theatre" and "Jalopy Theatre, Red Hook, Brooklyn, NY" among them, so
    // Dan was triaging the same night more than once. #1064 deliberately kept the trailing city on the
    // grounds that dropping it could merge two same-named venues in different towns, and noted the audit
    // had seen no collisions; that premise is what changed. The risk it named cannot bite here anyway,
    // because the key also carries the group and the date, so two different churches would only merge if
    // the same group played the same night in both towns.
    @Test func oneVenueWrittenWithAndWithoutItsLocationIsOneShow() {
        // The live case, exactly as stored.
        #expect(key("Bruce Molsky & Darol Anger", "2026-07-25", "Jalopy Theatre")
                == key("Bruce Molsky & Darol Anger", "2026-07-25", "Jalopy Theatre, Red Hook, Brooklyn, NY"))
        // A parent building, not a city, folds the same way.
        #expect(key("G", "2026-07-01", "Weill Recital Hall")
                == key("G", "2026-07-01", "Weill Recital Hall, Carnegie Hall"))
        // And a street address, which already folded, still does.
        #expect(key("G", "2026-07-01", "The Cutting Room")
                == key("G", "2026-07-01", "The Cutting Room, 44 East 32nd Street, New York, NY"))
    }

    // The other half of that change: it must not start merging genuinely different rooms, which is the
    // risk #1064 was protecting against. Two different rooms in one building keep different first names,
    // so they stay apart.
    @Test func twoRoomsInOneBuildingStillDoNotMerge() {
        #expect(key("G", "2026-07-01", "Weill Recital Hall, Carnegie Hall")
                != key("G", "2026-07-01", "Zankel Hall, Carnegie Hall"))
        #expect(key("G", "2026-07-01", "Stern Auditorium / Perelman Stage, Carnegie Hall")
                != key("G", "2026-07-01", "Weill Recital Hall, Carnegie Hall"))
    }

    // The display path must NOT lose the parent building: `strippingEmbeddedAddress` is shared with
    // VenueDisplay, so the key-only reduction has to happen somewhere else. A card still reads
    // "Weill Recital Hall, Carnegie Hall".
    @Test func theDisplayPathKeepsTheParentBuilding() {
        #expect(VenueNormalization.strippingEmbeddedAddress("Weill Recital Hall, Carnegie Hall")
                == "Weill Recital Hall, Carnegie Hall")
        // It still drops a street address, which is what it was for.
        #expect(VenueNormalization.strippingEmbeddedAddress("The Cutting Room, 44 East 32nd Street, New York, NY")
                == "The Cutting Room")
    }

    // A trailing street-suffix abbreviation folds to its full word, so "65th St" and "65th Street" agree.
    @Test func aTrailingStreetSuffixAbbreviationFolds() {
        #expect(key("G", "2026-07-01", "Holy Trinity Church at 65th St")
                == key("G", "2026-07-01", "Holy Trinity Church at 65th Street"))
        #expect(key("G", "2026-07-01", "The Hall on Fifth Ave")
                == key("G", "2026-07-01", "The Hall on Fifth Avenue"))
    }

    // Spacing around a slash folds to one form.
    @Test func slashSpacingFolds() {
        #expect(key("G", "2026-07-01", "Stern Auditorium/Perelman Stage")
                == key("G", "2026-07-01", "Stern Auditorium / Perelman Stage"))
    }

    // fold and normalizeForKey preserve case (the display path relies on that) and are stable / idempotent.
    @Test func foldIsCasePreservingAndIdempotent() {
        let once = VenueNormalization.fold("Stern Auditorium/Perelman Stage")
        #expect(once == "Stern Auditorium / Perelman Stage")
        #expect(VenueNormalization.fold(once) == once)   // idempotent
        let forKey = VenueNormalization.normalizeForKey("The Cutting Room, 44 East 32nd Street, New York, NY")
        #expect(forKey == "The Cutting Room")
    }
}
