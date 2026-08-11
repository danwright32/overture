import Testing

private func ev(
    title: String = "Some Performance",
    presenter: String? = nil,
    venue: String? = "Weill Recital Hall"
) -> ExtractedEvent {
    ExtractedEvent(title: title, presenter: presenter, venue: venue, performanceDate: "2026-06-25", sourceUrl: nil)
}

@Suite("Event classifier — dead-zone cases")
struct ClassifierDeadZoneTests {
    @Test func competitionWinnersRentalIsAgencyWeakUncovered() {
        let c = EventClassifier.classify(ev(
            title: "Boston & New York International Music Competition Winners' Recital",
            presenter: "Jam Generation", venue: "Weill Recital Hall"))
        #expect(c.production == .agency)
        #expect(c.profile == .weak)
        #expect(c.coverage == .likelyUncovered)
        #expect(c.discipline == .music)
    }

    @Test func risingStarsShowcaseIsAgencyWeak() {
        let c = EventClassifier.classify(ev(title: "New York Rising Stars Concert", presenter: "New York Young Arts Foundation"))
        #expect(c.production == .agency)
        #expect(c.profile == .weak)
    }
}

@Suite("Event classifier — strong-fit cases")
struct ClassifierStrongTests {
    // #350: choir/chorus signals still detect a strong, self-produced profile; the resulting
    // discipline is Music (Choral was folded into it), not a separate Choral bucket.
    @Test func childrensChoirIsSelfStrongMusic() {
        let c = EventClassifier.classify(ev(
            title: "Indianapolis Children's Choir", presenter: "Indianapolis Children's Choir",
            venue: "Stern Auditorium / Perelman Stage"))
        #expect(c.production == .selfProduced)
        #expect(c.profile == .strong)
        #expect(c.discipline == .music)
        #expect(c.coverage == .likelyUncovered)
    }

    @Test func culturalTheaterPieceIsSelfTheater() {
        let c = EventClassifier.classify(ev(
            title: "The Presence of Absence (A Cuban Nocturne)",
            presenter: "Cuban Cultural Center of New York and Thalia Spanish Theatre",
            venue: "Thalia Spanish Theatre"))
        #expect(c.production == .selfProduced)
        #expect(c.discipline == .theater)
        #expect(c.profile == .strong)
    }
}

@Suite("Event classifier — discipline and ambiguity")
struct ClassifierMiscTests {
    @Test func disciplineFromKeywords() {
        #expect(EventClassifier.classify(ev(title: "Spring Ballet Gala")).discipline == .dance)
        #expect(EventClassifier.classify(ev(title: "La Bohème: Opera in Concert")).discipline == .opera)
        #expect(EventClassifier.classify(ev(title: "Brooklyn Youth Chorus")).discipline == .music)
        #expect(EventClassifier.classify(ev(title: "Wind Ensemble Showcase")).discipline == .band)
    }

    // LIVE-STORE-CLAIM verified=2026-07-16 measure="live rows tagged music while music was the classifier's fallback"
    // #970 Phase 0. The fallback used to be `.music`, so "no idea" and "this is music" were the same
    // answer. That made `music` 119 of 128 live rows and left `.other` unreachable, which matters now
    // that discipline picks the geographic gate: music takes the strict five-borough rule, everything
    // else takes the looser one. A show the classifier cannot read must say so, not claim to be music.
    @Test func fallsBackToOtherWhenNothingMatches() {
        #expect(EventClassifier.classify(ev(title: "An Evening of Chopin")).discipline == .other)
    }

    // Real rows from the live store, all at Under St Marks, all tagged `music` today purely because
    // the fallback said so. None carries a discipline signal, so none should claim one.
    @Test func unreadableTitlesAreOtherNotMusic() {
        #expect(EventClassifier.classify(ev(title: "A Man Called Paris")).discipline == .other)
        #expect(EventClassifier.classify(ev(title: "Gigi in Punk")).discipline == .other)
        #expect(EventClassifier.classify(ev(title: "Honey, Drop It")).discipline == .other)
    }

