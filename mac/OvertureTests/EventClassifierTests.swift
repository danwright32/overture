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

    @Test func fallsBackToMusic() {
        #expect(EventClassifier.classify(ev(title: "An Evening of Chopin")).discipline == .music)
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
