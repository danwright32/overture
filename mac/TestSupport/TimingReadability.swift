import Foundation

// #3918: is a timing run steady enough to judge a ceiling against, or was it measuring the machine?
//
// WHAT WAS MEASURED, and it is why this exists rather than being a precaution. The live store cost
// suite was run twice on 2026-09-23, ten minutes apart, against the same store and the same code:
//
//   quiet:  the prospect fetch 205.5 ms, five runs spanning 203.6 to 212.5   (4% of the median)
//   loaded: the prospect fetch 694.7 ms, five runs spanning 353.1 to 902.3   (79% of the median)
//
// The second was taken at a one minute load average of 51.6. Its per row figure was 0.5207 ms against
// the shipped ceiling of 0.50, so the ratchet FAILED on code that had not changed. A red there is
// indistinguishable from a real regression, which is the whole problem (L411, L224).
//
// AND THE JUSTIFICATION IN THE CODE WAS WRONG, which is worth recording because it reads convincingly.
// `fetchCeilingMsPerRow` argued that a per row rate "is also immune to how busy this Mac is in a way no
// absolute millisecond figure can be (L224), because both terms move together". The two terms of that
// rate are MILLISECONDS and ROWS, and a row count does not move when the machine gets busy. Dividing by
// it removes the store's growth from the reading, which is real and is why the rate is the right shape,
// but it removes nothing at all of the machine's load.
//
// WHAT ACTUALLY MAKES A READING JUDGEABLE is a quantity measured in the SAME run, which is what L224
// asks for in as many words. This run already measures one: the spread of its own repeats. A quiet
// machine repeats itself closely and a contended one does not, and the separation between the two
// measurements above is not marginal, it is 4% against 79%.
//
// THE THRESHOLD sits between them with room on both sides rather than just above the quiet reading, so
// an ordinary busy afternoon does not start reporting UNMEASURED and an ordinary quiet one does not
// start passing things it should refuse (L172).
enum TimingReadability {

    /// How far apart the repeats of one timing may be, as a fraction of their own median, before the run
    /// is too unsteady to judge a ceiling against.
    ///
    /// Declared here rather than inline so a change to it is a visible edit to a named calibration.
    /// 0.25 is six times the quiet reading's 4% and a third of the loaded one's 79%.
    static let steadySpreadFraction = 0.25

    /// Three answers, never two, and `unmeasurable` is never folded into either (L98, L11).
    ///
    /// A run that could not be judged and a run that passed call for opposite next steps: the first says
    /// take the reading again on a quiet machine, the second says the code is within its ceiling. A
    /// guard that reported the first as the second would go quiet exactly when the Mac is busiest, and
    /// one that reported it as a failure would accuse the code of a regression the machine caused.
    enum Verdict: Equatable {
        case steady
        case unmeasurable(spreadFraction: Double)
        /// No repeat was taken, or the median was zero, so there is no spread to read at all. Its own
        /// case because "the run was steady" is a claim this cannot make about it.
        case noReading
    }

    /// Judge one timing by the spread of its own repeats.
    ///
    /// `low` and `high` are the extremes of the repeats and `median` their middle, which is what the
    /// suite's own `timedInAFreshContext` already returns, so nothing new has to be measured to ask this.
    static func verdict(low: Double, high: Double, median: Double) -> Verdict {
        guard median > 0, high >= low else { return .noReading }
        let fraction = (high - low) / median
        return fraction <= steadySpreadFraction ? .steady : .unmeasurable(spreadFraction: fraction)
    }

    /// The widest of several timings' verdicts, so a run is judged by its LEAST steady arm.
    ///
    /// Least steady rather than average, deliberately: the arms are read against each other as well as
    /// against their ceilings, so one arm bouncing makes every comparison in the run unreliable, not
    /// just its own.
    static func worst(of verdicts: [Verdict]) -> Verdict {
        if verdicts.isEmpty { return .noReading }
        if verdicts.contains(.noReading) { return .noReading }
        let unsteady = verdicts.compactMap { v -> Double? in
            if case .unmeasurable(let f) = v { return f }
            return nil
        }
        guard let worst = unsteady.max() else { return .steady }
        return .unmeasurable(spreadFraction: worst)
    }
}
