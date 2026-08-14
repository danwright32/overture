import Testing
import Foundation

// #2262: a rental room's listing leads with the ROOM's own name, and bills the company putting the show
// on further down, inside the description.
//
// 54 Below is the second largest source of shows that reach the queue with no producing organisation at
// all (56 of them). #2259's parse reads the possessive credit standing in FRONT of the show's title, which
// is how the Green Room 42's ticketing pages bill a producer; 54 Below does not bill that way. Every one
// of its pages opens "Welcome To 54 Below A Nonprofit Cabaret Venue" and then the show's title, so the
// only name in front of the title is the room's, which is drained downstream and leaves nobody to pitch.
//
// MEASURED, not invented (L48). Every string below is a contiguous verbatim slice of the real page text as
// `ShowListingReader` stores it (`PageNormalizer.visibleText(PageNormalizer.normalize(html))`), from
// listings fetched on 2026-08-11. Each fixture names its own URL.
//
// What the whole calendar looks like, measured the same day over all 61 listings reachable from
// https://54below.org/calendar/ :
//   - 17 bill a producer in the description ("Produced by ...").
//   - ONE of those 17 names a company: "Produced by Productions by Stephan". The other 16 name
//     individuals, whom the shared rule refuses (a bare personal name is not producer-shaped), so this
//     arm leaves them alone rather than reaching for them. That is the cost of keeping ONE rule, and it
//     is stated rather than hidden: widening it to individuals would move the VenueTix, OvationTix and
//     TicketTailor boundaries too, and is #2554 rather than a second spelling of the rule here (L93).
//   - The credit always stands AFTER the show's own title (61 of 61: the title sits at the same offset on
//     every page and no credit precedes it), which is what this arm requires.
//   - "produced by" appears more than once on exactly ONE of the 61 pages, and all three occurrences there
//     are that show's own credits. No page carries a past credit from a performer's bio in the text the
//     app stores, which is the risk #2259 named when it kept this half out.
@Suite("The producer a rental room's listing bills in its description (#2262)")
struct ListingBilledProducerTests {

    // https://54below.org/events/re-arranged-a-night-of-new-arrangements-1/  fetched 2026-08-11
    private let reArranged = """
    Welcome To 54 Below A Nonprofit Cabaret Venue Re-Arranged: A Night of New Arrangements August 5, \
    2026 Back by popular demand! Step into an evening of bold harmonies and beautiful reinvention at \
    Re-Arranged: A Night of New Arrangements . This intimate concert experience celebrates the \
    artistry, power, and nuance of femme voices through thoughtfully crafted duet and trio \
    arrangements that give your favorite songs a fresh perspective. Featuring original arrangements by \
    Sydney Stephan , hosted by Sabina Demidovich and performances by over 30 of New York City’s most \
    exceptional femme artists, Re-Arranged highlights connection, collaboration, and musical \
    storytelling at its finest. From harmonies to reinterpretations, each pairing offers something \
    familiar yet entirely new. Produced by Productions by Stephan , Re-Arranged is a one-night-only \
    celebration of femme creativity, musical excellence, and the art of collaboration.
    """

    // https://54below.org/events/54-below-debut-2/  fetched 2026-08-11
    private let debut = """
    Welcome To 54 Below A Nonprofit Cabaret Venue 54 Below! DEBUT! August 29, 2026 This performance \
    will also be livestreamed. For tickets and more information, click here . Back by popular demand! \
    Join us for a high-energy celebration of theatrical triumphs and firsts at 54 Below! DEBUT , an \
    electrifying concert series that brings the exhilarating highs and heartbreaking near-misses of a \
    life in the theater to the stage. With a mix of show-stopping performances and untold backstage \
    stories, DEBUT explores the moments that shaped rising talents, from first auditions to opening \
    nights and dream roles to unexpected breakthroughs. Featuring iconic songs from beloved composers, \
    DEBUT is a one-night-only event you won’t want to miss. Debuting new performers to the New York \
    stage, enjoy a night of raw, unforgettable energy, celebrating the triumph of firsts. No matter \
    the stage, we all start somewhere! Produced by Amanda Negrete . Music direction by Elijah Cox .
    """

