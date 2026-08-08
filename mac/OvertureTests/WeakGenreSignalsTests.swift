import Testing
import Foundation

// #1946: two gaps in the classifier's hand-written word lists, both measured on the live store on
// 2026-08-07 (845 rows, 537 of them with no genre at all).
//
// Every title below is a real row from that store.
@Suite("The two word-list gaps (#1946)")
struct WeakGenreSignalsTests {

    private func genre(_ title: String, _ presenter: String? = nil) -> Discipline {
        EventClassifier.classify(ExtractedEvent(title: title, presenter: presenter, venue: nil)).discipline
    }

    // "sing" was missing while every neighbouring inflection was present (`song`, `songs`, `sings`,
    // `singers`), which reads as an oversight rather than a decision. Nine unread rows carry it and every
    // one of them is music.
    @Test func aShowAboutSingingIsMusic() {
        #expect(genre("Messiah Sing", "The Dessoff Choirs") == .music)
        #expect(genre("Live, Laugh, Sing") == .music)
        #expect(genre("Gotta Sing") == .music)
        #expect(genre("The Pumpkin Singalong at Sakura Park", "Every Voice Choirs") == .music)
        #expect(genre("Jason Graae: It's a Graae Night for Singing!") == .music)
    }

    // "musical" is read LAST and only where nothing else answered, which is what lets it rescue a stage
    // musical without taking a row that already has a better genre.
    @Test func aStageMusicalWithNoOtherSignalIsTheater() {
        #expect(genre("Bone Wars: A New Musical") == .theater)
        #expect(genre("Alice in Wonderland the Musical") == .theater)
        #expect(genre("A Christmas Carol the Musical 2026 (18th SMASH YEAR!)",
                      "Michael Sgouros & Brenda Bell") == .theater)
        #expect(genre("Marlise (A New Golden Age Musical)") == .theater)
    }

    // The cost the original refusal was protecting against, and the reason the pass is last: read at full
    // strength beside the theater check, "musical" would take these rows from the genre that fits them.
    // This is the half that must not regress, so it is asserted as its own claim.
    @Test func aStrongerSignalKeepsItsRowFromTheWeakOne() {
        #expect(genre("Gross Prophets: A Comedy Musical", "Asylum NYC") == .comedy)
        #expect(genre("Musical Mondays", "Jalopy Theatre") == .theater,
                "a real theater word still wins outright")
        #expect(genre("An Evening of Opera Musicals", "Taconic Opera") == .opera)
        #expect(genre("Symphony No. 9: The Musical Story", "Taconic Opera") == .music)
    }

    // And a title carrying neither is still honestly unread (#1657).
    @Test func aTitleWithNeitherSignalIsStillUnread() {
        #expect(genre("A Man Called Paris", "Under St Marks") == .other)
    }
}
