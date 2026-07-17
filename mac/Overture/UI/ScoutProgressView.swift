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
// launch when a run is still going (#1035), and AddLeadSheet renders it inline while a pasted lead is
// read (#1036). One progress surface, not three that drift.
//
// This is not decoration. CLAUDE.md's standing rule is that a slow action must make working, still-
// alive and failed visibly different states; the ticking counter and the stalled warning are exactly
// that, routed through the same RunProgress.liveness every other long action uses.
struct ScoutProgressView: View {
    enum Phase: Equatable { case scouting, reading }

    // What the modal shows RIGHT NOW, re-read each tick inside the TimelineView. The caller wires this
    // to the native progress callback's captured values (scouting) or to the queue/results diff plus the
    // run's own progress file (reading), so a live read happens every second without this view knowing
    // where the numbers come from.
    struct Snapshot: Equatable {
        var sourceName: String? = nil
        var completed: Int = 0
        var total: Int = 0
    }

    let phase: Phase
    // When the CURRENT phase began, for the elapsed counter and the stall window. Per-phase: the sweep
    // and the read are separate activities with separate ceilings (RunTimeouts.scout vs scoutExtract).
    let since: Date?
    var snapshot: () -> Snapshot = { Snapshot() }
    // The reading phase's real heartbeat (marker freshness), so a slow-but-living run never flips to the
    // misleading "looks stuck" state while a genuinely dead one does. nil keeps wall-clock-only behaviour.
    var runAlive: (() -> Bool)? = nil
    // Stalled-state retry: abandon the apparently-dead run and start fresh (wired by the caller).
    var onRetry: (() -> Void)? = nil
    // Dismiss-to-hide: the run keeps going untouched; the caller shows a reopen affordance.
    var onHide: (() -> Void)? = nil

    // Each phase's own stall window: an in-process sweep is quick, a detached read that follows detail
    // pages legitimately runs long, so reusing the sweep's 3-minute ceiling for the read would declare a
    // healthy run stuck (the #803 lesson).
    var timeout: TimeInterval { phase == .scouting ? RunTimeouts.scout : RunTimeouts.scoutExtract }

    // Just the ticking content, sized to its content. The presentation chrome (the takeover's fixed
    // frame and canvas background) is applied by the caller, so the SAME view drops into RootView's
    // full-screen sheet and inline into AddLeadSheet (#1036) without one imposing the other's size.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    // Internal (not private) so ScoutProgressViewStateTests can call it with a fixed `now`, the same
    // reason LiveRunLabel.content(now:) is (see its #470 comment).
    @ViewBuilder func content(now: Date) -> some View {
        let state = RunProgress.liveness(since: since, now: now, timeout: timeout, runAlive: runAlive?())
        VStack(spacing: OVSpacing.md) {
            switch state {
            case .stalled(let elapsed):
                stalled(elapsed: elapsed)
            case .running, .idle:
                running(now: now)
            }
            controls(state: state)
        }
        .frame(maxWidth: .infinity)
        .padding(OVSpacing.lg)
    }

    @ViewBuilder private func running(now: Date) -> some View {
        let snap = snapshot()
        ProgressView().controlSize(.large).tint(OVColor.gold)
        Text(ScoutProgressCopy.title(phase))
            .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
        if let line = ScoutProgressCopy.sourceLine(name: snap.sourceName,
                                                   completed: snap.completed, total: snap.total) {
            Text(line).font(OVType.body).foregroundStyle(OVColor.inkSoft)
                .multilineTextAlignment(.center)
        }
        if let elapsed = RunProgress.elapsedLabel(since: since, now: now) {
            Text(elapsed).font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                .monospacedDigit()
        }
    }

    @ViewBuilder private func stalled(elapsed: String) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 28)).foregroundStyle(OVColor.rust)
        Text(RunProgress.stalledLabel(ScoutProgressCopy.title(phase), elapsed: elapsed))
            .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder private func controls(state: RunLiveness) -> some View {
        HStack(spacing: OVSpacing.sm) {
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

extension ScoutProgressView.Snapshot {
    // #1034/#1036: the live reading-phase snapshot, from the files the app already owns. The source being
    // read now comes from diffing the queue the app wrote against the results the run is filling; the
    // count from the run's own script-derived progress file (#1015). ONE definition, shared by RootView's
    // takeover and AddLeadSheet's inline read, so the two can never disagree about what the read is
    // showing. Injectable URLs so it is a real unit test; missing files read as an empty snapshot.
    static func liveReading(queueURL: URL = ScoutExtractQueueBuilder.defaultURL,
                            resultsURL: URL = ScoutExtractResultsDecoder.defaultURL,
                            progressURL: URL = ScoutExtractProgressDecoder.defaultURL) -> ScoutProgressView.Snapshot {
        let progress = ScoutExtractProgressDecoder.loadCurrent(from: progressURL)
        return ScoutProgressView.Snapshot(
            sourceName: ScoutExtractCurrentSource.loadCurrentName(queueURL: queueURL, resultsURL: resultsURL),
            completed: progress?.completed ?? 0,
            total: progress?.total ?? 0)
    }
}

// The modal's words, pure so a test reads them directly rather than digging them out of the view.
enum ScoutProgressCopy {
    static func title(_ phase: ScoutProgressView.Phase) -> String {
        switch phase {
        case .scouting: return "Scouting"
        case .reading:  return "Reading calendars"
        }
    }

    // "Carnegie Hall · 3 of 9" while a run has several sources, or just the name for a single-source run
    // (a pasted lead, where "1 of 1" is noise), or just the count before the source is known, or nil when
    // there is neither. The count shows only when total > 1, which is what makes the lead case degrade
    // without any special-casing at the call site (#1036).
    static func sourceLine(name: String?, completed: Int, total: Int) -> String? {
        let count = total > 1 ? "\(min(completed, total)) of \(total)" : nil
        switch (name, count) {
        case let (name?, count?): return "\(name) · \(count)"
        case let (name?, nil):    return name
        case let (nil, count?):   return count
        case (nil, nil):          return nil
        }
    }
}