    // https://54below.org/events/flame-the-songs-of-amara-janae-brady-and-xander-browne/  2026-08-11
    private let flame = """
    Welcome To 54 Below A Nonprofit Cabaret Venue Flame: The Songs of Amara Janae Brady and Xander \
    Browne, feat. Sidney DuPont & more! August 23, 2026 This performance will also be livestreamed. \
    For tickets and more information, click here . Join us at 54 Below for a scorching hot evening of \
    the songs from the dynamic musical theatre writing duo and 2025 Jonathan Larson Grant Finalists \
    Amara Janae Brady and Xander Browne ! The night will be full of stand alone songs and songs from \
    their new musical, BaKed . Developed with the historic Apollo Theater and Drama Club Camp \
    Productions, BaKed is an explosive reimagining of Cinderella’s story from a whole new perspective. \
    Enter Amelia, the overworked and underappreciated baker who caters Prince Charming’s Ball. When \
    the Crown fails to pay her, she blows up her life… and her home and ends up on a wild adventure \
    with all the folks in this story who don’t get a happy ending as they learn to make happy \
    beginnings of their own. Performed by its writers Amara Janae Brady , Xander Browne , and some \
    very special guests, this show is sure to make you get down… and then fight for revolution. \
    Directed by Blayze Teicher and cast by Charlie Hano, CSA . In collaboration with Breaking & \
    Entering Theatre Collective .
    """

    // https://54below.org/events/hayley-trapp-the-bubbling-cabaret/  fetched 2026-08-11
    private let bubblingCabaret = """
    Welcome To 54 Below A Nonprofit Cabaret Venue Hayley Trapp: The Bubbling Cabaret September 1, 2026 \
    Making her 54 Below debut, Hayley Trapp presents The Bubbling Cabaret an evening to honor the \
    legacy of Charlie Trapp.
    """

    // https://54below.org/events/first-drafts-student-edition/  fetched 2026-08-11
    private let firstDrafts = """
    Welcome To 54 Below A Nonprofit Cabaret Venue First Drafts: Student Edition August 18, 2026 \
    Following its inception in 2025, the Showpeople Theatre Collective returns to New York City with \
    the second iteration of the First Drafts cabaret series, an evening of the freshest songs by \
    up-and-coming musical theatre songwriters. This time, the focus is truly on the theatre makers of \
    tomorrow as the show solely features the work of high school and college students from New York \
    City and beyond! Produced and directed by Showpeople Resident Artist Colby Thompson , First \
    Drafts: Student Edition gives songwriters a chance to hear their songs performed in an acclaimed \
    cabaret, and it gives audiences the chance to hear musical theatre hits long before they reach the \
    stage.
    """

    // MARK: - What it has to catch

