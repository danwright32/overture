import SwiftUI
import AppKit

// #1808: shown at launch when the installed copy is behind what has shipped, or when Overture cannot
// tell how old it is.
//
// Dan chose the shape, 2026-08-03: "a pop up window that takes up most of the app screen. It can be
// dismissed." A quiet masthead line was the alternative and he turned it down, for the right reason:
// the whole failure is that he does not notice the gap, and a line he can miss is a line he will miss.
// He has reported bugs in behaviour that was already fixed because the fix was not in front of him.
//
// Follows StoreShrinkNoticeSheet's framing (#1409), which is the other launch-time notice: same header,
// same body treatment, wider because this one is meant to be unmissable. It carries no sentence of its
// own: every word comes from BuildFreshnessCopy, which is tested, so what Dan reads here cannot drift
// under a green suite (#885).
struct BuildFreshnessSheet: View {
    let verdict: BuildFreshness.Verdict
    // Where the installer built from, or nil when there is no record of an install. Nil means no Update
    // button, because a button that cannot act reads as an update that ran and did nothing (#1778).
    let repoPath: String?
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OVSpacing.sm) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(OVColor.goldBright)
                Text(BuildFreshnessCopy.title(verdict))
                    .font(OVType.dateHeading)
                    .foregroundStyle(OVColor.onForest)
            }
            .padding(.horizontal, OVSpacing.lg)
            .padding(.vertical, OVSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OVColor.canvas)

            VStack(alignment: .leading, spacing: OVSpacing.md) {
                Text(BuildFreshnessCopy.body(verdict))
                    .font(OVType.body)
                    .foregroundStyle(OVColor.onForest)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if repoPath != nil {
                    // Said BEFORE he presses it: the installer quits Overture partway through and
                    // relaunches it, so the app vanishing mid-update is the update working rather than a
                    // crash. Without this line the button looks like it killed the app.
                    Text(BuildFreshnessCopy.updateNote)
                        .font(OVType.meta)
                        .foregroundStyle(OVColor.onForest.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(BuildFreshnessCopy.cannotUpdate)
                        .font(OVType.meta)
                        .foregroundStyle(OVColor.onForest.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button(BuildFreshnessCopy.dismiss) { onDismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(OVColor.onForest.opacity(0.75))
                    Spacer()
                    if repoPath != nil {
                        // #2188: the press is REPORTED rather than acted on here. The sheet used to
                        // dismiss itself and open the command file, so there was no moment at which
                        // anything else could learn a press had happened, and a run that then refused
                        // had nowhere to report back to.
                        Button(BuildFreshnessCopy.update) { onUpdate() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(OVColor.gold)
                    }
                }
            }
            .padding(OVSpacing.lg)
        }
        // Wider than the other notices on purpose: Dan asked for something taking up most of the window,
        // because this is the one notice whose whole job is to be impossible to work past without seeing.
        .frame(width: 620)
        .background(OVColor.forest)
    }
}

// Attached at the window, like StoreShrinkNotice, so RootView neither knows nor cares. It owns the read
// as well as the dismissal (#2065): the verdict used to be worked out once in OvertureApp.init and
// pinned, which raced the installer's own write and left Dan being told for hours that a copy straight
// from the installer had not come from the installer. Every rule about how often to look lives in
// BuildFreshnessState, so this holds no policy of its own, just the three moments worth looking at.
//
// #2188: it also owns the waiting that follows a press. The update runs in a Terminal window this
// process cannot see, so the only thing that knows how it went is the record the run leaves, and
// something has to be looking. One sheet shows either panel, because they are one conversation: the
// press closes the out of date panel and its outcome opens the next one in the same place.
struct BuildFreshnessNotice: ViewModifier {
    @State private var state: BuildFreshnessState
    @State private var attempt: UpdateAttemptState

    init(directory: URL) {
        _state = State(initialValue: BuildFreshnessState(directory: directory))
        _attempt = State(initialValue: UpdateAttemptState(directory: directory))
    }

    // The press: open the update, and hand the id it comes back with to the watcher. Nothing is watched
    // when nothing was opened, so a press that could not be written never leaves something waiting on a
    // run that does not exist.
    @MainActor private func press() {
        guard let repoPath = state.repoPath else { return }
        // Dismissed first: the installer quits this process moments later, and a sheet still up when the
        // window goes is a worse last frame than a closed one.
        state.dismiss()
        guard let id = UpdateCommandFile.open(repoPath: repoPath) else { return }
        attempt.pressed(id, at: Date())
    }

    func body(content: Content) -> some View {
        content
            // One watch per press, started when the press happens and ending when its outcome is known.
            .task(id: attempt.press) { await attempt.watch() }
            // The read that beats the install race, then the slow tick that notices a merge landing
            // while Dan works. Both end when the window goes, so a closed window watches nothing.
            .task {
                state.refreshIfStale()
                await state.watch()
            }
            // And the cheap one: he switched to a terminal, something merged, he switched back.
            // refreshIfStale, not a read, so app-switching all afternoon still costs one look.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                state.refreshIfStale()
            }
            .sheet(isPresented: .init(
                get: { attempt.shouldShow || state.shouldShow },
                set: { if !$0 { if attempt.shouldShow { attempt.dismiss() } else { state.dismiss() } } })) {
                // The outcome of a press he just made comes first: it is the newer news, and it is about
                // the thing he did rather than the thing he was told.
                if attempt.shouldShow, let progress = attempt.progress {
                    UpdateFailureSheet(progress: progress,
                                       canRetry: state.repoPath != nil,
                                       onRetry: { press() },
                                       onDismiss: { attempt.dismiss() })
                } else if let verdict = state.verdict {
                    // Only ever built when shouldShow is true, which requires a verdict, so there is no
                    // fallback here inventing one.
                    BuildFreshnessSheet(verdict: verdict, repoPath: state.repoPath,
                                        onUpdate: { press() },
                                        onDismiss: { state.dismiss() })
                }
            }
    }
}

extension View {
    // Takes the directory, not an answer: the panel reads the records itself, when it is about to show.
    func buildFreshnessNotice(directory: URL) -> some View {
        modifier(BuildFreshnessNotice(directory: directory))
    }
}
