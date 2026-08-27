import SwiftUI

// #1034/#1010: the takeover progress surface a scout Dan started shows while it runs. He isn't doing
// anything else while a scout he clicked works, so its progress gets the whole screen instead of a
// compact toolbar label that reflows the row (#994).
//
// It covers the whole journey: the native "Scouting" phase (the fetch/hash sweep) followed by the
// detached "Reading calendars" phase (ScoutExtractService reading the pages that changed). It ends
// before Prepping, which keeps its own toolbar label.
//
// Shared, deliberately: RootView presents it as a sheet for a manual scout (#1034), reopens it on
// launch when a run is still going (#1035), AddLeadSheet renders it inline while a pasted lead is
// read (#1036), and #1130 reuses it for the Prep run's takeover. One progress surface, not several
// that drift. (It is named for the scout it first served; it is the app's shared run-progress takeover.)
//
// This is not decoration. CLAUDE.md's standing rule is that a slow action must make working, still-
// alive and failed visibly different states; the ticking counter and the stalled warning are exactly
// that, routed through the same RunProgress.liveness every other long action uses.
struct RunProgressView: View {
    // #1130: `prepping` is the detached Prep run (contact-finding + drafting per prospect), which takes
    // minutes and so needs the same visible working/stalled state as the scout rather than a bare label.
    // #1322: `probing` is a reachability probe. It reuses the same detached prep runner (so it shares the
    // prep timeout), but the takeover and toolbar label it honestly instead of "Prepping".
    // #1824: `readingListings` is the app's own render of each kept show's listing page, which runs in
    // process between Dan pressing Prep and the detached run launching. It is a separate phase from
    // `prepping` because it is a separate activity with a separate ceiling, and because a launch that
    // silently spent thirty seconds in a hidden browser before anything appeared would read as a dead
    // button.
    enum Phase: Equatable { case scouting, reading, readingListings, prepping, probing }

    // What the modal shows RIGHT NOW, re-read each tick inside the TimelineView. The caller wires this
    // to the native progress callback's captured values (scouting) or to the queue/results diff plus the
    // run's own progress file (reading), so a live read happens every second without this view knowing
    // where the numbers come from.
    struct Snapshot: Equatable {
        var sourceName: String? = nil
        var completed: Int = 0
        var total: Int = 0
        // #1530: when this snapshot last ADVANCED, i.e. when the run last landed an item. It rides on the
        // snapshot rather than sitting in the caller as a second piece of state deliberately: the caller
        // already replaces the whole snapshot on every heartbeat and already nils it when a run ends, so a
        // stamp on it cannot be forgotten in one of those paths and go stale into the next run.
        //
        // Set by the in-process sweep (the one phase with no marker file to prove it is alive). The
        // detached phases leave it nil and keep passing their marker reading as `heartbeat`.
        var advancedAt: Date? = nil
        // #2203: what the phase is doing once its COUNTED part is finished. The sweep's count pins at its
        // total the moment the fetch loop ends, with the read hand-off, the booking reconcile, the
        // blocked-town retirement and the saves still to come, so a screen showing only the count read as
        // frozen rather than as finished with one part. Once set it REPLACES the source name and the
        // count, because a count that can no longer move is a promise the screen cannot keep.
        var step: ScoutSweepStep? = nil
    }

