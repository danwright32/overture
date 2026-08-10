import SwiftUI
import SwiftData

// #1027: the one branded surface a finished MANUAL scout shows, once, at the true end of the run.
//
// It replaces the plain system alert. Every applicable warning is its own section, ranked by how much
// it needs Dan (app-level first, then the per-source failures he can act on, then the informational
// notes). The per-source failures are actionable in place: correct a source's address, or confirm a
// quiet page is the right one. Fix as many as you like; "Read the ones I fixed" reads them in one run,
// which takes over the screen with the normal scout progress. Auto (scheduled) runs never open this;
// they leave a quiet line instead.
struct ScoutSummaryView: View {
    let warnings: ScoutWarnings
    // Reads exactly the sources Dan corrected, in one run. Wired by RootView to runScout(only:).
    var onReadFixed: (Set<String>) -> Void = { _ in }
    // #1190: re-runs the ordinary scout so the next batch of over-budget sources gets checked. Wired by
    // RootView to the same runScout() a "Run scout" press uses, never a second run path.
    var onRunAgain: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WatchedSource.orgName) private var sources: [WatchedSource]

    @State private var fixedIds: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(OVColor.line)

            // #1190: the re-run prompt sits ABOVE the scrolling sections so it can never scroll out of
            // view: it is the one thing on this popup that changes what the run covered.
            if let rerunPrompt {
                rerunBanner(rerunPrompt)
                Divider().overlay(OVColor.line)
            }

            // A deferred-only run has no sections; skip the empty scroll box entirely.
            if !warnings.sections.isEmpty {
                CappedScrollView(maxHeight: 460) { sectionStack }
                Divider().overlay(OVColor.line)
            }
            footer
        }
        .frame(width: 560)
        .background(OVColor.canvas)
        .actionFeedbackBanner()
    }

    // #1190: shown only for a manual run (this popup never opens for a scheduled one) that hit its
    // budget and left sources unchecked. nil the rest of the time.
    private var rerunPrompt: ScoutRerunPrompt? {
        ScoutRerunPrompt.after(deferredCount: warnings.deferredCount, auto: false)
    }

    // The prompt: what is waiting, and one click to check it.
    private func rerunBanner(_ prompt: ScoutRerunPrompt) -> some View {
        HStack(spacing: OVSpacing.md) {
            Text(prompt.line)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(OVColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: OVSpacing.sm)
            Button(prompt.buttonLabel) { onRunAgain() }
                .buttonStyle(.borderedProminent)
                .tint(OVColor.forestText)
        }
        .padding(OVSpacing.lg)
    }

    // The subtitle explains the inline actions, so it is shown ONLY when there is something to act on. A
    // run whose popup carries only informational notes would be promising a Fix/Confirm that is not there.
    // #1426: the still-watched list, never the raw one. Stop watching the last failing source and the
    // subtitle's promise goes with the cards it was describing.
    // #2207: the silently empty sources count as actionable too, because they now carry the same
    // controls. That is the whole of #2207: the copy was written to be acted on (#1531 added the source's
    // NAME on the grounds that it was "the only actionable fact in the warning") and the surface was built
    // to say there was nothing to do.
    private var hasActionableFailures: Bool {
        warnings.sections.contains {
            switch $0 {
            case .failures(let results):
                return !ScoutSummaryRow.stillWorthShowing(results, in: sources).isEmpty
            case .silentlyEmptyFeed(let empties):
                return !ScoutSummaryRow.silentlyEmptyStillWorthShowing(empties, in: sources).isEmpty
            default:
                return false
            }
        }
    }

    // #1426: the ids Dan fixed, minus any he has since stopped watching. Reading them would spend a scout
    // run on sources that are off the watchlist.
    private var fixedAndStillWatched: Set<String> {
        ScoutSummaryRow.stillWorthShowing(fixedIds, in: sources)
    }

    private var sectionStack: some View {
        VStack(alignment: .leading, spacing: OVSpacing.lg) {
            ForEach(Array(warnings.sections.enumerated()), id: \.offset) { _, section in
                sectionView(section)
            }
        }
        .padding(OVSpacing.lg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ScoutSummaryCopy.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
            if hasActionableFailures {
                Text(ScoutSummaryCopy.subtitle).font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(OVSpacing.lg)
    }

    private var footer: some View {
        HStack {
            Spacer()
            if !fixedAndStillWatched.isEmpty {
                Button(ScoutSummaryCopy.readFixed(fixedAndStillWatched.count)) {
                    // #1034: no dismiss() here. The summary and the scout-progress takeover now share ONE
                    // presented sheet, and onReadFixed starts a fresh scout that re-shows that same sheet
                    // as progress. Dismissing first would fight the re-present (a dropped sheet, or a
                    // flicker), so the read just swaps this sheet's content in place instead.
                    onReadFixed(fixedAndStillWatched)
                }
                .keyboardShortcut(.defaultAction)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(fixedAndStillWatched.isEmpty ? .defaultAction : .cancelAction)
        }
        .padding(OVSpacing.lg)
    }

    @ViewBuilder
    private func sectionView(_ section: ScoutWarnings.Section) -> some View {
        switch section {
        case .saveFailed:
            infoBlock(ScoutWarningCopy.saveFailed)
        case .extractLaunchFailure(let message):
            infoBlock(message)
        case .readerFinishedEmpty(let message):
            infoBlock(message)
        case .failures(let results):
            // #1426: the heading counts what is on screen, because the rows and the count read the same
            // filtered list. Removing every failing source leaves nothing here at all, rather than a
            // heading over an empty box.
            let shown = ScoutSummaryRow.stillWorthShowing(results, in: sources)
            if !shown.isEmpty { failuresBlock(shown) }
        case .unqueued(let ids):
            infoBlock(ScoutWarningCopy.unqueued(ids: ids))
        case .silentlyEmptyFeed(let empties):
            // #2207: the shape of a page whose format changed, and the case that most needs looking at,
            // because it is invisible everywhere else: nothing failed. Same filter as the failures above,
            // so a source Dan settles on this screen leaves it.
            let stillEmpty = ScoutSummaryRow.silentlyEmptyStillWorthShowing(empties, in: sources)
            if !stillEmpty.isEmpty { silentlyEmptyBlock(stillEmpty) }
        case .pastClientList(let message):
            infoBlock(message)
        }
    }

    // An informational section: one sentence Dan reads, nothing to act on.
    private func infoBlock(_ message: String) -> some View {
        Text(message).font(.system(size: 12)).foregroundStyle(OVColor.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    // #2207: the sources that read fine and came back with nothing. Its own section rather than folded in
    // with the failures, because it is a different fact and a different sentence: nothing failed, which is
    // exactly why it is easy to miss. Same card, same controls, same "Read the ones I fixed" follow
    // through, because "what am I supposed to do with this" (Dan, 2026-08-06) has the same three answers
    // here: correct the address, say the page is right, or stop watching it.
    private func silentlyEmptyBlock(_ results: [ScoutService.SourceResult]) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            Text(ScoutSummaryCopy.silentlyEmptyHeading(results.count))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(OVColor.rust)
            Text(ScoutWarningCopy.silentlyEmptyFeed(sources: results.map { ($0.orgName, $0.droppedRowCount) }))
                .font(.system(size: 12)).foregroundStyle(OVColor.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(results, id: \.sourceId) { result in
                    silentlyEmptyRow(result)
                    if result.sourceId != results.last?.sourceId {
                        Divider().overlay(OVColor.line)
                    }
                }
            }
            .background(OVColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(OVColor.line))
        }
    }

    @ViewBuilder
    private func silentlyEmptyRow(_ result: ScoutService.SourceResult) -> some View {
        let source = sources.first { $0.sourceId == result.sourceId }
        VStack(alignment: .leading, spacing: 3) {
            Text(result.orgName).font(.system(size: 13, weight: .medium)).foregroundStyle(OVColor.ink)
            if let urlString = ScoutSummaryRow.displayURL(result: result, source: source) {
                if let url = URL(string: urlString) {
                    Link(urlString, destination: url)
                        .font(.system(size: 11)).foregroundStyle(OVColor.forestText).lineLimit(1)
                } else {
                    Text(urlString).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint).lineLimit(1)
                }
            }
            if let source {
                // No failure to pass: nothing failed. `readFineAndCameBackEmpty` is what says this row is
                // the state Confirm settles, since by the time the row is read a silently empty source and
                // a healthy one are indistinguishable.
                SourceFixConfirmActions(source: source, failure: nil,
                                        onFixed: { fixedIds.insert($0) },
                                        offersStopWatching: true,
                                        readFineAndCameBackEmpty: true)
            }
        }
        .padding(.horizontal, OVSpacing.sm)
        .padding(.vertical, OVSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The actionable section: the per-source failures, each with fix/confirm where it applies.
    private func failuresBlock(_ results: [ScoutService.SourceResult]) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            Text(ScoutSummaryCopy.failuresHeading(results.count))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(OVColor.rust)

            VStack(spacing: 0) {
                ForEach(results, id: \.sourceId) { result in
                    failureRow(result)
                    if result.sourceId != results.last?.sourceId {
                        Divider().overlay(OVColor.line)
                    }
                }
            }
            .background(OVColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(OVColor.line))
        }
    }

    @ViewBuilder
    private func failureRow(_ result: ScoutService.SourceResult) -> some View {
        let source = sources.first { $0.sourceId == result.sourceId }
        VStack(alignment: .leading, spacing: 3) {
            Text(result.orgName).font(.system(size: 13, weight: .medium)).foregroundStyle(OVColor.ink)
            if let message = result.state.failureMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // #1055: the flagged page itself, so Dan can open it and judge whether it is the wrong page
            // without leaving this popup for the Sources sheet. Clickable when it parses as a URL, plain
            // text otherwise. Carnegie's native feed has no page and so nothing to show here.
            // #1125: the address comes off the LIVE source when one matches, not the run-time snapshot,
            // so a correction Dan just saved shows the new URL instead of reading as a no-op.
            if let urlString = ScoutSummaryRow.displayURL(result: result, source: source) {
                if let url = URL(string: urlString) {
                    Link(urlString, destination: url)
                        .font(.system(size: 11)).foregroundStyle(OVColor.forestText).lineLimit(1)
                } else {
                    Text(urlString).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint).lineLimit(1)
                }
            }
            // #1450: no kind gate here any more. Which controls a source's kind allows is the component's
            // own rule; gating the whole block on it here is what left Carnegie's feed with no exit.
            if let source, case .failed(let failure) = result.state {
                SourceFixConfirmActions(source: source, failure: failure,
                                        onFixed: { fixedIds.insert($0) },
                                        offersStopWatching: true)
            }
        }
        .padding(.horizontal, OVSpacing.sm)
        .padding(.vertical, OVSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// #1125: which address a couldn't-be-checked row shows, kept out of the SwiftUI view so it can be tested
// (logic in a view body is untestable, #863). The `SourceResult` is a SNAPSHOT captured when the scout
// ran; the live `WatchedSource` is what "Change the page link" writes to. Prefer the live value whenever a row
// matches, so a saved correction is visible immediately instead of reading as a no-op. The snapshot is
// the fallback only for a result with no live watchlist row of its own.
enum ScoutSummaryRow {
    static func displayURL(result: ScoutService.SourceResult, source: WatchedSource?) -> String? {
        source?.listingsURL ?? result.listingsURL
    }

    // #1426/#1499: which of the run's failures the popup still has anything to say about. The list it was
    // handed is a SNAPSHOT taken when the scout finished, so an action Dan takes on this very screen cannot
    // change it: without this filter the card would keep its rust failure line AND keep being counted by the
    // "N sources couldn't be checked" heading. Asked of the LIVE watchlist rows, which is also what makes an
    // Undo restore the card for free rather than needing a second path back.
    //
    // #1499 made this ONE question instead of a list of actions. It was "is it still watched", which covered
    // the stop-watching button and nothing else, so when "This page is right" cleared the failure underneath
    // the card went on stating the problem the press had just settled. That is the "did that work?" failure
    // mode: the only evidence a press landed is a banner that disappears, above a card that contradicts it.
    // Three buttons have now needed the same treatment one at a time (#1125 the address, #1426 stop
    // watching, this), so the rule is stated as the question rather than as the actions, and a fourth button
    // gets it for free.
    static func stillWorthShowing(_ results: [ScoutService.SourceResult],
                                  in sources: [WatchedSource]) -> [ScoutService.SourceResult] {
        results.filter { hasSomethingLeftToSay($0.sourceId, in: sources) }
    }

    // The same question asked of the ids Dan has fixed, so "Read the ones I fixed" cannot offer to spend a
    // scout run on a source he fixed and then removed, or on one he has since confirmed is fine.
    static func stillWorthShowing(_ sourceIds: Set<String>, in sources: [WatchedSource]) -> Set<String> {
        sourceIds.filter { hasSomethingLeftToSay($0, in: sources) }
    }

    // #2207: the same question for a source that read fine and came back with nothing, which needs its own
    // answer because `hasSomethingLeftToSay` cannot give one. That rule asks the live row whether it
    // reports a problem, and a silently empty source's row reports none: nothing failed, which is the
    // whole difficulty. Read through that rule every such card would vanish the instant it was drawn.
    //
    // So it asks what would actually settle this one: Dan said the page is right (confirmEmpty stamps the
    // anchor), or he stopped watching it. A CORRECTED address deliberately leaves the card, exactly as it
    // does for a failure: the new address has not been read yet, and that card is what "Read the ones I
    // fixed" is about.
    static func silentlyEmptyStillWorthShowing(_ results: [ScoutService.SourceResult],
                                               in sources: [WatchedSource]) -> [ScoutService.SourceResult] {
        results.filter { result in
            guard let source = sources.first(where: { $0.sourceId == result.sourceId }) else { return true }
            guard source.isActive else { return false }
            return source.confirmedEmptyHash == nil
        }
    }

    // Two ways a card stops having anything to say, and one deliberate way it does not.
    //
    // Not watched any more: deliberately "is it still watched" rather than "did Dan remove it", because a
    // source that went inactive when the org asked us to stop is just as gone from this screen's view.
    //
    // Settled: the live row reports no problem at all. Keyed to that ANSWER rather than to any particular
    // field a confirm writes, because `confirmEmpty` does not always write them all (with no bytes to anchor
    // to it returns .noHash having still cleared the failure), and a rule that watched for the hash would
    // miss that path.
    //
    // A CORRECTED address is the case this must not swallow, and it is why "settled" is not merely "has no
    // failure". `editURL` also clears lastFailure, but leaves health at .neverChecked, because the page has
    // not been checked at the new address yet: unknown is not settled. That card has to stay, both so Dan can
    // see his correction on it (#1125) and because the footer's "Read the ones I fixed" is about exactly
    // those sources.
    //
    // A result with no live row at all STAYS: that is not a removal, it is the unmatched case #1125 kept the
    // snapshot for, and dropping it would silently swallow a failure.
    private static func hasSomethingLeftToSay(_ sourceId: String, in sources: [WatchedSource]) -> Bool {
        guard let source = sources.first(where: { $0.sourceId == sourceId }) else { return true }
        guard source.isActive else { return false }
        return !(source.health == .ok && source.lastFailure == nil)
    }
}

// #1190: the manual scout summary's "N venues still to check, run again" prompt, kept out of the view
// body so its show/hide rule and its singular/plural wording are testable (#863: logic that lived in a
// view drifted twice under a green suite). An automatic (scheduled) run never shows it: those runs defer
// nothing by design, and even if that changed, the re-run affordance is a manual surface Dan opened, so
// `auto` is refused here rather than relied on to be false upstream.
struct ScoutRerunPrompt: Equatable {
    let deferredCount: Int

    static func after(deferredCount: Int, auto: Bool) -> ScoutRerunPrompt? {
        guard !auto, deferredCount > 0 else { return nil }
        return ScoutRerunPrompt(deferredCount: deferredCount)
    }

    var line: String {
        deferredCount == 1
            ? "1 venue is still waiting to be checked."
            : "\(deferredCount) venues are still waiting to be checked."
    }

    var buttonLabel: String { "Run scout again" }
}

enum ScoutSummaryCopy {
    static let title = "Scout results"
    // #1426: it used to list the actions ("Fix a source's address or confirm a page is right, and I'll
    // read the ones you fix."). With a third button on every card that list was both longer and still
    // wrong, and it was already restating words Dan can read on the buttons themselves (#843). What is
    // left is the only part no button says: fixing one queues it to be read.
    static let subtitle = "I'll read the ones you fix."

    static func failuresHeading(_ count: Int) -> String {
        count == 1 ? "One source couldn't be checked." : "\(count) sources couldn't be checked."
    }

    // #2207: says what happened, not that something failed, because nothing did. Rust like the failures
    // heading because it is the same kind of thing to Dan (a source he may need to do something about),
    // and the sentence under it is what tells the two apart.
    static func silentlyEmptyHeading(_ count: Int) -> String {
        count == 1 ? "One source went quiet." : "\(count) sources went quiet."
    }

    static func readFixed(_ count: Int) -> String {
        count == 1 ? "Read the one I fixed" : "Read the \(count) I fixed"
    }
}
