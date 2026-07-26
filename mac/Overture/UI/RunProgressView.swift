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
    enum Phase: Equatable { case scouting, reading, prepping, probing }

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
        // detached phases leave it nil and keep passing their marker check as `runAlive`.
        var advancedAt: Date? = nil
    }

    let phase: Phase
    // When the CURRENT phase began, for the elapsed counter and the stall window. Per-phase: the sweep
    // and the read are separate activities with separate ceilings (RunTimeouts.scout vs scoutExtract).
    let since: Date?
    var snapshot: () -> Snapshot = { Snapshot() }
    // The reading phase's real heartbeat (marker freshness), so a slow-but-living run never flips to the
    // misleading "looks stuck" state while a genuinely dead one does. nil keeps wall-clock-only behaviour.
    var runAlive: (() -> Bool)? = nil
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

    // Each phase's own stall window: an in-process sweep is quick, a detached read that follows detail
    // pages legitimately runs long, so reusing the sweep's 3-minute ceiling for the read would declare a
    // healthy run stuck (the #803 lesson).
    var timeout: TimeInterval {
        switch phase {
        case .scouting: return RunTimeouts.scout
        case .reading:  return RunTimeouts.scoutExtract
        case .prepping, .probing: return RunTimeouts.prep
        }
    }

    // Just the ticking content, sized to its content. The presentation chrome (the takeover's fixed
    // frame and canvas background) is applied by the caller, so the SAME view drops into RootView's
    // full-screen sheet and inline into AddLeadSheet (#1036) without one imposing the other's size.
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
        // #1530: a phase with a marker file uses it (`runAlive`); the in-process sweep has none, so its
        // still-alive evidence is that the snapshot advanced recently. A phase with neither falls through
        // to `false`, which leaves the wall-clock ceiling deciding exactly as it did before.
        let alive = runAlive?() ?? RunProgress.sweepIsAlive(lastProgressAt: snap.advancedAt, now: now)
        let state = RunProgress.liveness(since: since, now: now, timeout: timeout, runAlive: alive)
        VStack(spacing: OVSpacing.md) {
            switch state {
            case .stalled(let elapsed):
                stalled(elapsed: elapsed)
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
        if let current = RunProgressCopy.currentSourceLine(name: snap.sourceName) {
            Text(current).font(OVType.body).foregroundStyle(OVColor.inkSoft)
                .multilineTextAlignment(.center)
        }
        if let progress = RunProgressCopy.overallProgressLine(completed: snap.completed, total: snap.total) {
            Text(progress).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                .monospacedDigit()
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

    @ViewBuilder private func stalled(elapsed: String) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 28)).foregroundStyle(OVColor.rust)
        Text(RunProgress.stalledLabel(RunProgressCopy.title(phase), elapsed: elapsed))
            .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder private func controls(state: RunLiveness) -> some View {
        HStack(spacing: OVSpacing.sm) {
            // #1037: stop the run for real, in either state (a running read or a stalled one). Rust, not
            // forest: this is the one control here that ends work, distinct from Hide (keep running) and
            // Retry (start again).
            if let onCancel {
                Button("Cancel", action: onCancel).buttonStyle(.plain).foregroundStyle(OVColor.rust)
            }
            if case .stalled = state, let onRetry {
                Button("Retry", action: onRetry).buttonStyle(.plain).foregroundStyle(OVColor.forest)
            }
            if let onHide {
                Button("Hide") { onHide() }
                    .buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
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
        case .prepping: return "Prepping"
        case .probing:  return "Checking reachability"
        }
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