    // #970 Phase 0. Detecting music only by choir words left 115 of 119 music rows resolving by
    // fallback, so flipping the fallback alone would have handed the strict five-borough rule just 4
    // rows out of 128 and quietly killed the discipline split Dan asked for. These are live titles.
    @Test func recognizesMusicBeyondChoirWords() {
        #expect(EventClassifier.classify(ev(title: "Berliner Philharmoniker")).discipline == .music)
        #expect(EventClassifier.classify(ev(title: "Anna Pierre, Piano Virgile Roche, Piano")).discipline == .music)
        #expect(EventClassifier.classify(ev(title: "Diana Jipa, Violin Ștefan Doniga, Piano")).discipline == .music)
        #expect(EventClassifier.classify(ev(title: "Camerata Nordica Octet")).discipline == .music)
        #expect(EventClassifier.classify(ev(title: "Carnegie Hall Citywide: Cerus Quartet")).discipline == .music)
        #expect(EventClassifier.classify(ev(title: "China Now Chamber Orchestra")).discipline == .music)
        #expect(EventClassifier.classify(ev(title: "2026 Concordia Music Competition Top Honors Recital")).discipline == .music)
        #expect(EventClassifier.classify(ev(title: "Joe Hisaishi in Concert")).discipline == .music)
    }

    // Live high-tier rows whose only music signal is a plainer English word. Both score above the
    // high-tier threshold, so reading them as "no signal" would put real prospects on the wrong side
    // of the geographic gate.
    @Test func recognizesMusicFromPlainWords() {
        #expect(EventClassifier.classify(ev(title: "Staten Island Community Song Circle")).discipline == .music)
        #expect(EventClassifier.classify(ev(title: "Timeless Melodies: Masterpieces Inspiring Generations")).discipline == .music)
    }

    // The music words are checked AFTER dance, opera and theater, so a title carrying both signals
    // keeps the more specific one. Without this order "Opera in Concert" reads as music.
    @Test func moreSpecificDisciplineBeatsAMusicWord() {
        #expect(EventClassifier.classify(ev(title: "La Bohème: Opera in Concert")).discipline == .opera)
        #expect(EventClassifier.classify(ev(title: "Spring Ballet Gala: A Piano Recital")).discipline == .dance)
        #expect(EventClassifier.classify(ev(title: "Playhouse Orchestra Night")).discipline == .theater)
    }

    // "musical" is a theater word wearing a music word's clothes. The music rule must not match the
    // prefix, which is what `music` being bounded is for.
    //
    // #1946 changed what happens to the word after that. It used to be refused outright, leaving 18 real
    // stage musicals with no genre at all; it is now read by the WEAK pass that runs last, so it reaches
    // a row nothing else could and takes none from a stronger signal (see WeakGenreSignalsTests).
    @Test func doesNotReadMusicalAsMusic() {
        let read = EventClassifier.classify(ev(title: "Hell Yeah! An Improvised Musical")).discipline
        #expect(read != .music)
        #expect(read == .theater)
    }

    @Test func doesNotMisreadPlayInAName() {
        let c = EventClassifier.classify(ev(title: "Timeless Melodies", presenter: "Play It Forward School of Music"))
        #expect(c.discipline == .music)
    }

    @Test func establishedOrchestraReadsAsSelfProduced() {
        let c = EventClassifier.classify(ev(title: "Orchestra of St. Luke's", presenter: "Orchestra of St. Luke's", venue: "Zankel Hall"))
        #expect(c.production == .selfProduced)
    }

    // #1533: a presenter the page never named leaves the production UNKNOWN, and that is the end of it.
    // It used to raise a badge asking Dan to settle it by hand, on 431 of the 556 undecided rows. The
    // classifier still says honestly that it does not know, and `.unknown` scores a neutral 0, so an
    // unanswered production neither promotes nor buries the show.
    @Test func aNamelessPresenterLeavesProductionUnknownAndScoresItNeutral() {
        let c = EventClassifier.classify(ev(title: "Gala Concert", presenter: nil))
        #expect(c.production == .unknown)
        #expect(Ranker.productionPoints(c.production) == 0)
    }
}

