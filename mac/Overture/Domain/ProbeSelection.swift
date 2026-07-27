import Foundation

// #1597 (milestone 32 Phase 4.4 to 4.6): what Dan is about to spend, and whether he is allowed to.
//
// Selecting dates is the moment a reachability check stops being a small opt-in action and becomes a
// real commitment. The running bar and the confirm sheet both read THIS, never their own counts, so the
// figure he is shown while choosing and the figure he approves can never disagree.
//
// The estimate is TIME, and deliberately not money. The tool reports a dollar cost, but Dan runs this on
// a Max plan where that figure is an API-equivalent number and not a bill he ever receives; putting it on
// screen implied a charge that does not exist (his call, 2026-07-27: "we are not using the api"). What a
// check actually spends is his time and his rolling usage window, so that is what the bar says.
enum ProbeSelection {

    // How long one lookup takes. Measured 2026-07-27: the first real check took 471 seconds for three
    // shows run one after another, so about 157 seconds each. A single named constant, so a second
    // measurement changes every sentence quoting a wait at once.
    //
    // One sample, on three Carnegie-affiliated organisations, which are unusually well documented. A
    // night of small indie productions could take longer (more searching before giving up) or less
    // (gives up sooner). An order of magnitude, which is all this needs to be.
    static let measuredSecondsPerLookup: TimeInterval = 157

    // Lookups run concurrently, so the wait is the number of ROUNDS, not the number of lookups. MUST
    // match OVERTURE_PREP_MAX_PARALLEL default in mac/scripts/prep-run.sh: if this is higher than the
    // runner's real cap the bar promises a wait the run cannot keep.
    static let maxConcurrentLookups = 10

    // The ceiling. Above this, the check is REFUSED rather than warned about.
    //
    // A warning is the wrong instrument: the failure mode is one tick on a week going through because
    // the confirm looked like the confirm he has clicked through a dozen times, and by then the usage
    // window is gone. Sized to let a few nights pass freely (40 lookups is about four typical nights,
    // roughly eleven minutes) while stopping a whole week from being committed by accident. Nothing is
    // lost by refusing: the same dates run fine in two batches.
    static let maxResearchesPerRun = 40

    struct Summary: Equatable {
        let dateCount: Int
        // Shows that will get an answer. Includes the ones a grouped item answers for, because Dan
        // selected them and they do come home with a contact.
        let showCount: Int
        // What the run is actually PAID for, after collapsing a producer's shows to one research.
        let researchCount: Int
        let organisationCount: Int
        let performerHuntCount: Int
        // Selected shows already answered recently, which cost nothing and are not re-researched.
        let alreadyAnsweredCount: Int
        // Wall clock, not work: lookups overlap, so this is rounds times one lookup.
        let estimatedSeconds: TimeInterval
        // True when the run is refused. Never a warning: see maxResearchesPerRun.
        let overCeiling: Bool

        var isEmpty: Bool { showCount == 0 && alreadyAnsweredCount == 0 }
    }

    // `candidateKeys` is what the date control already computes: the still-open, not-recently-answered
    // shows on the selected dates. `answeredKeys` is the rest of the selection, carried separately so
    // the confirm can say plainly that they cost nothing rather than silently omitting them (a count
    // that quietly drops shows is how a pill stops being a promise about rows).
    static func summarize(dateCount: Int, candidates: [ProbeBatch.Show], alreadyAnswered: Int,
                          among all: [ProbeBatch.Show], promoted: Set<String> = []) -> Summary {
        let plan = ProbeBatch.plan(selecting: Set(candidates.map(\.key)), among: all, promoted: promoted)
        let researches = plan.keysToRun.count
        return Summary(
            dateCount: dateCount,
            showCount: plan.selectedCount,
            researchCount: researches,
            organisationCount: plan.organisationCount,
            performerHuntCount: plan.performerHuntCount,
            alreadyAnsweredCount: alreadyAnswered,
            estimatedSeconds: estimatedSeconds(forLookups: researches),
            overCeiling: researches > maxResearchesPerRun)
    }