    let phase: Phase
    // When the CURRENT phase began, for the elapsed counter and the stall window. Per-phase: the sweep
    // and the read are separate activities with separate ceilings (RunTimeouts.scout vs scoutExtract).
    let since: Date?
    var snapshot: () -> Snapshot = { Snapshot() }
    // The reading phase's real heartbeat (marker freshness), so a slow-but-living run never flips to the
    // misleading "looks stuck" state while a genuinely dead one does. nil keeps wall-clock-only behaviour.
    // #1822: the run's marker, read for all three of the things it can say. Was a Bool, which could not
    // distinguish a marker that had been deleted at the end of a healthy run from one left behind by a
    // run that died, so a finished run rendered as a stuck one.
    var heartbeat: (() -> RunHeartbeat)? = nil
    // #1427: the learned run-duration history, injected like `snapshot` so the estimate is testable and the
    // view stays ignorant of where it comes from. Read each tick; the default returns nil so every existing
    // caller (and every non-reading phase) shows no estimate, exactly as before.
    var durationHistory: () -> RunDurationHistory? = { nil }
    // Stalled-state retry: abandon the apparently-dead run and start fresh (wired by the caller).
    var onRetry: (() -> Void)? = nil
    // Dismiss-to-hide: the run keeps going untouched; the caller shows a reopen affordance.
    var onHide: (() -> Void)? = nil
    // #1037: a real Cancel that STOPS the run (cooperatively), distinct from Hide. Present only when the
    // caller supplies one: the scout takeover does; AddLeadSheet keeps its own Cancel.
    var onCancel: (() -> Void)? = nil
    // #1684: has a stop already been asked for? Read each tick, like `heartbeat`, from the same cancel
    // sentinel the runner itself obeys, so the panel and the runner can never disagree about whether the
    // click was honoured. Defaults to "no", so every caller that has no cancel to offer is unaffected.
    var cancelRequested: (() -> Bool)? = nil
    // #2201: is the run parked on a question to Dan? A run waiting for an answer is neither working nor
    // stuck, and calling it stuck points him away from the one action that would deliver the answer.
    // Read each tick like the others; defaults to "no", so every caller with nothing to ask is unaffected.
    var waitingOnAnswer: (() -> Bool)? = nil

    // #3137: how many shows this check is working through, read each tick rather than captured. A closure
    // for the same reason the heartbeat and the count are (#1003): the marker carrying the size is written
    // when the run starts, which can be after this view was constructed, and the panel re-renders every
    // second. Nil where the caller has nothing to say, which every non-probing phase does.
    var probeLookups: (() -> Int?)? = nil

    // Each phase's own stall window: an in-process sweep is quick, a detached read that follows detail
    // pages legitimately runs long, so reusing the sweep's 3-minute ceiling for the read would declare a
    // healthy run stuck (the #803 lesson).
    var timeout: TimeInterval {
        switch phase {
        case .scouting: return RunTimeouts.scout
        case .reading:  return RunTimeouts.scoutExtract
        case .readingListings: return RunTimeouts.showListingRead
        case .prepping: return RunTimeouts.prep
        // #1597: a check is not a Prep run with a different title. It shared Prep's 3-minute ceiling and
        // so reported the first real one (7m51s, working fine) as stuck at 3:38 on screen.
        // #3137: and ten minutes is a per-ROUND figure. Past the runner's fan-out cap a bigger check runs
        // deeper rather than wider, so the window follows its depth or a healthy 30 show run says it looks
        // stuck moments before it finishes.
        case .probing:  return RunTimeouts.reachabilityProbeWindow(lookups: probeLookups?())
        }
    }

    // Just the ticking content, sized to its content. The presentation chrome (the takeover's fixed
    // frame and canvas background) is applied by the caller, so the SAME view drops into RootView's
    // full-screen sheet and inline into AddLeadSheet (#1036) without one imposing the other's size.
    // #2872: one per rendered run, held across ticks. Not `@State`: it carries no observable and is
    // never read by the view's identity, so it must not take part in invalidation.
    @State private var finishingWatch = FinishingWatch()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    // Internal (not private) so RunProgressViewStateTests can call it with a fixed `now`, the same
    // reason LiveRunLabel.content(now:) is (see its #470 comment).
    @ViewBuilder func content(now: Date) -> some View {
        // Read ONCE per tick and pass it down: the same snapshot decides both what the run says and, for
        // the sweep, whether it is still alive, so reading it twice could answer the two from different
        // instants.
        let snap = snapshot()
        // #1822: a phase with a marker reports all three of its states, so a run that ENDED (marker gone,
        // the exit trap's last act) is no longer told apart from one that WEDGED (marker still sitting
        // there, untouched). The in-process sweep has no marker, so it keeps answering with its own
        // advancing-count evidence, folded to beating or stale exactly as before.
        let beat = heartbeat?()
            ?? (RunProgress.sweepIsAlive(lastProgressAt: snap.advancedAt, now: now) ? .beating : .stale)
        // #2872: when this tick first saw the marker gone, so "Finishing up" is a handover and not a
        // permanent state. Asked from the same snapshot as the verdict, so the two cannot answer from
        // different instants.
        let absentSince = finishingWatch.observe(beat, now: now)
        let state = RunProgress.liveness(since: since, now: now, timeout: timeout, heartbeat: beat,
                                         cancelRequested: cancelRequested?() ?? false,
                                         waitingOnAnswer: waitingOnAnswer?() ?? false,
                                         markerAbsentSince: absentSince)
        VStack(spacing: OVSpacing.md) {
            switch state {
            case .stalled(let elapsed):
                stalled(elapsed: elapsed)
            case .finishing(let elapsed):
                finishing(elapsed: elapsed)
            case .stopping(let elapsed):
                stopping(elapsed: elapsed)
            case .waitingOnYou(let elapsed):
                waiting(elapsed: elapsed)
            case .running, .idle:
                running(snap, now: now)
            }
            controls(state: state)
        }
        .frame(maxWidth: .infinity)
        .padding(OVSpacing.lg)
    }

