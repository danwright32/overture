import SwiftUI

// #1597 / #1774: the two controls that read the ticked reachability dates.
//
// They live here, outside QueueView.swift, for a structural reason rather than a tidiness one. The whole
// value of moving the ticks onto ProbeSelectionState is that QueueView's body never reads them; a read
// anywhere in that body puts the dependency straight back and one checkbox re-derives the whole store
// again. Keeping the only two readers in their own file makes that rule checkable as a single assertion
// (QueueInvalidationGuardTests) instead of a hunt through a dozen functions on the body path.

// #1597: tick a date to add it to a multi-date check. Rendered on Scout date headings that still hold
// something to check, so it never appears beside a date whose Check button is absent.
struct ProbeDateCheckbox: View {
    let groupID: String
    let selection: ProbeSelectionState

    var body: some View {
        Button {
            selection.toggle(groupID)
        } label: {
            Image(systemName: selection.contains(groupID) ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(selection.contains(groupID) ? OVColor.forest : OVColor.inkSoft)
        }
        .buttonStyle(.plain)
        .help("Include this date in one reachability check")
    }
}

// #1597: everything the selection bar and its confirm need, computed ONCE from the ticked dates. Both read
// this, so the total Dan watches while choosing is the total he approves.
struct ProbeSelectionBar: View {
    let selection: ProbeSelectionState
    // #1916/#1771: a closure, never a built array. QueueModel.probeSelection takes its rows as an
    // @autoclosure and returns nil before evaluating them when nothing is ticked, so an unticked queue
    // never pays for the StageNavigation.focusedKeys sweep that produces them. Handing it an already-built
    // array would move that sweep back onto every render and undo the guard.
    let rows: () -> [QueueItem]
    let allItems: [QueueItem]
    let today: String
    let stage: StageFocus?
    var overrides: ProducerOverrides = .none
    var geo: GeoRefusals = .none
    // #1323: a probe and a normal Prep share the single detached-run slot, so the run control greys out
    // while any run is in flight rather than failing after the tap with alreadyRunning.
    let prepRunning: Bool
    // Reports the confirm up to QueueView, which owns the sheet. The bar never starts a run itself.
    let onRun: (_ keys: [String], _ title: String, _ message: String) -> Void

    private var summaryAndKeys: (ProbeSelection.Summary, [String])? {
        QueueModel.probeSelection(dates: selection.dates, in: rows(), among: allItems,
                                  today: today, stage: stage, overrides: overrides, geo: geo)
    }

    var body: some View {
        if let (summary, keys) = summaryAndKeys, !summary.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: OVSpacing.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ProbeSelectionCopy.selectionSummary(summary))
                            .font(OVType.meta.weight(.semibold))
                            .foregroundStyle(OVColor.ink)
                        Text(ProbeSelectionCopy.costLine(summary))
                            .font(OVType.meta)
                            .foregroundStyle(OVColor.inkSoft)
                    }
                    Spacer(minLength: OVSpacing.sm)
                    Button(ProbeSelectionCopy.clearSelection) {
                        selection.clear()
                    }
                    .buttonStyle(.plain)
                    .font(OVType.meta)
                    .foregroundStyle(OVColor.inkSoft)
                    Button {
                        guard !prepRunning else { return }
                        // #1765: the decision is ProbeSelection's, not this closure's. It used to be an
                        // early return that refused a large selection before the confirm sheet, which meant
                        // the one rule deciding whether Dan could run at all lived where no test could
                        // reach it (#863).
                        switch ProbeSelection.outcome(for: summary) {
                        case .nothing:
                            break
                        case .confirm(let title, let message):
                            onRun(keys, title, message)
                        }
                    } label: {
                        Text(ReachabilityProbeCopy.controlLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(prepRunning ? OVColor.onForest.opacity(0.5) : OVColor.onForest)
                            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 3)
                            .background(Capsule().fill(OVColor.forest.opacity(prepRunning ? 0.4 : 1)))
                    }
                    .buttonStyle(.plain)
                    .help(prepRunning ? ReachabilityProbeCopy.controlBusyHelp : "")
                }
            }
            .padding(.horizontal, OVSpacing.xl)
            .padding(.vertical, OVSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Opaque, because it floats OVER the rows rather than sitting above them: anything translucent
            // here would show the content sliding underneath and read as a rendering fault.
            .background(OVColor.canvas)
            .overlay(alignment: .bottom) { Rectangle().fill(OVColor.line).frame(height: 1) }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