    // Rounds, never the sum. Estimating the sum would tell Dan a four-minute check takes an hour and a
    // half, and he would never run it.
    static func estimatedSeconds(forLookups lookups: Int) -> TimeInterval {
        guard lookups > 0 else { return 0 }
        let rounds = (lookups + maxConcurrentLookups - 1) / maxConcurrentLookups
        return Double(rounds) * measuredSecondsPerLookup
    }
}

// The sentences. Kept beside the arithmetic so a number and the words around it are changed together.
enum ProbeSelectionCopy {

    // The running bar, while Dan is ticking dates. Says what is selected and how long it will take,
    // because the wait is the thing he cannot work out for himself and most needs before clicking.
    static func selectionSummary(_ s: ProbeSelection.Summary) -> String {
        let dates = s.dateCount == 1 ? "1 date" : "\(s.dateCount) dates"
        let shows = s.showCount == 1 ? "1 show" : "\(s.showCount) shows"
        return "\(dates), \(shows)"
    }

    // The saving is worth saying out loud only when there IS one: on a night of one-off productions
    // every show is its own hunt and "40 shows, 40 lookups" would be a second telling of the first half.
    static func costLine(_ s: ProbeSelection.Summary) -> String {
        let lookups = s.researchCount == 1 ? "1 lookup" : "\(s.researchCount) lookups"
        let wait = durationLabel(s.estimatedSeconds)
        if s.researchCount < s.showCount {
            return "\(lookups), \(wait): shows by the same producer share one."
        }
        return "\(lookups), \(wait)."
    }

    static func durationLabel(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "under a minute" }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "about 1 minute" : "about \(minutes) minutes"
    }

    static let clearSelection = "Clear"

    // The refusal. Says the number, why there is a limit at all, and the way forward, so it is an
    // instruction rather than a wall.
    static func overCeilingMessage(_ s: ProbeSelection.Summary) -> String {
        "That is \(s.researchCount) lookups, \(durationLabel(s.estimatedSeconds)). "
            + "Overture stops at \(ProbeSelection.maxResearchesPerRun) in one run so a whole week "
            + "cannot go on one click. Select fewer dates and run them in batches."
    }

    // The confirm title is the SAME question whether one date or seven produced the list, so it is
    // ReachabilityProbeCopy's sentence, not a second copy of it here. Written out again, the two would
    // drift and Dan would meet two subtly different versions of one question.
    static func multiDateTitle(_ s: ProbeSelection.Summary) -> String {
        ReachabilityProbeCopy.confirmTitle(count: s.showCount)
    }

    static func multiDateMessage(_ s: ProbeSelection.Summary) -> String {
        var parts: [String] = []
        parts.append("This looks up a real contact for every still-open show on the "
                     + (s.dateCount == 1 ? "date" : "\(s.dateCount) dates") + " you picked.")
        // What the money buys, split the way it actually divides: a producer answered once for all its
        // shows, versus a one-off hunt that answers for exactly one.
        if s.organisationCount > 0 && s.performerHuntCount > 0 {
            parts.append(s.organisationCount == 1
                         ? "1 named producer answers for several of them; \(s.performerHuntCount) "
                             + (s.performerHuntCount == 1 ? "show is" : "shows are") + " a one-off hunt."
                         : "\(s.organisationCount) named producers answer for several shows each; "
                             + "\(s.performerHuntCount) "
                             + (s.performerHuntCount == 1 ? "show is" : "shows are") + " a one-off hunt.")
        } else if s.performerHuntCount > 0 {
            parts.append("Every one is a one-off hunt, so none of them share an answer.")
        }
        // Never silently omit the shows that cost nothing: a count that drops rows stops being a promise.
        if s.alreadyAnsweredCount > 0 {
            parts.append("\(s.alreadyAnsweredCount) more "
                         + (s.alreadyAnsweredCount == 1 ? "show was" : "shows were")
                         + " checked recently and are not looked up again.")
        }
        parts.append(ProbeSelectionCopy.costLine(s))
        return parts.joined(separator: " ")
    }
}
