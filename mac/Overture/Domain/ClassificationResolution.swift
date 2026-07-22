import Foundation

// Resolves one Confirm on the classification editor (#1363) into either accepting the scout's
// guess unchanged or correcting the dimensions Dan actually changed. Pure and testable, so the
// SwiftUI editor only binds pickers and calls this; see ClassificationResolutionTests.
enum ClassificationResolution: Equatable {
    case acceptAsIs
    case correct(discipline: Discipline?, production: Production?)

    static func resolve(currentDiscipline: String, currentProduction: String,
                        selectedDiscipline: Discipline, selectedProduction: Production) -> ClassificationResolution {
        let disciplineChanged = selectedDiscipline.rawValue != currentDiscipline
        let productionChanged = selectedProduction.rawValue != currentProduction
        guard disciplineChanged || productionChanged else { return .acceptAsIs }
        return .correct(discipline: disciplineChanged ? selectedDiscipline : nil,
                        production: productionChanged ? selectedProduction : nil)
    }
}
