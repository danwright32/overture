import Testing
@testable import Overture

@Suite("Natural key canonicalization")
struct NaturalKeyTests {
    @Test func decodesHtmlEntitiesSoScrapedAndCleanNamesAgree() {
        // Scout output may carry raw entities (issue #25); a later run that fetched
        // the org's real site sees the decoded form. Both must produce one key.
        let scraped = Prospect.makeNaturalKey(
            groupName: "Susan &amp; the Choir", performanceDate: "2026-07-01", venue: "Weill Recital Hall")
        let clean = Prospect.makeNaturalKey(
            groupName: "Susan & the Choir", performanceDate: "2026-07-01", venue: "Weill Recital Hall")
        #expect(scraped == clean)
    }

    @Test func decodesNumericEntities() {
        let a = Prospect.makeNaturalKey(groupName: "Caf&#233; Quartet", performanceDate: "2026-07-01", venue: nil)
        let b = Prospect.makeNaturalKey(groupName: "Café Quartet", performanceDate: "2026-07-01", venue: nil)
        #expect(a == b)
    }

    @Test func normalizesUnicodeComposition() {
        // "é" as one codepoint vs "e" + combining accent must canonicalize identically.
        let composed = Prospect.makeNaturalKey(groupName: "Pli\u{00E9} Dance", performanceDate: "2026-07-01", venue: nil)
        let decomposed = Prospect.makeNaturalKey(groupName: "Plie\u{0301} Dance", performanceDate: "2026-07-01", venue: nil)
        #expect(composed == decomposed)
    }

    @Test func collapsesNonBreakingAndEnDashWhitespaceConsistently() {
        let nbsp = Prospect.makeNaturalKey(groupName: "The\u{00A0}Choir", performanceDate: "2026-07-01", venue: nil)
        let plain = Prospect.makeNaturalKey(groupName: "The Choir", performanceDate: "2026-07-01", venue: nil)
        #expect(nbsp == plain)
    }

    @Test func stillLowercasesAndJoins() {
        let k = Prospect.makeNaturalKey(groupName: "DCINY", performanceDate: "2026-07-01", venue: "Stern")
        #expect(k == "dciny|2026-07-01|stern")
    }
}

// #1590: the venue half of this key folds formatting variance (#1064/#1498); the TITLE half never did,
// so a source that respells one show's title minted a whole second card for the same night.
// LIVE-STORE-CLAIM verified=2026-07-27 measure="new dated prospects; date+venueKey buckets holding >1 row; groups whose titles differ only by punctuation/accent/case"
// Measured on
// the live store 2026-07-27: 571 new dated shows, 88 date-and-venue buckets holding more than one row,
// and 10 of those groups were one show whose two titles differ ONLY by punctuation, accent, or case.
// Every pair below is a real pair of stored rows, quoted from that measurement.
@Suite("Natural key title fold (#1590)")
struct NaturalKeyTitleFoldTests {
    private func keys(_ a: String, _ b: String, date: String, venue: String) -> (String, String) {
        (Prospect.makeNaturalKey(groupName: a, performanceDate: date, venue: venue),
         Prospect.makeNaturalKey(groupName: b, performanceDate: date, venue: venue))
    }

    @Test func foldsAnAccentTheOtherSpellingDropped() {
        // #330 vs #756, 54 Below, 2026-07-28.
        let (a, b) = keys("Stevie Holland: A Summer Soiree Celebrating \"Talk to Your Tomatoes\"",
                          "Stevie Holland: A Summer Soirée Celebrating \"Talk to Your Tomatoes\"",
                          date: "2026-07-28", venue: "54 Below")
        #expect(a == b)
    }

    @Test func foldsThreeDotsAgainstASingleEllipsisCharacter() {
        // #322 vs #755, 54 Below, 2026-07-31. The same near-miss class the venue fold already handles.
        let (a, b) = keys("Christine Andreas: S'Wonderful...", "Christine Andreas: S'Wonderful\u{2026}",
                          date: "2026-07-31", venue: "54 Below")
        #expect(a == b)
    }

    @Test func foldsAnEmDashAgainstAHyphen() {
        // #327 vs #754, 54 Below, 2026-07-30.
        let (a, b) = keys("Coming Out - An Evening of New Queer Musicals by Allison St. Rock",
                          "Coming Out \u{2014} An Evening of New Queer Musicals by Allison St. Rock",
                          date: "2026-07-30", venue: "54 Below")
        #expect(a == b)
    }

    @Test func foldsBracketsAgainstAnExclamationMark() {
        // #338 vs #585, Jalopy Theatre, 2026-07-29. The open mic Dan was dismissing several times a night.
        let (a, b) = keys("Jalopy Open Mic Every Wednesday!", "Jalopy Open Mic (Every Wednesday)",
                          date: "2026-07-29", venue: "Jalopy Theatre")
        #expect(a == b)
    }

    @Test func foldsAStrayComma() {
        // #571 vs #685, Jalopy Theatre, 2026-08-08.
        let (a, b) = keys("A Square Dance with the J.T. Roundup Stringband, called by Sargent Seedoo",
                          "A Square Dance with the J.T. Roundup Stringband called by Sargent Seedoo",
                          date: "2026-08-08", venue: "Jalopy Theatre")
        #expect(a == b)
    }

    @Test func foldsTheVenueSpellingAndTheTitleSpellingTogether() {
        // The live pairs carry BOTH kinds of variance at once: the bare venue on one row, the venue with
        // its street address on the other, plus a respelled title. One key has to survive both.
        let a = Prospect.makeNaturalKey(groupName: "Thurston Howell \u{2013} A Premier Yacht Rock Spectacular!",
                                        performanceDate: "2026-08-01", venue: "The Cutting Room")
        let b = Prospect.makeNaturalKey(groupName: "Thurston Howell - A Premier Yacht Rock Spectacular!",
                                        performanceDate: "2026-08-01",
                                        venue: "The Cutting Room, 44 East 32nd Street, New York, NY")
        #expect(a == b)
    }

    // The other direction, and the one that matters most: the fold must never fuse two genuinely
    // different acts. The Green Room 42 legitimately books two different shows on one night, all through
    // the live store, and those are two real cards Dan has to see.
    @Test func keepsTwoDifferentActsOnOneNightApart() {
        let (a, b) = keys("Bite Me", "A Tom Lehrer Cabaret",
                          date: "2026-07-29", venue: "The Green Room 42")
        #expect(a != b)
    }

    @Test func keepsTitlesApartThatDifferByAWordNotJustPunctuation() {
        let (a, b) = keys("Fleetwood Mac: Stripped", "Fleetwood Mac: Stripped (Broadway Sings)",
                          date: "2026-09-23", venue: "The Cutting Room")
        #expect(a != b)
    }

    // A title made only of punctuation folds to nothing. It must fall back to its own canonical text
    // rather than becoming an empty string, which would key every such show onto one row.
    @Test func aTitleOfPurePunctuationDoesNotCollapseToEmpty() {
        let (a, b) = keys("!!!", "???", date: "2026-07-29", venue: "Jalopy Theatre")
        #expect(a != b)
        #expect(!a.hasPrefix("|"))
    }
}
