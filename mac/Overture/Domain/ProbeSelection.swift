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

    // How long one ROUND takes: one wave of concurrent lookups, whose wall clock is its slowest member.
    // Used only until enough real checks have been recorded to learn the figure (#1616).
    //
    // It says per ROUND because that is how it has always been used (`estimatedSeconds` multiplies it by
    // the round count), and until #1616 it held a per-LOOKUP number, which is the defect this issue
    // reports: 157 was measured on 2026-07-27 from three shows run ONE AFTER ANOTHER, 471 seconds for the
    // three. Since #1597 a check fans out, so that number never described a round at all.
    //
    // 390 is measured, from the only recorded check surviving on this Mac (2026-08-07): three shows in
    // three concurrent chunks, `runCost.durationMs` 389906. Its three streams took 146s, 390s and 150s, so
    // a lookup is roughly as fast beside two others as it is alone and what makes a round long is its
    // slowest member. The other observed parallel round was 3m45s (225s), also over three shows, and the
    // larger of the two is the honest fallback: a round of ten draws more slow lookups than a round of
    // three, and the failure that matters here is promising a wait the run cannot keep.
    //
    // Two samples, both on three shows, which is exactly why this is a fallback and not the answer.
    static let fallbackSecondsPerRound: TimeInterval = 390

    // #1616: the figure the bar should quote, learned where there is evidence and hand-set where there is
    // not. One named place, so no surface can consult the history and another the constant.
    static func secondsPerRound(learnedFrom history: ProbeDurationHistory) -> TimeInterval {
        history.learnedSecondsPerRound ?? fallbackSecondsPerRound
    }

    // The live read, and the only impure entry point here. Called from the two places Dan is shown a wait
    // (the selection bar, and the two confirms QueueView raises), never from a pure summarize, so a test
    // can exercise every sentence without reaching a file.
    static func liveSecondsPerRound() -> TimeInterval {
        secondsPerRound(learnedFrom: ProbeDurationHistoryStore.load())
    }

    // Lookups run concurrently, so the wait is the number of ROUNDS, not the number of lookups. MUST
    // match OVERTURE_PREP_MAX_PARALLEL default in mac/scripts/prep-run.sh: if this is higher than the
    // runner's real cap the bar promises a wait the run cannot keep.
    static let maxConcurrentLookups = 10

    // #1765: there is NO ceiling, and the refusal that used to live here is gone.
    //
    // It stopped at 40 lookups so a whole week could not go through on one accidental click. Dan hit it
    // with a deliberate 19-date, 77-show selection: "I should never be blocked by what I'm trying to do.
    // If I want to do this, let me."
    //
    // The brake could not tell an accident from a decision. A fat-fingered week and a chosen one are the
    // same shape to the code, so the only person it could ever stop was the one who meant it, while the
    // bar states the size and the wait before anything is spent and the confirm sheet is where an accident
    // gets caught. Nothing downstream breaks past 40 either: prep-run.sh already splits the work-list into
    // up to maxConcurrentLookups chunks and works each one through in order, so 77 lookups run as roughly
    // 8 rounds, which is exactly the wait the bar quoted. The refusal was asking Dan to do by hand, in two
    // clicks, the batching the runner already performs (L54).
    //
    // This also brings a check in line with what the scout already does for the same problem. A big paid
    // read is not refused there either: ScoutReadBudget asks past its threshold and lets Dan decide.

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
        // #1724: selected shows an earlier check already ran over and came home without an answer for.
        // Its exact opposite: these are the ones being paid for a SECOND time, and until this they were
        // stored as nothing at all, so the sheet counted them as ordinary first-time lookups.
        let previouslyMissedCount: Int
        // Wall clock, not work: lookups overlap, so this is rounds times how long one round takes.
        let estimatedSeconds: TimeInterval

        var isEmpty: Bool { showCount == 0 && alreadyAnsweredCount == 0 }

        // #1765: a run long enough to span more than one round of concurrent lookups. The confirm says
        // what such a run BLOCKS, because at that length losing the single run slot is a real cost and for
        // one round it is not worth a sentence.
        var spansSeveralRounds: Bool { researchCount > maxConcurrentLookups }
    }

    // #2267: the one-show re-check Dan starts from a card. Its own factory rather than a contrived call
    // into `summarize`, because the date framing does not apply (there is no selection and no producer
    // amortisation to compute across it), but the COST SENTENCE must be the same one the date confirm
    // uses, or he would meet two different accounts of what one lookup costs.
    //
    // `previouslyMissed` is 1 when an earlier check ran over this show and came home with nothing, which
    // is exactly the sentence that could change his mind about spending again.
    //
    // #1616: `secondsPerRound` is passed in rather than read here, so this stays pure and a test never
    // reaches Dan's real history file. Defaulted to the constant, so a caller that does not know quotes
    // what the app quoted before any of this existed.
    static func summarizeOneShowRecheck(previouslyMissed: Bool,
                                        secondsPerRound: TimeInterval = fallbackSecondsPerRound) -> Summary {
        Summary(dateCount: 1, showCount: 1, researchCount: 1, organisationCount: 0,
                performerHuntCount: 0, alreadyAnsweredCount: 0,
                previouslyMissedCount: previouslyMissed ? 1 : 0,
                estimatedSeconds: estimatedSeconds(forLookups: 1, secondsPerRound: secondsPerRound))
    }

    // #1805: finishing the shows a check never reached. Every one of them is being paid for a second
    // time in the sense that a run already ran over the set they were in, so `previouslyMissedCount` is
    // all of them: that is the honest count, and it is the sentence that could change his mind.
    static func summarizeShowsACheckMissed(count: Int,
                                           secondsPerRound: TimeInterval = fallbackSecondsPerRound) -> Summary {
        Summary(dateCount: 0, showCount: count, researchCount: count, organisationCount: 0,
                performerHuntCount: 0, alreadyAnsweredCount: 0, previouslyMissedCount: count,
                estimatedSeconds: estimatedSeconds(forLookups: count, secondsPerRound: secondsPerRound))
    }

    // `candidateKeys` is what the date control already computes: the still-open, not-recently-answered
    // shows on the selected dates. `answeredKeys` is the rest of the selection, carried separately so
    // the confirm can say plainly that they cost nothing rather than silently omitting them (a count
    // that quietly drops shows is how a pill stops being a promise about rows).
    // #1724: `previouslyMissed` is counted by the caller from the same selected rows, for the same reason
    // `alreadyAnswered` is: the mark lives on the row and this type never sees a row. Defaulted to 0 so a
    // caller that does not know keeps the old sentence rather than claiming nothing was missed.
    static func summarize(dateCount: Int, candidates: [ProbeBatch.Show], alreadyAnswered: Int,
                          previouslyMissed: Int = 0,
                          among all: [ProbeBatch.Show], overrides: ProducerOverrides = .none,
                          secondsPerRound: TimeInterval = fallbackSecondsPerRound) -> Summary {
        let plan = ProbeBatch.plan(selecting: Set(candidates.map(\.key)), among: all, overrides: overrides)
        let researches = plan.keysToRun.count
        return Summary(
            dateCount: dateCount,
            showCount: plan.selectedCount,
            researchCount: researches,
            organisationCount: plan.organisationCount,
            performerHuntCount: plan.performerHuntCount,
            alreadyAnsweredCount: alreadyAnswered,
            previouslyMissedCount: previouslyMissed,
            estimatedSeconds: estimatedSeconds(forLookups: researches, secondsPerRound: secondsPerRound))
    }

    // #1765: what clicking Check DOES with a selection. In Domain rather than the button's closure,
    // because that closure is unreachable by any test (#863) and it is exactly where the decision lived:
    // an early `return` in QueueView refused a large selection before the confirm sheet Dan would
    // otherwise see, so nothing could assert whether a given selection was runnable at all.
    enum Outcome: Equatable {
        // Nothing selected, or nothing left to check on what is selected: the button does nothing.
        case nothing
        // Ask, then run. The sentences come from ProbeSelectionCopy so the bar and the sheet cannot
        // disagree about what the run costs.
        //
        // #1765: this is now the ONLY outcome a non-empty selection can have, whatever its size. There is
        // deliberately no refusal case to fall into: a selection Dan is not allowed to run is a state this
        // type can no longer express, so the brake cannot come back by accident.
        case confirm(title: String, message: String)
    }

    static func outcome(for s: Summary) -> Outcome {
        guard !s.isEmpty else { return .nothing }
        return .confirm(title: ProbeSelectionCopy.multiDateTitle(s),
                        message: ProbeSelectionCopy.multiDateMessage(s))
    }

    // Rounds, never the sum. Estimating the sum would tell Dan a four-minute check takes an hour and a
    // half, and he would never run it.
    //
    // #1616: the pace is an argument, learned by the caller or left at the constant. It is the same
    // quantity either way, seconds for one wave of concurrent lookups, so nothing here changes with it.
    static func estimatedSeconds(forLookups lookups: Int,
                                 secondsPerRound: TimeInterval = fallbackSecondsPerRound) -> TimeInterval {
        guard lookups > 0 else { return 0 }
        let rounds = (lookups + maxConcurrentLookups - 1) / maxConcurrentLookups
        return Double(rounds) * secondsPerRound
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

    // #1765: what a long run BLOCKS, which is the one cost neither the title nor the wait figure carries.
    // A check holds the same single run slot a Prep run does (PrepQueueService throws .alreadyRunning), so
    // for the length of the run Dan cannot start either. The minute count tells him how long he waits for THIS; this
    // tells him what he also cannot do meanwhile, which is new information rather than a second telling
    // (#843).
    //
    // Said only for a run spanning several rounds. At three minutes the slot is not worth a sentence, and
    // a line that appears on every confirm is one he stops reading (L36).
    //
    // Modelled on ScoutReadBudget's ask, which is the same problem already solved: it states how long the
    // whole set takes and what the alternative leaves behind, and deliberately repeats nothing the buttons
    // beside it already say.
    static let blocksOtherRuns = "No Prep run or other check can start until it finishes."

    // The confirm title is the SAME question whether one date or seven produced the list, so it is
    // ReachabilityProbeCopy's sentence, not a second copy of it here. Written out again, the two would
    // drift and Dan would meet two subtly different versions of one question.
    static func multiDateTitle(_ s: ProbeSelection.Summary) -> String {
        ReachabilityProbeCopy.confirmTitle(count: s.showCount)
    }

    // #2267: the one-show version. Says what it is doing and what it costs, in that order, using the SAME
    // cost sentence as the date confirm. It deliberately does not repeat what the buttons say, and it does
    // not mention blocking other runs: one lookup is a single round, which is the case #1765 decided was
    // not worth a sentence.
    static func oneShowRecheckMessage(_ s: ProbeSelection.Summary) -> String {
        var parts = ["This looks up a real contact for this one show, even though it already has an answer."]
        parts.append(ProbeSelectionCopy.costLine(s))
        if s.previouslyMissedCount > 0 {
            parts.append("A check has already run over this show once and never got an answer for it.")
        }
        return parts.joined(separator: "\n\n")
    }

    // #1805: what finishing a short run costs, in the same sentence as every other check.
    static func finishMissedShowsMessage(_ s: ProbeSelection.Summary) -> String {
        var parts = ["This looks up a contact for the \(s.showCount) shows the last check never reached."]
        parts.append(ProbeSelectionCopy.costLine(s))
        if s.spansSeveralRounds { parts.append(blocksOtherRuns) }
        return parts.joined(separator: "\n\n")
    }

    static func multiDateMessage(_ s: ProbeSelection.Summary) -> String {
        var parts: [String] = []
        parts.append("This looks up a real contact for every still-open show on the "
                     + (s.dateCount == 1 ? "date" : "\(s.dateCount) dates") + " you picked.")
        // #1765: the wait comes SECOND, not last. The 40-lookup refusal used to be what stopped Dan walking
        // into a run of that length unaware, and with it gone the sheet has to carry that weight: at this size
        // the wait is the fact that matters, and it was sitting after the producer-sharing detail where a
        // confirm he has clicked through a dozen times would never show it to him.
        parts.append(ProbeSelectionCopy.costLine(s))
        if s.spansSeveralRounds { parts.append(blocksOtherRuns) }
        // #1724: said HERE, straight after what the run costs, because it qualifies that cost rather than
        // the breakdown below it: these shows have been through a check once already and came back with
        // nothing. It is the sentence that could change his mind about the spend, so it goes where he is
        // still reading, not after a producer split he has clicked past a dozen times.
        //
        // Silent at zero. An "0 of them" line on every ordinary confirm is one he stops seeing (L36).
        if s.previouslyMissedCount > 0 {
            // Same phrase as the run's own shortfall and the row's mark ("never got an answer"), because
            // all three are about one event and a second wording for it reads as a second thing.
            parts.append(s.previouslyMissedCount == 1
                         ? "1 of them went through an earlier check and never got an answer."
                         : "\(s.previouslyMissedCount) of them went through an earlier check and never got an answer.")
        }
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
        return parts.joined(separator: " ")
    }
}
