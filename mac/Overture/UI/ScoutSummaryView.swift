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

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WatchedSource.orgName) private var sources: [WatchedSource]

    @State private var fixedIds: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(OVColor.line)

            ScrollView { sectionStack }.frame(maxHeight: 460)

            Divider().overlay(OVColor.line)
            footer
        }
        .frame(width: 560)
        .background(OVColor.canvas)
        .actionFeedbackBanner()
    }

    // The subtitle explains the inline actions, so it is shown ONLY when there is something to act on. A
    // run whose popup carries only informational notes would be promising a Fix/Confirm that is not there.
    private var hasActionableFailures: Bool {
        warnings.sections.contains { if case .failures = $0 { return true }; return false }
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
            if !fixedIds.isEmpty {
                Button(ScoutSummaryCopy.readFixed(fixedIds.count)) {
                    // #1034: no dismiss() here. The summary and the scout-progress takeover now share ONE
                    // presented sheet, and onReadFixed starts a fresh scout that re-shows that same sheet
                    // as progress. Dismissing first would fight the re-present (a dropped sheet, or a
                    // flicker), so the read just swaps this sheet's content in place instead.
                    onReadFixed(fixedIds)
                }
                .keyboardShortcut(.defaultAction)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(fixedIds.isEmpty ? .defaultAction : .cancelAction)
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
            failuresBlock(results)
        case .unqueued(let ids):
            infoBlock(ScoutWarningCopy.unqueued(ids: ids))
        case .silentlyEmptyFeed:
            infoBlock(ScoutWarningCopy.silentlyEmptyFeed)
        case .pastClientList(let message):
            infoBlock(message)
        }
    }

    // An informational section: one sentence Dan reads, nothing to act on.
    private func infoBlock(_ message: String) -> some View {
        Text(message).font(.system(size: 12)).foregroundStyle(OVColor.ink)
            .fixedSize(horizontal: false, vertical: true)
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
                        .font(.system(size: 11)).foregroundStyle(OVColor.forest).lineLimit(1)
                } else {
                    Text(urlString).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint).lineLimit(1)
                }
            }
            // A source with an editable page (not Carnegie's native feed) gets the inline actions.
            if let source, source.kind != .algolia, case .failed(let failure) = result.state {
                SourceFixConfirmActions(source: source, failure: failure,
                                        onFixed: { fixedIds.insert($0) })
            }
        }
        .padding(.horizontal, OVSpacing.sm)
        .padding(.vertical, OVSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// #1125: which address a couldn't-be-checked row shows, kept out of the SwiftUI view so it can be tested
// (logic in a view body is untestable, #863). The `SourceResult` is a SNAPSHOT captured when the scout
// ran; the live `WatchedSource` is what "Fix the address" writes to. Prefer the live value whenever a row
// matches, so a saved correction is visible immediately instead of reading as a no-op. The snapshot is
// the fallback only for a result with no live watchlist row of its own.
enum ScoutSummaryRow {
    static func displayURL(result: ScoutService.SourceResult, source: WatchedSource?) -> String? {
        source?.listingsURL ?? result.listingsURL
    }
}

enum ScoutSummaryCopy {
    static let title = "Scout results"
    static let subtitle = "Fix a source's address or confirm a page is right, and I'll read the ones you fix."

    static func failuresHeading(_ count: Int) -> String {
        count == 1 ? "One source couldn't be checked." : "\(count) sources couldn't be checked."
    }

    static func readFixed(_ count: Int) -> String {
        count == 1 ? "Read the one I fixed" : "Read the \(count) I fixed"
    }
}
