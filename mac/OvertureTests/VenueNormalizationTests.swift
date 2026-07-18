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
