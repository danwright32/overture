import Foundation

// #1597 (milestone 32 Phase 4.4 to 4.6): what Dan is about to spend, and whether he is allowed to.
//
// Selecting dates is the moment a reachability check stops being a small opt-in action and becomes a
// real spending decision: measured at about $1.36 per research (2026-07-27, $4.08 for three shows), one
// tick on a week is roughly a $90 click. So the selection carries its own arithmetic, and the running
// bar and the confirm sheet both read THIS, never their own counts, so the number he is shown while
// choosing and the number he approves can never disagree.
enum ProbeSelection {

    // The measured price of researching one entry. Deliberately a single named constant rather than a
    // number inlined in copy: when a second measurement lands it changes in one place, and every
    // sentence quoting money changes with it.
    //
    // One sample, on three Carnegie-affiliated organisations, which are unusually well documented. A
    // night of small indie productions could cost more (more searching before giving up) or less (gives
    // up sooner). Treat the estimate as an order of magnitude, which is all a brake needs.
    static let measuredUSDPerResearch = 1.36

    // The ceiling. Above this, the check is REFUSED rather than warned about.
    //
    // A warning is the wrong instrument here: the failure mode is one tick on a week going through
    // because the confirm looked like the confirm he has clicked through a dozen times, and by the time
    // he sees the number it has been spent. Sized to let a few nights pass freely (40 researches is
    // about four typical nights) while stopping a week, which is roughly 90 dollars, from happening by
    // accident. Dan can always run the nights in batches.
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
        let estimatedUSD: Double
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
            estimatedUSD: (Double(researches) * measuredUSDPerResearch * 100).rounded() / 100,
            overCeiling: researches > maxResearchesPerRun)
    }
}

// The sentences. Kept beside the arithmetic so a number and the words around it are changed together.
enum ProbeSelectionCopy {

    // The running bar, while Dan is ticking dates. Says what is selected and what it will cost, because
    // the cost is the thing he cannot work out for himself and the thing he most needs before clicking.
    static func selectionSummary(_ s: ProbeSelection.Summary) -> String {
        let dates = s.dateCount == 1 ? "1 date" : "\(s.dateCount) dates"
        let shows = s.showCount == 1 ? "1 show" : "\(s.showCount) shows"
        return "\(dates), \(shows)"
    }

    // The saving is worth saying out loud only when there IS one: on a night of one-off productions
    // every show is its own hunt and "40 shows, 40 lookups" would be a second telling of the first half.
    static func costLine(_ s: ProbeSelection.Summary) -> String {
        let lookups = s.researchCount == 1 ? "1 lookup" : "\(s.researchCount) lookups"
        let money = String(format: "about $%.2f", s.estimatedUSD)
        if s.researchCount < s.showCount {
            return "\(lookups), \(money): shows by the same producer share one."
        }
        return "\(lookups), \(money)."
    }

    static let clearSelection = "Clear"

    // The refusal. Says the number, why there is a limit at all, and the way forward, so it is an
    // instruction rather than a wall.
    static func overCeilingMessage(_ s: ProbeSelection.Summary) -> String {
        "That is \(s.researchCount) lookups, about $\(String(format: "%.0f", s.estimatedUSD)). "
            + "Overture stops at \(ProbeSelection.maxResearchesPerRun) in one run so a week cannot be "
            + "spent on one click. Select fewer dates and run them in batches."
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
