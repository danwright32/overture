import Foundation

// Resolves one Confirm on the genre editor into either leaving the scout's value alone or correcting
// it. Pure and testable, so the SwiftUI editor only binds a picker and calls this; see
// ClassificationResolutionTests.
//
// #1533 cut the production type out of this. The editor used to carry both dimensions because it was
// reached from a badge that claimed to be unsure of both; that badge is gone, and production type is
// no longer a question the app puts to Dan at all.
enum ClassificationResolution: Equatable {
    case unchanged
    case correct(discipline: Discipline)

    static func resolve(currentDiscipline: String, selectedDiscipline: Discipline) -> ClassificationResolution {
        // A raw-string comparison, deliberately, NOT `Discipline(rawValue: current) == selected`. A stored
        // value no case matches (the legacy "choral", an empty string) shows in the picker as `.other`, and
        // confirming that has to WRITE `other` rather than read as "nothing changed", or the picker would
        // show one genre while the store kept another.
        selectedDiscipline.rawValue == currentDiscipline ? .unchanged : .correct(discipline: selectedDiscipline)
    }
}