// #2504: WHO this show would be pitched to, when nobody but the act is named.
//
// Measured on the live store 2026-08-11: 439 of 877 rows name no presenting organisation, and they
// average a fit score of 0.4 against 3.2 for the rest. The cause was structural, not a judgement. Three
// of the six scoring axes were computed from the presenter string alone, and `isProducer` was gated on
// that string being non-empty, so on those 439 rows `production` could never be anything but `unknown`,
// `profile` could never be `strong`, and `coverage` could never be `likelyUncovered`. Each of those is
// the "we know nothing" value and each scores 0, so the score read on the queue as "poor fit" while
// actually meaning "we could not look".
//
// Dan's call, 2026-08-11, asked which way to take it: judge the ACT itself, because the act is the party
// he would write to. His position on these leads, from #2464: "do not filter. often solo performers are
// great leads."
//
// So the classifier now has a notion of the PARTY: the presenting organisation when one is named, and
// the act when none is. A show with no organisation billed is one the act is putting on itself, which is
// what `selfProduced` means, and that is a fact about the row rather than a guess about the name.
@Suite("Event classifier - the act is the party when nobody else is named (#2504)")
struct ClassifierActIsThePartyTests {

    // The commonest live shape by far: a soloist at a room that rents itself out, night after night.
    @Test func aSoloistBilledUnderHerOwnNameIsSelfProducing() {
        let c = EventClassifier.classify(ev(title: "Amanda Duarte", presenter: nil,
                                            venue: "The Green Room 42"))
        #expect(c.production == .selfProduced)
        // Deliberately NOT strong. Nothing here says whether she is well known, and inventing that would
        // be the classifier claiming more than it measured.
        #expect(c.profile == .neutral)
    }

    // A blank presenter and a whitespace-only presenter are the same row. The extraction boundary writes
    // an empty string rather than nil when it drains a room's own name, which is the commonest way a row
    // reaches this state at all.
    @Test func aDrainedPresenterCountsAsNobodyNamed() {
        let c = EventClassifier.classify(ev(title: "Christopher Zelno", presenter: "   ",
                                            venue: "The Green Room 42"))
        #expect(c.production == .selfProduced)
    }

    // When the act names an organisation, that organisation is judged as the party, so the profile axis
    // becomes reachable for the first time on these rows.
    @Test func anEnsembleBilledAsTheActIsJudgedAsTheOrganisationItIs() {
        let c = EventClassifier.classify(ev(
            title: "China Now Chamber Orchestra and the Bard East/West Ensemble",
            presenter: nil, venue: "Zankel Hall"))
        #expect(c.production == .selfProduced)
        #expect(c.profile == .strong)
        #expect(c.coverage == .likelyUncovered)
    }

    // The room is the one organisation on the page that is certainly NOT the producer (#1787, #2259).
    // Several live rows repeat the room's own name inside the act line ("LOL! The Players Theatre Short
    // Play Festival"), and reading "Theatre" there as an organisation would promote the venue by the back
    // door, on a row whose whole problem is that nobody else was named.
    @Test func theRoomsOwnNameInsideTheActLineIsNotAnOrganisation() {
        let c = EventClassifier.classify(ev(title: "LOL! The Players Theatre Short Play Festival 2026",
                                            presenter: nil, venue: "The Players Theatre"))
        #expect(c.production == .selfProduced)   // still the act's own show
        #expect(c.profile == .neutral)           // but the room does not make it a strong organisation
    }

    // An agency-routed rental is still the dead zone, whoever is billed. This is the one direction that
    // must NOT be lifted: the whole point of the agency signal is that these rarely convert.
    @Test func anAgencyRentalIsStillTheDeadZoneWithNoPresenterNamed() {
        let c = EventClassifier.classify(ev(
            title: "New York International Music Competition Winners' Recital",
            presenter: nil, venue: "Weill Recital Hall"))
        #expect(c.production == .agency)
        #expect(c.profile == .weak)
    }

    // A show that DOES name a presenting organisation is untouched by any of this. The party is the
    // presenter there, exactly as before, and a title full of organisation words cannot make an ordinary
    // agency rental look self-produced.
    @Test func aNamedPresenterStillDecidesTheRow() {
        let c = EventClassifier.classify(ev(title: "Gala of Rising Stars",
                                            presenter: "Distinguished Concerts International",
                                            venue: "Stern Auditorium / Perelman Stage"))
        #expect(c.production == .agency)
        #expect(c.profile == .weak)
    }
}
