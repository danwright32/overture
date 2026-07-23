import Foundation

// #5 (opener A/B testing), Phase 4: the pure reporting logic behind ExperimentReportView. Mirrors
// OutcomePatterns/OutcomeStats (all rate math lives in OutcomeStats, tested), but groups by the
// APP-ASSIGNED arm and scopes to one experiment. Kept pure and out of any view (#863) so every honesty
// rule below is testable rather than assembled in a SwiftUI body.
//
// Honesty rules baked in (Dan's decisions, #1377):
//  - Tally on the app-assigned arm (Prospect.assignedArm), NEVER the drafter's echo (draftVariant). The
//    echo is used ONLY to compute a compliance/drift rate, so a flat result can't be silently misread as
//    "arms don't matter" when the truth is "the drafter never produced the assigned arm".
//  - EXCLUDE a send whose assigned opener Dan materially rewrote (experimentOpenerEdited) from the rate,
//    but keep it visible as its own count, so a reply to a rewrite is never credited to the assigned arm.
//  - A deliberately HIGH sample bar (experimentCallThreshold, NOT OutcomePatterns.lowSampleThreshold = 4,
//    which is for flagging thin slices and is near-decorative for a pairwise reply-rate call). The report
//    NEVER declares a winner (that is #4); the bar only gates the "too few to tell" banner, and stays in
//    effect until BOTH arms clear it.
enum ExperimentReport {
    // High on purpose: 4 (OutcomePatterns) would let a 4-vs-1 split read as signal. Dan's call is to keep
    // it high and never auto-call a winner, so this is only the "too few to tell" line, not a decision.
    static let experimentCallThreshold = 30

    // One arm's numbers. `tally` counts only SENT, NON-edited prospects (the honest rate base); edited
    // sends are surfaced separately in `editedExcluded`. Compliance is echo-matches-assigned among that
    // same counted set.
    struct ArmReport: Equatable, Sendable {
        var arm: String
        var tally: OutcomeTally
        var editedExcluded: Int
        var complianceMatched: Int
        var complianceTotal: Int

        // Share of counted sends where the drafter actually produced the assigned arm. Nil when nothing
        // counted (avoid 0/0). A low value means the reply-rate comparison is meaningless.
        var complianceRate: Double? {
            complianceTotal == 0 ? nil : Double(complianceMatched) / Double(complianceTotal)
        }
        // The two numbers that gate the deferred #4 auto-tune, surfaced so nobody builds it blind: live
        // counted volume for this arm, and how often Dan rewrote the opener on this arm's sends.
        var countedSends: Int { complianceTotal }
        var rewriteRate: Double? {
            let totalSent = complianceTotal + editedExcluded
            return totalSent == 0 ? nil : Double(editedExcluded) / Double(totalSent)
        }
    }

    struct Report: Equatable, Sendable {
        var experimentId: String
        var arms: [ArmReport]

        // Both arms must clear the bar before the report will present a rate difference as meaningful.
        // Per-arm-independent would let one thin arm ride on the other's volume.
        var bothArmsClearBar: Bool {
            !arms.isEmpty && arms.allSatisfy { $0.tally.contacted >= experimentCallThreshold }
        }
        var tooFewToTell: Bool { !bothArmsClearBar }
    }

    // Build the report for one experiment from the whole prospect set. Scopes to prospects stamped with
    // this experiment's id, then one ArmReport per defined variant (so an arm with zero sends still shows).
    static func report(for experiment: Experiment, allProspects: [Prospect]) -> Report {
        let scoped = allProspects.filter { $0.experimentID == experiment.experimentId }
        let arms = [experiment.variantA, experiment.variantB].map { armReport(arm: $0, in: scoped) }
        return Report(experimentId: experiment.experimentId, arms: arms)
    }

    static func armReport(arm: String, in scopedProspects: [Prospect]) -> ArmReport {
        let armProspects = scopedProspects.filter { $0.assignedArm == arm }
        let sent = armProspects.filter { $0.wasProvablyContacted }
        // A send whose assigned opener Dan rewrote is excluded from the rate but counted separately.
        let counted = sent.filter { !$0.experimentOpenerEdited }
        let editedExcluded = sent.count - counted.count
        let samples = counted.map { p -> OutcomeSample in
            // A reply lives on the contact, not the lead outcome (the OutcomePatterns rule): count an
            // otherwise-unresolved lead as replied when a contact wrote back.
            let effectiveOutcome: Outcome =
                (p.outcome == .noResponse && p.recipients.contains(where: \.replied)) ? .replied : p.outcome
            return OutcomeSample(wasContacted: true, outcome: effectiveOutcome, dimension: arm)
        }
        let tally = OutcomeStats.tally(samples)
        // Compliance: the drafter's echo (draftVariant) matching the assigned arm, among counted sends.
        let matched = counted.filter { $0.draftVariant == arm }.count
        return ArmReport(arm: arm, tally: tally, editedExcluded: editedExcluded,
                         complianceMatched: matched, complianceTotal: counted.count)
    }

    // MARK: - Display helpers (mirror OutcomePatterns, so the view just renders)

    // Reply rate for an arm, hidden entirely below the bar (a rate over a handful of sends is noise wearing
    // the costume of a number). "Replied" includes those who booked (a booking is a reply).
    static func replyLine(_ arm: ArmReport, tooFewToTell: Bool) -> String {
        let base = "\(arm.tally.replied + arm.tally.booked) replied of \(arm.tally.contacted)"
        return tooFewToTell ? base : base + OutcomePatterns.percentSuffix(arm.tally.responseRate)
    }

    // The honest low-N banner, naming the bar. Lives here (not the view) so the interpolation of the
    // threshold is testable copy, not a sentence computed in a SwiftUI body (#863).
    static func tooFewToTellLine() -> String {
        "Too few sends to call anything yet. Both styles need at least \(experimentCallThreshold) sends before the reply rates mean much."
    }

    // Only shown when there is something to say (never "0 excluded"). Carries the opener-rewrite RATE,
    // one of the two numbers that gate the deferred #4 auto-tune (#1396): the raw edited count is already
    // here, so the % is the only new number and it rides this same line rather than a duplicate one (#843).
    static func editedExcludedLine(_ arm: ArmReport) -> String? {
        guard arm.editedExcluded > 0 else { return nil }
        guard let rate = arm.rewriteRate else {
            return "\(arm.editedExcluded) edited, excluded from the rate"
        }
        return "\(arm.editedExcluded) edited (\(Int((rate * 100).rounded()))% of sends), excluded from the rate"
    }

    // The other deferred-#4 gate number (#1396): this arm's counted send volume, framed as progress toward
    // the sample bar so Dan can watch each style climb toward a trustworthy read. The reply line's
    // denominator carries the same count but never relates it to the bar, and the "too few to tell" banner
    // states the bar only in the abstract, never per arm. Nil when nothing has sent yet (never "0 of 30").
    static func sendVolumeLine(_ arm: ArmReport) -> String? {
        let sends = arm.countedSends
        guard sends > 0 else { return nil }
        if sends >= experimentCallThreshold {
            return "\(sends) sends in, enough for the rate to mean something"
        }
        return "\(sends) of \(experimentCallThreshold) sends toward a reliable read"
    }

    // The drafter-compliance line: what share of this arm's counted sends actually used the assigned shape.
    // Nil (no line) when nothing counted yet.
    static func complianceLine(_ arm: ArmReport) -> String? {
        guard let rate = arm.complianceRate else { return nil }
        return "drafter used this shape on \(Int((rate * 100).rounded()))% of sends"
    }
}
