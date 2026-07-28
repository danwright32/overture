import Testing
@testable import Overture

// #1533: the editor now carries the GENRE alone. Production type left with the badge that used to
// prompt for it: Dan does not research self-produced versus agency-presented, so the app stopped
// asking. This pure resolver decides, from the scout's stored genre and Dan's pick, whether anything
// needs writing at all. It keeps that decision out of the SwiftUI view, where it could not be tested.
@Suite("Genre editor resolution (#1533)")
struct ClassificationResolutionTests {
    @Test func pickingTheGenreAlreadyStoredWritesNothing() {
        #expect(ClassificationResolution.resolve(currentDiscipline: "music", selectedDiscipline: .music)
                == .unchanged)
    }

    @Test func pickingADifferentGenreCorrectsIt() {
        #expect(ClassificationResolution.resolve(currentDiscipline: "music", selectedDiscipline: .dance)
                == .correct(discipline: .dance))
    }

    // LIVE-STORE-CLAIM verified=2026-07-28 measure="undecided rows stored as the catch-all genre, against all undecided rows"
    // The unreadable-genre case, 318 of the 556 undecided rows on the live store: the scout found no
    // genre word and stored `other`. Correcting that is the whole reason this editor survived #1533.
    @Test func namingAGenreTheScoutCouldNotReadCorrectsIt() {
        #expect(ClassificationResolution.resolve(currentDiscipline: "other", selectedDiscipline: .theater)
                == .correct(discipline: .theater))
    }

    // A stored value no enum case matches (the legacy "choral" DisciplineMigration retires, or an empty
    // string) must NOT read as unchanged. The editor shows such a row as "Performance" (`.other`), so
    // confirming that has to WRITE `other`, or the picker would show one thing while the store kept
    // another, with no way left to reconcile them.
    @Test func anUnreadableStoredGenreIsCorrectedRatherThanTreatedAsUnchanged() {
        #expect(ClassificationResolution.resolve(currentDiscipline: "choral", selectedDiscipline: .other)
                == .correct(discipline: .other))
        #expect(ClassificationResolution.resolve(currentDiscipline: "", selectedDiscipline: .other)
                == .correct(discipline: .other))
    }
}