    @Test func theCompanyBilledInTheDescriptionIsFound() {
        #expect(ListingOrganiser.producerNamed(inListingText: reArranged,
                                               showTitle: "Re-Arranged: A Night of New Arrangements",
                                               venue: "54 Below") == "Productions by Stephan")
    }

    // The room leads the page on every one of these listings, and it is not the producer. Before this
    // arm the only name in front of the title was "Welcome To 54 Below A Nonprofit Cabaret Venue".
    @Test func theRoomsOwnLeadInIsNotMistakenForTheCompany() {
        let name = ListingOrganiser.producerNamed(inListingText: reArranged,
                                                  showTitle: "Re-Arranged: A Night of New Arrangements",
                                                  venue: "54 Below")
        #expect(name?.contains("54 Below") == false)
        #expect(name?.contains("Cabaret Venue") == false)
    }

    // MARK: - What it has to leave alone

    // REVERSED by #2554, and this is the whole point of that issue. 16 of the 17 measured credits name a
    // person, and the rule dropped every one of them, so the number it fired on (1 of 61 real listings)
    // read as a working feature. On a rental room the individual billed as producing IS the person who
    // hired the room and who would hire a photographer, so the credit is now read whoever it names.
    @Test func aCreditNamingAnIndividualIsRead() {
        #expect(ListingOrganiser.producerNamed(inListingText: debut, showTitle: "54 Below! DEBUT!",
                                               venue: "54 Below") == "Amanda Negrete")
    }

    // A page that bills nobody at all. Company-shaped names sit in its prose ("Drama Club Camp
    // Productions", "Breaking & Entering Theatre Collective") and neither is billed as producing THIS
    // show: one is where the musical was developed, the other a collaborator. A rule that matched
    // company shape wherever it appeared would pitch both (L104).
    @Test func companyNamesInProseAreNotACredit() {
        #expect(ListingOrganiser.producerNamed(
            inListingText: flame,
            showTitle: "Flame: The Songs of Amara Janae Brady and Xander Browne, feat. Sidney DuPont & more!",
            venue: "54 Below") == nil)
    }

    // "Hayley Trapp presents The Bubbling Cabaret" is the act introducing her own show, not a producing
    // company being billed. Only "presented by" and "produced by" are credits.
    @Test func aPerformerPresentingTheirOwnShowIsNotACredit() {
        #expect(ListingOrganiser.producerNamed(inListingText: bubblingCabaret,
                                               showTitle: "Hayley Trapp: The Bubbling Cabaret",
                                               venue: "54 Below") == nil)
    }

    // The honest miss #2262 recorded, now READ: #2554 added "produced and directed by" to the credits,
    // because that phrasing is what the p0 case used ("this concert is produced and directed by Caseen
    // Gaines") and searching for "produced by" inside it matches nothing at all.
    //
    // The value it returns carries the role the page put in front of the name, because the credit really
    // does read "Produced and directed by Showpeople Resident Artist Colby Thompson". Asserted as it is,
    // rather than trimmed to "Colby Thompson", because stripping a role would mean enumerating roles and
    // guessing where the name starts, and this string is not wrong: it names the producer AND the
    // collective, and the run reads the page itself as well.
    @Test func aCreditCarryingTheRoleInFrontOfTheNameIsRead() {
        #expect(ListingOrganiser.producerNamed(inListingText: firstDrafts,
                                               showTitle: "First Drafts: Student Edition",
                                               venue: "54 Below") == "Showpeople Resident Artist Colby Thompson")
    }

    // The room guard covers this arm too. Constructed, not measured: the real Re-Arranged text with the
    // billed company named as the room it plays in, which is the one substitution that proves the guard
    // gates the new arm rather than only the possessive one (#1787).
    @Test func aBilledNameThatIsTheRoomIsRefused() {
        #expect(ListingOrganiser.producerNamed(inListingText: reArranged,
                                               showTitle: "Re-Arranged: A Night of New Arrangements",
                                               venue: "Productions by Stephan") == nil)
    }

    // Constructed: the same credit moved in FRONT of the show's title. The description belongs to the
    // show whose title it follows, and on a page listing several shows a credit standing above the title
    // belongs to a different one.
    @Test func aCreditStandingBeforeTheTitleIsNotThisShowsProducer() {
        let text = "Produced by Productions by Stephan , tonight at eight. Re-Arranged: A Night of New "
            + "Arrangements is a one-night-only celebration."
        #expect(ListingOrganiser.producerNamed(inListingText: text,
                                               showTitle: "Re-Arranged: A Night of New Arrangements",
                                               venue: "54 Below") == nil)
    }

    // MARK: - The shared rule itself, asked directly

    // The billing arm lives in ProducerShapedName, beside the supertitle rule the feed adapters ask, so
    // the two boundaries cannot answer "is this a producing company?" differently (#2452, L26).
    @Test func theSharedRuleReadsTheBilledCompanyOutOfASentence() {
        #expect(ProducerShapedName.billedInProse(
            "Produced by Productions by Stephan , Re-Arranged is a one-night-only celebration.")
                == "Productions by Stephan")
    }

    // #2554: reversed with the arm above. The credit is what says somebody is producing this show, so the
    // name behind it does not also have to be shaped like a company.
    @Test func theSharedRuleReadsACreditNamingAPerson() {
        #expect(ProducerShapedName.billedInProse("Produced by Amanda Negrete . Music direction by Elijah "
                                                + "Cox .") == "Amanda Negrete")
    }

    // The capital is what separates a name from the sentence carrying on. "company" is one of the words
    // the rule looks for, so without it this phrase is short enough to pass as an organisation.
    @Test func theSharedRuleRefusesLowercaseProseAfterTheConnector() {
        #expect(ProducerShapedName.billedInProse("produced by the company that staged it") == nil)
    }

    // Real prose from the Flame listing. A company name with nothing billing it is not a credit.
    @Test func theSharedRuleRefusesACompanyNameWithNoConnector() {
        #expect(ProducerShapedName.billedInProse(
            "Developed with the historic Apollo Theater and Drama Club Camp Productions, BaKed is an "
            + "explosive reimagining") == nil)
    }

    // A page with nothing billed at all has nothing to read, which is a different answer from a refusal
    // and reaches the same place: no company.
    @Test func theSharedRuleFindsNothingWhereNobodyIsBilled() {
        #expect(ProducerShapedName.billedInProse("An evening of songs at eight, doors at seven.") == nil)
    }
}
