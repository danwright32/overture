import Testing
import Foundation

// #1742: the gold genre line IS the editor, and Dan asked for it while looking straight at it. #1533
// moved the correction onto the line that states the genre, and implemented "quiet" as invisible: the
// line rendered byte-identical to every other tracked all-caps caption in the app, with a tooltip and
// nothing else. A tooltip is not an affordance, it is a reward for already suspecting.
//
// The visible cue itself (a chevron sitting after the word, at rest, in the register of the title's
// rename pencil) is a SwiftUI body and cannot be asserted here. What CAN be pinned is the part with a
// rule in it: what the control announces. It is now the only labelled control on this row, so a wrong
// label is the difference between "Genre, Performance, change it" and a bare raw enum value read aloud.
@Suite("The genre control announces itself (#1742)")
struct GenreControlTests {
    @Test func itNamesTheGenreInDansWordsRatherThanTheStoredValue() {
        #expect(GenreControlCopy.accessibilityLabel(for: "music").contains("Music"))
        #expect(GenreControlCopy.accessibilityLabel(for: "theater").contains("Theater"))
    }

    // The case that is now common rather than rare: a show whose genre nothing could establish. The
    // stored value is "other" and it must never be what a person hears.
    //
    // #1657: and what is heard is the same thing the card shows, which is that no genre was read. It does
    // not announce a genre and then contradict itself, and it offers to SET one rather than to change a
    // genre that does not exist.
    @Test func anUnestablishedGenreIsAnnouncedTheWayTheCardShowsIt() {
        let label = GenreControlCopy.accessibilityLabel(for: "other")
        #expect(label.contains(Discipline.other.label))
        #expect(!label.contains("other"), "the raw stored value is not a word Dan uses")
        #expect(label.lowercased().contains("set it"))
    }

    // A label that only names the genre says nothing about what the control DOES, which is the whole
    // defect this issue was filed for, arriving through the audio channel instead of the visual one.
    @Test func itSaysThatItCanBeChanged() {
        #expect(GenreControlCopy.accessibilityLabel(for: "dance").lowercased().contains("change"))
    }

    // Any genre the app can store is announced, so a new one added later cannot fall through to an
    // empty label.
    @Test func everyGenreTheAppCanStoreGetsARealLabel() {
        for discipline in Discipline.allCases {
            let label = GenreControlCopy.accessibilityLabel(for: discipline.rawValue)
            #expect(!label.isEmpty)
            #expect(label.contains(QueueModel.disciplineLabel(discipline.rawValue)))
        }
    }
}
