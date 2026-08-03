import Foundation

// The positive "still alive" signal for a detached AI run (#435): elapsed time since the run was
// requested, formatted for the spinner ("Drafting a reply… 0:45"). Shared by the reply drafter, Prep,
// and scout so a working / still-alive run reads differently from a bare indefinite spinner. Pure: the
// view feeds it a start time and the current instant from a TimelineView; this only formats.
enum RunProgress {
    static func elapsedLabel(since start: Date?, now: Date) -> String? {
        guard let start else { return nil }
        let total = max(0, Int(now.timeIntervalSince(start)))   // clamp clock skew to zero, never negative
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // The full spinner caption: "Drafting a reply… 0:45" while a start time is known, or the plain
    // "Drafting a reply…" when it isn't. The trailing ellipsis stays so a counter-less run still reads
    // as in-progress. `detail` (#354, e.g. "3 of 9" from a run's own progress file) inserts before the
    // ellipsis when present: "Prepping 3 of 9… 0:45".
    // #885: the STALLED sentence, the one label LiveRunLabel did not get from here. RunProgress.liveness
    // already decides THAT a run is stalled; it should also say so. An asymmetry with nothing holding it
    // in place is an asymmetry that drifts.
    static func stalledLabel(_ base: String, elapsed: String) -> String {
        "\(base) looks stuck (\(elapsed))"
    }

    // #1822: the run has ended and its screen is closing itself. Deliberately does NOT repeat the phase
    // title: in the takeover that title is already on screen directly above this line, and in the
    // toolbar this sentence is only ever visible for a moment (#843, do not say twice what the line
    // beside it already said).
    static func finishingLabel(elapsed: String) -> String {
        "Finishing up (\(elapsed))"
    }

    // #1684: the run is stopping at Dan's request. Says "Stopping" rather than "Stopped", because it has
    // not stopped yet and claiming it had would be the same dishonesty in the other direction. Carries the
    // elapsed counter for the same reason the other states do: it is the evidence that the screen is still
    // alive rather than frozen, which is exactly what he could not tell.
    //
    // Names the RUN rather than standing alone as one word, so it sits beside "Finishing up" as a sentence
    // and so `docs/copy-inventory.md` carries it: that inventory skips a one-word literal, and a sentence
    // Dan reads that never reaches the list nobody can cold-read is exactly what the list exists to stop.
    static func stoppingLabel(elapsed: String) -> String {
        "Stopping the run (\(elapsed))"
    }

    static func spinnerLabel(_ base: String, since start: Date?, now: Date, detail: String? = nil) -> String {
        let label = detail.map { "\(base) \($0)" } ?? base
        if let elapsed = elapsedLabel(since: start, now: now) {
            return "\(label)… \(elapsed)"
        }
        return "\(label)…"
    }

    // #436: the single three-state decision every long action routes through. Given the run's start,
    // the current instant, and its expected window, report whether the run is idle, still working/alive
    // (with the elapsed counter), or past its timeout and stalled (an actionable failed state, not an
    // indefinite spinner). The boundary is `>=` so it matches Recipient.isReplyDraftStalled.
    //
    // #471: a fixed wall-clock timeout alone can't tell a genuinely dead run from one that's just
    // slower than usual, so the run's real heartbeat (marker freshness) overrides the clock.
    // #1822: takes the heartbeat's three states rather than a Bool. See RunHeartbeat for why absence and
    // staleness cannot share one answer. `nil` means the caller has no marker to read at all, which keeps
    // the wall clock in charge exactly as it was before any heartbeat existed.
    static func liveness(since start: Date?, now: Date, timeout: TimeInterval,
                         heartbeat: RunHeartbeat? = nil,
                         cancelRequested: Bool = false) -> RunLiveness {
        guard let start, let elapsed = elapsedLabel(since: start, now: now) else { return .idle }
        // A marker that is GONE ends the run whatever the clock says: a runner deletes it in its exit
        // trap, so this is the last thing a healthy run does, not a symptom. Checked BEFORE the stop
        // below, because a stopped run whose marker has already gone is over, and "Stopping" there would
        // be a screen claiming work is still winding down after it has ended.
        if heartbeat == .absent { return .finishing(elapsed: elapsed) }
        // #1684: Dan asked this run to stop, so the screen says so. It outranks both remaining verdicts.
        // Not `running`, because a spinner identical to a working run is what made him press Cancel three
        // more times and call it broken. Not `stalled` either: past the timeout a stopped run would
        // otherwise accuse itself of being stuck and offer him a Retry, when nothing has gone wrong and he
        // is the one who stopped it.
        if cancelRequested { return .stopping(elapsed: elapsed) }
        if now.timeIntervalSince(start) >= timeout {
            return heartbeat == .beating ? .running(elapsed: elapsed) : .stalled(elapsed: elapsed)
        }
        return .running(elapsed: elapsed)
    }

    // #1684: may a run Dan STOPPED be treated as over yet?
    //
    // A cancelled run's heartbeat stops at once: `prep-run.sh`'s heartbeat loop reads the sentinel on a
    // short poll and exits, so nothing touches the marker again. Waiting the full ordinary stale window
    // after that is waiting on a clock rather than on evidence, and it is the three minutes of silence Dan
    // sat through. Once the marker has missed a beat it would certainly have made, the run is done.
    //
    // Judged on the MARKER rather than on the request, so a runner that has not yet noticed the sentinel
    // (it polls every few seconds) keeps the run alive by doing what a live run does. Declaring one dead
    // while it is still working would report a live run as finished, which is the worse error of the two.
    static func stoppedRunIsOver(cancelRequestedAt: Date?, markerTouchedAt: Date?, now: Date,
                                 grace: TimeInterval = RunTimeouts.stoppedRunGrace) -> Bool {
        guard let cancelRequestedAt, now.timeIntervalSince(cancelRequestedAt) > grace else { return false }
        // No marker reading at all is not evidence of life, so it cannot hold a stopped run open.
        guard let markerTouchedAt else { return true }
        return now.timeIntervalSince(markerTouchedAt) > grace
    }

    // #1530: the in-process scout sweep's heartbeat, folded to beating or stale for `liveness` above.
    //
    // A detached run proves it is alive by touching a marker file; the sweep has no marker, so it was
    // judged on wall clock alone and every 62-source run ended by claiming to be stuck. What it does have
    // is a per-source signal (ScoutService's onNativeProgress fires as each source lands), so "a source
    // landed within the last `window`" is the same kind of positive still-alive evidence, and it holds
    // however long the whole sweep runs.
    //
    // `nil` (not one source has landed yet) reads as not-alive on purpose: there is no heartbeat to trust,
    // so RunTimeouts.scout stays in charge, which is the wedged-on-the-first-source case it was written
    // for. Clock skew (a stamp in the future) reads as alive, matching elapsedLabel's clamp.
    static func sweepIsAlive(lastProgressAt: Date?, now: Date,
                             window: TimeInterval = RunTimeouts.scoutSourceStep) -> Bool {
        guard let lastProgressAt else { return false }
        return now.timeIntervalSince(lastProgressAt) < window
    }
}

// The three visibly-distinct states the saved UX principle requires of any non-instant action:
// nothing in flight, working/still-alive, or stalled/failed. Carries the elapsed counter on both live
// states so the stalled case still shows how long it has been stuck.
//
// #472: a deliberately different, narrower vocabulary from DetachedRunPhase
// (DetachedRunOutcome.swift), not an oversight. This answers "what should the UI show right now
// while something might still be in flight" (a continuous, per-second question, driving
// LiveRunLabel); DetachedRunPhase answers "the moment a detached run stopped, what did it
// produce" (a one-shot terminal question). Evaluated folding them into one vocabulary per #472
// and deliberately didn't: the two are used in disjoint call sites for different lifecycle
// moments, so a single flat enum would just give each side dead cases it can never see.
enum RunLiveness: Equatable {
    case idle
    case running(elapsed: String)
    // #1822: the run has ended and its screen is about to close. Neither working nor stuck, because it
    // is neither: the runner deleted its marker in its exit trap, which is how a HEALTHY run finishes.
    case finishing(elapsed: String)
    // #1684: Dan pressed Cancel and the request has been accepted. Distinct from every state around it,
    // because it is a distinct fact: the run is neither working nor stuck nor finished, it is winding down
    // at his request. A stop with no state of its own is a control that keeps offering itself after being
    // pressed, which reads as broken (L44).
    case stopping(elapsed: String)
    case stalled(elapsed: String)
}

// #1822: what a run marker actually says, kept as three states because it has three things to say and a
// Bool could only carry two. A runner touches its marker while it works and deletes it on the way out,
// so absence means FINISHED while staleness means WEDGED. Collapsing those into one "not alive" is what
// made every Prep run long enough to pass its timeout accuse itself of being stuck in the seconds
// between the runner exiting and the screen noticing.
enum RunHeartbeat: Equatable {
    case beating
    case stale
    case absent

    // Clock skew (a stamp in the future) reads as beating, matching elapsedLabel's clamp.
    static func of(markerTouchedAt: Date?, now: Date, staleAfter: TimeInterval) -> RunHeartbeat {
        guard let markerTouchedAt else { return .absent }
        return now.timeIntervalSince(markerTouchedAt) < staleAfter ? .beating : .stale
    }
}
