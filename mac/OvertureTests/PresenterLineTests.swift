import Testing
import Foundation

// #1687: Dan, on the Aug 4 queue: "I should be able to see who the group is no matter if I've worked with
// them or not. If it's a named performing group like YNYC is, I should be able to tell that from just
// looking at the card." The presenting org rode all the way onto the row model and was never drawn, so the
// only thing naming the ensemble was the gold past-client pill, which by definition appears only on a
// group he has already booked. That inverts the pill: it exists to say "you know these people" and was
// being read as "who is playing".
//
// The rule is four gates rather than one field, because the presenter is very often the ROOM. Drawing it
// unconditionally would print "Jalopy Theatre" directly above "Jalopy Theatre" on 275 of the live store's
// 547 rows carrying one, which is the #843 defect (a second line that tells him nothing the line beside it
// did not). The decision lives here, tested, rather than in a ternary in the view, the same way
// headerShowsTimingLine already handles the booked-row case.
@Suite("Presenter line on the card (#1687)")
struct PresenterLineTests {

    // A house whose presenting brand is its own name, in the shape the live store holds it: Carnegie Hall
    // presents under "Carnegie Hall Presents" into four rooms that are never spelled "Carnegie Hall".
    private var carnegieCorpus: ProducerGate.VenueBrands {
        ProducerGate.VenueBrands(shows: [
            ProducerGate.Show(presenter: "Carnegie Hall Presents", venue: "Stern Auditorium / Perelman Stage"),
            ProducerGate.Show(presenter: "Carnegie Hall Presents", venue: "Zankel Hall"),
            ProducerGate.Show(presenter: nil, venue: "Carnegie Hall"),
        ])
    }

