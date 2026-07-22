import Testing
@testable import Overture

// The one Confirm interaction on the classification editor (#1363) carries BOTH genre and
// production. This pure resolver decides, from the scout's current guess and Dan's selection,
// whether he accepted the guess as-is (mark reviewed, no override) or corrected a dimension
// (write only the changed one, so classificationOverriddenByDan reflects a real change). It
// keeps that decision out of the SwiftUI view, where it could not be tested (#863).
@Suite("Classification editor resolution (#1363)")
struct ClassificationResolutionTests {
    @Test func selectingTheSameGuessAcceptsItAsIs() {
        let r = ClassificationResolution.resolve(
            currentDiscipline: "music", currentProduction: "agency",
            selectedDiscipline: .music, selectedProduction: .agency)
        #expect(r == .acceptAsIs)
    }

    @Test func changingOnlyGenreCorrectsGenreAlone() {
        let r = ClassificationResolution.resolve(
            currentDiscipline: "music", currentProduction: "agency",
            selectedDiscipline: .dance, selectedProduction: .agency)
        #expect(r == .correct(discipline: .dance, production: nil))
    }

    @Test func changingOnlyProductionCorrectsProductionAlone() {
        let r = ClassificationResolution.resolve(
            currentDiscipline: "music", currentProduction: "agency",
            selectedDiscipline: .music, selectedProduction: .selfProduced)
        #expect(r == .correct(discipline: nil, production: .selfProduced))
    }

    @Test func changingBothCorrectsBothInOnePass() {
        let r = ClassificationResolution.resolve(
            currentDiscipline: "music", currentProduction: "unknown",
            selectedDiscipline: .opera, selectedProduction: .selfProduced)
        #expect(r == .correct(discipline: .opera, production: .selfProduced))
    }
}