    @ViewBuilder private func running(_ snap: Snapshot, now: Date) -> some View {
        ProgressView().controlSize(.large).tint(OVColor.gold)
        Text(RunProgressCopy.title(phase))
            .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
        // #1124: the source being read RIGHT NOW and the overall count are two independent facts, so they
        // sit on separate lines. Gluing them into "name · N of M" read as if the number indexed the named
        // source (and, since the two come from uncoordinated sources, was effectively off by one).
        // #2203: once the counted part is done, the step replaces both lines below it. Showing "68 of 68
        // done" beside a phase that is still working is the count making a promise it cannot keep, and
        // showing the last source's name is naming something already finished with.
        if let step = snap.step {
            Text(step.line).font(OVType.body).foregroundStyle(OVColor.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if let current = RunProgressCopy.currentSourceLine(name: snap.sourceName) {
                Text(current).font(OVType.body).foregroundStyle(OVColor.inkSoft)
                    .multilineTextAlignment(.center)
            }
            if let progress = RunProgressCopy.overallProgressLine(completed: snap.completed, total: snap.total) {
                Text(progress).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .monospacedDigit()
            }
        }
        if let elapsed = RunProgress.elapsedLabel(since: since, now: now) {
            Text(elapsed).font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                .monospacedDigit()
        }
        // #1427: the predicted time left, on the Reading-calendars phase only, and only once enough runs
        // have been recorded to learn a pace (RunDurationHistory returns nil otherwise, so the line simply
        // does not appear, same as today). Sits under the elapsed counter it complements.
        if phase == .reading,
           let remaining = durationHistory()?.remaining(total: snap.total, completed: snap.completed),
           let line = RunProgressCopy.remainingLine(remaining) {
            Text(line).font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                .monospacedDigit()
        }
    }

    // #1822: the run is over and this screen is closing itself. The same calm treatment as running, with
    // no alarm colour and no warning symbol, because nothing has gone wrong. The phase title stays so the
    // screen does not appear to change subject in its last second.
    @ViewBuilder private func finishing(elapsed: String) -> some View {
        ProgressView().controlSize(.large).tint(OVColor.gold)
        Text(RunProgressCopy.title(phase))
            .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
        Text(RunProgress.finishingLabel(elapsed: elapsed))
            .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            .monospacedDigit()
    }

    // #1684: the stop has been accepted and the run is winding down. Same calm treatment as finishing, no
    // alarm colour and no warning symbol, because nothing has gone wrong: Dan asked for this.
    //
    // It deliberately drops the "N of M done" line and the phase title. Both are what made a stopping run
    // pixel-identical to a working one, and a count that can no longer climb is a progress line making a
    // promise it cannot keep.
    @ViewBuilder private func stopping(elapsed: String) -> some View {
        ProgressView().controlSize(.large).tint(OVColor.gold)
        Text(RunProgress.stoppingLabel(elapsed: elapsed))
            .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            .monospacedDigit()
        // Only the paid phase explains itself: on a check the wait has a cost attached, which is the one
        // thing he cannot see. On the scout and on Prep the stop is simply a stop.
        if phase == .probing {
            Text(ReachabilityProbeCopy.stoppingSpendNote)
                .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // #2201: the run is parked on a question. Calm, like finishing and stopping, because nothing has
    // gone wrong: it is doing exactly what it should, which is waiting for Dan. The counter keeps ticking
    // so the screen is still visibly alive, and the phase title goes, because "Scouting" beside a run that
    // is not scouting is the screen naming the wrong activity.
    @ViewBuilder private func waiting(elapsed: String) -> some View {
        ProgressView().controlSize(.large).tint(OVColor.gold)
        Text(RunProgress.waitingOnYouLabel(elapsed: elapsed))
            .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            .monospacedDigit()
    }

    @ViewBuilder private func stalled(elapsed: String) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 28)).foregroundStyle(OVColor.rust)
        Text(RunProgress.stalledLabel(RunProgressCopy.title(phase), elapsed: elapsed))
            .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder private func controls(state: RunLiveness) -> some View {
        // #1684: has the stop already been accepted? Kept as one named value rather than repeated inline,
        // since both the Cancel button and its caveat below turn on it.
        let stopping: Bool = { if case .stopping = state { return true } else { return false } }()
        return VStack(spacing: OVSpacing.xs) {
            HStack(spacing: OVSpacing.sm) {
                // #1037: stop the run for real, in either state (a running read or a stalled one). Rust, not
                // forest: this is the one control here that ends work, distinct from Hide (keep running) and
                // Retry (start again).
                // #1684: gone once the stop has been accepted. A control that keeps offering itself after
                // being pressed reads as broken, so Dan presses it again, which is exactly what happened:
                // "I'm trying to click cancel and it's doing nothing." It was doing something; there was
                // just nothing on screen that had changed (L44).
                if let onCancel, !stopping {
                    Button("Cancel", action: onCancel).buttonStyle(.plain).foregroundStyle(OVColor.rust)
                }
                if case .stalled = state, let onRetry {
                    Button("Retry", action: onRetry).buttonStyle(.plain).foregroundStyle(OVColor.forestText)
                }
                if let onHide {
                    Button("Hide") { onHide() }
                        .buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
                }
            }
            // #1685: on the one phase that SPENDS, say what Cancel does before it is pressed. A check is
            // the only run here where stopping does not stop the cost, and the control read as though it
            // would. Deliberately visible rather than a tooltip: a caveat nobody hovers over is a caveat
            // nobody reads (L49), and this one exists to be read at the moment of deciding.
            //
            // Only while a cancel is actually on offer, and only for a check. On the scout and on Prep it
            // would be a sentence about money on a run that spends nothing per item.
            if phase == .probing, onCancel != nil, !stopping {
                Text(ReachabilityProbeCopy.cancelSpendCaveat)
                    .font(OVType.meta)
                    .foregroundStyle(OVColor.inkSoft)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension RunProgressView.Snapshot {
    // #1034/#1036: the live reading-phase snapshot, from the files the app already owns. The source being
    // read now comes from diffing the queue the app wrote against the results the run is filling; the
    // count from the run's own script-derived progress file (#1015). ONE definition, shared by RootView's
    // takeover and AddLeadSheet's inline read, so the two can never disagree about what the read is
    // showing. Injectable URLs so it is a real unit test; missing files read as an empty snapshot.
    static func liveReading(queueURL: URL = ScoutExtractQueueBuilder.defaultURL,
                            resultsURL: URL = ScoutExtractResultsDecoder.defaultURL,
                            progressURL: URL = ScoutExtractProgressDecoder.defaultURL) -> RunProgressView.Snapshot {
        let progress = ScoutExtractProgressDecoder.loadCurrent(from: progressURL)
        return RunProgressView.Snapshot(
            sourceName: ScoutExtractCurrentSource.loadCurrentName(queueURL: queueURL, resultsURL: resultsURL),
            completed: progress?.completed ?? 0,
            total: progress?.total ?? 0)
    }
}

extension RunProgressView.Snapshot {
    // #1130: the live Prep-run snapshot, from the run's own progress file (overture-prep-progress.json,
    // total/completed, written by the workflow, decoded by PrepProgressDecoder). The Prep run works by
    // prospect but does not publish which one, so there is no per-item name: currentSourceLine is nil and
    // only the "N of M done" progress line shows. Injectable URL so it is a real unit test; a missing or
    // mid-write file reads as an empty snapshot (completed 0, total 0), which renders no count line at all.
    static func livePrepping(progressURL: URL = PrepProgressDecoder.defaultURL) -> RunProgressView.Snapshot {
        let progress = PrepProgressDecoder.loadCurrent(from: progressURL)
        return RunProgressView.Snapshot(sourceName: nil,
                                          completed: progress?.completed ?? 0,
                                          total: progress?.total ?? 0)
    }
}

// The modal's words, pure so a test reads them directly rather than digging them out of the view.
enum RunProgressCopy {
    static func title(_ phase: RunProgressView.Phase) -> String {
        switch phase {
        case .scouting: return "Scouting"
        case .reading:  return "Reading calendars"
        case .readingListings: return "Reading show pages"
        case .prepping: return "Prepping"
        case .probing:  return "Checking reachability"
        }
    }

    // #1613: what a run that DIED says. Not "looks stuck": stuck invites waiting, and there is nothing
    // left to wait for, which is the state Dan sat in for 3:38 on 2026-07-27 pressing a Cancel button
    // that nothing was alive to hear. It names the ending and says Overture has already tidied up, so the
    // sentence is a report rather than an instruction with no action behind it (L11).
    static func diedLine(phase: RunProgressView.Phase) -> String {
        diedLine(named: title(phase))
    }

    // #2104: the reply-classify run has no Phase case (it has no takeover modal of its own, only the
    // queue's one-line run label), so it names itself here. Built through the same sentence as every
    // other dead run rather than a second one, so they cannot come to word it differently.
    static let diedLineForReplies = diedLine(named: "Drafting replies")

    private static func diedLine(named what: String) -> String {
        "\(what) stopped before it finished. Overture has cleared it, so you can start again."
    }

    // #1124: the name and the count are two uncoordinated facts (the name is the source being read RIGHT
    // NOW, from the queue/results diff; the count is how many are DONE, from the run's own progress file),
    // so they are rendered as two separate lines, never glued into "name · N of M". That glued form read
    // as if the number indexed the named source ("Carnegie Hall is #3 of 9") and, because the halves drift
    // independently, was effectively off by one (the name sat on one source while the count ticked past).

    // The source being read RIGHT NOW, on its own line, or nil before any source is known (or for a run
    // that publishes no per-item name, like Prep). Just the name: no count, no position.
    static func currentSourceLine(name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    // Overall progress across the whole run, worded as a COMPLETED count ("N of M done") so it reads as
    // separate overall progress rather than the named source's position. Shown only when there is more
    // than one source to get through: "1 of 1 done" is noise for a pasted lead, which is what lets the
    // lead case degrade to the name alone without any special-casing at the call site (#1036).
    static func overallProgressLine(completed: Int, total: Int) -> String? {
        guard total > 1 else { return nil }
        return "\(min(completed, total)) of \(total) done"
    }

    // #1427: the predicted time left on a Reading-calendars run, e.g. "~2m 30s remaining", or nil when
    // there is nothing to say (no estimate available, or the run is effectively done). Rounded to the
    // nearest ten seconds on purpose: this is a prediction from an averaged pace, and a per-second value
    // would imply a precision it does not have. The "~" says "about" so it never reads as a countdown clock.
    static func remainingLine(_ remaining: TimeInterval?) -> String? {
        guard let remaining, remaining > 0 else { return nil }
        let rounded = Int((remaining / 10).rounded()) * 10
        guard rounded > 0 else { return nil }
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let seconds = rounded % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if seconds > 0 { parts.append("\(seconds)s") }
        return "~\(parts.joined(separator: " ")) remaining"
    }
}
