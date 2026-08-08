import Testing
import Foundation

// #1658 (Phase C of #1591): the SHOW decides its own genre, and the organisation putting it on is only
// consulted when the show's own title says nothing.
//
// Every title below is a real live-store row, and every one of them is a case where the presenter's name
// outranked the show. A building's name is a poor witness to what is on inside it tonight: Jalopy Theatre
// is a Red Hook folk music room, and 30 of its 34 rows were stored as theater for that reason alone.
@Suite("The title decides the genre (#1658)")
struct TitleDecidesTheGenreTests {

    private func genre(_ title: String, _ presenter: String?) -> Discipline {
        EventClassifier.classify(ExtractedEvent(title: title, presenter: presenter, venue: nil)).discipline
    }

    @Test func aFolkFestivalAtATheatreIsMusic() {
        #expect(genre("The 2026 Brooklyn Folk Festival", "Jalopy Theatre") == .music)
    }

    @Test func aComedyNightAtAPlayhouseIsComedy() {
        #expect(genre("Headquarters Comedy", "SoHo Playhouse") == .comedy)
    }

    // The row Dan was shown and ruled on (2026-08-07): an orchestral concert billed by an opera company
    // is read as music.
    @Test func anOrchestralConcertBilledByAnOperaCompanyIsMusic() {
        #expect(genre("Symphony No. 9", "Taconic Opera") == .music)
    }

    // The fallback, which is what keeps this phase from making the queue LESS readable. A title carrying
    // no genre word at all still reaches an answer through the presenter, exactly as before: 27 of
    // Jalopy's 30 wrong rows are artist-name titles, and they still lean on the presenter.
    @Test func aTitleWithNoSignalStillFallsBackToThePresenter() {
        #expect(genre("Bone Wars", "The Players Theatre") == .theater)
        #expect(genre("Tim Eriksen", "Jalopy Theatre") == .theater)
    }

    // And a show whose title names its own genre keeps it when the presenter agrees, so the change is
    // about precedence and not about refusing the presenter.
    @Test func aTitleAndPresenterThatAgreeAreUnchanged() {
        #expect(genre("Opera Goes to Church", "Taconic Opera") == .opera)
    }

    // Neither says anything: still unread, and now it SAYS so (#1657).
    @Test func neitherNamingAGenreIsStillUnread() {
        #expect(genre("A Man Called Paris", "Under St Marks") == .other)
    }
}
