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