    // The case Dan raised. Nothing in the title or the venue says who is singing, and the ensemble is a
    // past client, so today this name reaches the card only through the pill.
    @Test func namesTheEnsembleWhenNothingElseOnTheCardDoes() {
        #expect(QueueModel.presenterLine(title: "Holiday Modulations",
                                         presenter: "Young New Yorkers' Chorus",
                                         venue: "The Church of St. Mary the Virgin (Times Square)")
                == "Young New Yorkers' Chorus")
    }

    // The same show on a row with no pill at all, which is the 198-row population this is really for.
    @Test func namesTheEnsembleOnARowWithNoPastRelationship() {
        #expect(QueueModel.presenterLine(title: "Summer Community Sings",
                                         presenter: "Young New Yorkers' Chorus",
                                         venue: "St. Paul's Episcopal Church (Carroll Gardens)")
                == "Young New Yorkers' Chorus")
    }

    @Test func silentWhenThereIsNoPresenter() {
        #expect(QueueModel.presenterLine(title: "Some Show", presenter: nil, venue: "Weill Recital Hall") == nil)
        #expect(QueueModel.presenterLine(title: "Some Show", presenter: "   ", venue: "Weill Recital Hall") == nil)
    }

    // "Classical Nomads" presented by "Classical Nomads" at Zankel Hall, from the live store.
    @Test func silentWhenThePresenterOnlyRepeatsTheTitle() {
        #expect(QueueModel.presenterLine(title: "Classical Nomads",
                                         presenter: "Classical Nomads",
                                         venue: "Zankel Hall") == nil)
    }

    // The venue comparison goes through VenueNormalization.normalizeForKey, so a source that baked the
    // neighbourhood into the venue string still counts as the same room. This exact pair is what made
    // #1498 and #1686 necessary, and an unfolded comparison would draw "Jalopy Theatre" above
    // "Jalopy Theatre, Red Hook, Brooklyn, NY".
    @Test func silentWhenThePresenterIsThisRowsOwnVenueHoweverItIsSpelled() {
        #expect(QueueModel.presenterLine(title: "Burstin' Boots Dance Party with the Talking Hearts!",
                                         presenter: "Jalopy Theatre",
                                         venue: "Jalopy Theatre, Red Hook, Brooklyn, NY") == nil)
        #expect(QueueModel.presenterLine(title: "Live! on Grand: Auditions",
                                         presenter: "Abrons Arts Center",
                                         venue: "Abrons Arts Center") == nil)
    }

    // The gate the row alone cannot supply, and the reason this reuses #1702's shared judgment rather than
    // growing a second copy of it. The venue field on these rows says "Stern Auditorium", never "Carnegie
    // Hall", so comparing the presenter against this row's own venue never fires and the house's brand
    // draws as though it were the act.
    @Test func silentWhenThePresenterIsTheBuildingsOwnBrand() {
        #expect(QueueModel.presenterLine(title: "NYO2",
                                         presenter: "Carnegie Hall Presents",
                                         venue: "Stern Auditorium / Perelman Stage",
                                         venueBrands: carnegieCorpus) == nil)
    }

    // The same brand at a venue that is not even in the building. Without the brand gate this row draws
    // "Carnegie Hall Presents" as the performing group in Bryant Park.
    @Test func silentWhenTheBuildingsBrandPresentsSomewhereElseEntirely() {
        #expect(QueueModel.presenterLine(title: "Carnegie Hall Citywide: El Laberinto del Coco",
                                         presenter: "Carnegie Hall Presents",
                                         venue: "Bryant Park",
                                         venueBrands: carnegieCorpus) == nil)
    }

    // Without a corpus there are no brands, so nothing is suppressed on this arm. Pinned because the
    // default is what every test and importer gets, and a default that silently suppressed would be far
    // harder to notice than one that silently shows.
    @Test func theBrandGateIsInertWithoutACorpus() {
        #expect(QueueModel.presenterLine(title: "NYO2",
                                         presenter: "Carnegie Hall Presents",
                                         venue: "Stern Auditorium / Perelman Stage")
                == "Carnegie Hall Presents")
    }

    // #843 again, in its subtler form: the name is already on the card, inside the title. Drawing it again
    // one line down adds nothing. 15 rows on the live store.
    @Test func silentWhenTheTitleAlreadyNamesThePresenter() {
        #expect(QueueModel.presenterLine(title: "Camerata Nordica Octet",
                                         presenter: "Camerata Nordica",
                                         venue: "Weill Recital Hall") == nil)
        #expect(QueueModel.presenterLine(title: "Irvine School of Music Student Recital",
                                         presenter: "Irvine School of Music",
                                         venue: "Weill Recital Hall") == nil)
    }

    // Whole words only, matching the guard inside ProducerGate.containsAsWords. A presenter that merely
    // shares a fragment with the title is still a fact the card is not showing.
    @Test func aSharedFragmentIsNotTheTitleNamingThePresenter() {
        #expect(QueueModel.presenterLine(title: "Nordicana: A Winter Programme",
                                         presenter: "Camerata Nordica",
                                         venue: "Weill Recital Hall") == "Camerata Nordica")
    }

    // Dan chose the bare name over "Presented by X" (2026-07-29), having read that the field mixes the act
    // with its agency: on 215 rows it is drawn with no label, so what is drawn must be the stored name
    // exactly, never a sentence built around it.
    @Test func drawsTheStoredNameWithNoLabelWrappedAroundIt() {
        let line = QueueModel.presenterLine(title: "Ludovico Einaudi",
                                            presenter: "The Bowery Presents",
                                            venue: "Stern Auditorium / Perelman Stage")
        #expect(line == "The Bowery Presents")
    }
}

// The pill exists to say "you know these people". Once the card names the group in its own right, a pill
// that also spells the name says it twice on one card, which is the thing #1687 is fixing, not a second
// instance of it.
@Suite("The past-client pill stops repeating a name the card now shows (#1687)")
struct PastClientPillDedupTests {
    private func row(presenterLine: String?, matchedClientName: String?) -> QueueItem {
        var q = QueueItem(
            id: "k", groupName: "Holiday Modulations", discipline: "music",
            venue: "The Church of St. Mary the Virgin", performanceDate: "2026-12-13",
            sourceListingURL: nil, websiteURL: nil,
            priorRelationship: "booked", production: "unknown", profile: "neutral",
            coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "reason",
            matchedClientName: matchedClientName, possibleMatchSource: nil,
            possibleMatchName: nil, status: .new)
        q.presenterLine = presenterLine
        return q
    }

