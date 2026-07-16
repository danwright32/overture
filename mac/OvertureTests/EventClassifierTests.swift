import Testing
@testable import Overture

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
        #expect(c.confidence == .confident)
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
        #expect(c.confidence == .confident)
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

    // "musical" is a theater word wearing a music word's clothes, and the existing theater rule
    // already refuses to read it. The music rule must not undo that by matching the prefix.
    @Test func doesNotReadMusicalAsMusic() {
        #expect(EventClassifier.classify(ev(title: "Hell Yeah! An Improvised Musical")).discipline == .other)
    }

    @Test func doesNotMisreadPlayInAName() {
        let c = EventClassifier.classify(ev(title: "Timeless Melodies", presenter: "Play It Forward School of Music"))
        #expect(c.discipline == .music)
    }

    @Test func establishedOrchestraFlaggedUncertain() {
        let c = EventClassifier.classify(ev(title: "Orchestra of St. Luke's", presenter: "Orchestra of St. Luke's", venue: "Zankel Hall"))
        #expect(c.production == .selfProduced)
        #expect(c.confidence == .uncertain)
    }

    @Test func unknownPresenterIsUncertain() {
        #expect(EventClassifier.classify(ev(title: "Gala Concert", presenter: nil)).confidence == .uncertain)
    }
}
