import Testing
@testable import Overture

// #1132: clicking "This looks right" on an unsure show only acknowledges the guess Dan saw; it does not
// lock the discipline in (only an actual correction does). So when a later scout run re-guesses the show
// as uncertain again, the old acknowledgement kept the row's "Unsure call" badge hidden over a fresh,
// unseen guess. The scout now clears that acknowledgement in exactly that case, so the badge resurfaces.
// A show Dan actually corrected stays protected. This pins the rule that decides it.
@Suite("Re-scout resurfaces the unsure badge after a plain confirm (#1132)")
struct ReScoutConfidenceAckTests {
    @Test func aFreshUncertainGuessClearsAMereConfirm() {
        #expect(ScoutService.reScoutClearsConfidenceAck(
            freshConfidence: Confidence.uncertain.rawValue, wasReviewed: true, wasOverridden: false))
    }

    // A show is confidently re-classified: nothing uncertain to resurface, so the confirm stands.
    @Test func aConfidentFreshGuessLeavesTheConfirmAlone() {
        #expect(!ScoutService.reScoutClearsConfidenceAck(
            freshConfidence: Confidence.confident.rawValue, wasReviewed: true, wasOverridden: false))
    }

    // Dan actually corrected the discipline (overridden): the scout keeps and re-scores his value rather
    // than re-guessing, so his acknowledgement must never be cleared.
    @Test func aCorrectedShowStaysProtected() {
        #expect(!ScoutService.reScoutClearsConfidenceAck(
            freshConfidence: Confidence.uncertain.rawValue, wasReviewed: true, wasOverridden: true))
    }

    // Never confirmed in the first place: the badge already shows, so there is nothing to clear (and
    // clearing a false to false is meaningless).
    @Test func anUnconfirmedShowNeedsNoClearing() {
        #expect(!ScoutService.reScoutClearsConfidenceAck(
            freshConfidence: Confidence.uncertain.rawValue, wasReviewed: false, wasOverridden: false))
    }

    // The rule is only useful if the scout's re-classify path actually calls it and acts on it. `apply`
    // is private (a full scout run can't be driven from a unit test), so this guards the wiring at the
    // source: cutting either the call or the clear brings the "silenced forever" bug back with the pure
    // tests above still green (the #887 "mutate the wire" lesson).
    @Test func applyWiresTheRuleAndClearsTheAcknowledgement() {
        let src = SourceGuardHelper.source("Overture/Integration/ScoutService.swift")
        #expect(src.contains("reScoutClearsConfidenceAck(freshConfidence: p.confidence"))
        #expect(src.contains("if clearAck { existing.confidenceReviewedByDan = false }"))
    }
}