    // The YNYC card, spelled exactly as the live store holds it: the Downbeat client record has no
    // apostrophe and the scouted presenter does. This pair is the whole reason the comparison goes
    // through GroupNameMatch.normalize (the matcher's own fold) rather than the venue key, which keeps
    // punctuation and would leave Dan's own card saying the name twice.
    @Test func thePillDropsTheNameTheLineAboveAlreadyShows() {
        let flag = QueueModel.historyFlag(row(presenterLine: "Young New Yorkers' Chorus",
                                              matchedClientName: "Young New Yorkers Chorus"))
        #expect(flag == "Worked together before")
    }

    // Also from the live store: a collaboration billed under a longer name than the client record. The
    // line above is naming something the pill is not, so both facts stay.
    @Test func thePillKeepsItsNameWhenTheLineNamesACollaboration() {
        let flag = QueueModel.historyFlag(row(presenterLine: "Tenet Vocal Artists & Alkemie",
                                              matchedClientName: "TENET Vocal Artists"))
        #expect(flag == "Worked together before (TENET Vocal Artists)")
    }

    // A pill naming a DIFFERENT organisation than the line is two real facts, and keeps both.
    @Test func thePillKeepsAnameTheLineDoesNotShow() {
        let flag = QueueModel.historyFlag(row(presenterLine: "Meng Wang Music Academy",
                                              matchedClientName: "DCINY"))
        #expect(flag == "Worked together before (DCINY)")
    }

    // No line drawn, nothing to repeat: the pill is the only thing naming them, exactly as before.
    @Test func thePillIsUnchangedOnARowWithNoPresenterLine() {
        let flag = QueueModel.historyFlag(row(presenterLine: nil, matchedClientName: "DCINY"))
        #expect(flag == "Worked together before (DCINY)")
    }
}

// A guard and its wiring are two claims (#887). The rules above only hold on screen if the row draws the
// line and the queue actually supplies the corpus the brand gate needs. Cut either wire and every test
// above stays green while the card goes wrong: without the first, nothing draws; without the second, every
// house brand in the store draws as the performing group.
@Suite("The card and the queue are wired to the presenter rule (#1687)")
struct PresenterLineWiringTests {
    @Test func theRowDrawsTheLineTheModelDecided() {
        let row = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        #expect(row.contains("item.presenterLine"))
    }

    // The line is the "who", between the title (the what) and the venue (the where): Dan's placement
    // choice, 2026-07-29. Pinned by ORDER in the header's source, since a SwiftUI order test cannot pin
    // placement any other way.
    @Test func theLineSitsBetweenTheTitleAndTheVenue() {
        let row = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        guard let title = row.range(of: "Text(item.groupName)"),
              let line = row.range(of: "item.presenterLine"),
              let venue = row.range(of: "let venueInfo = VenueDisplay.resolve") else {
            Issue.record("header no longer has the title, presenter and venue anchors this pins order on")
            return
        }
        #expect(title.upperBound < line.lowerBound)
        #expect(line.upperBound < venue.lowerBound)
    }

    // The brand gate is INERT without a corpus, so a builder that forgot to pass one would draw every
    // house brand in the store while every rule test above stayed green. Scoped to the one builder both
    // card surfaces (Queue and Archive) go through, so a coincidental match elsewhere in a 1500-line file
    // cannot stand in for the real wiring.
    @Test func theOneQueueBuilderComputesTheLineAgainstTheWholeStore() {
        let model = SourceGuardHelper.source("Overture/UI/QueueView+Model.swift")
        // #2524: found by NAME rather than by the signature's last line. Pinned to the closing line it
        // broke the moment a parameter was added after `now:`, and a marker that stops matching returns
        // nil, which every `contains` below is quietly false against (#2192). The name is the thing this
        // guard is actually about.
        guard let body = SourceGuardHelper.bodyOfFunction(named: "items", in: model) else {
            Issue.record("QueueModel.items(from:) is gone, so this guard is asking nothing")
            return
        }
        #expect(body.contains("ProducerGate.VenueBrands("))
        #expect(body.contains("presenterLine"))
        // The corpus is the whole store, not the caller's already-filtered rows: judging brands against a
        // triaged subset would let a dismissal quietly change which names draw (the #1598 reasoning that
        // put `corpus` on this signature in the first place).
        #expect(body.contains("corpus ?? prospects"))
    }
}
