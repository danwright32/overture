import SwiftUI
import SwiftData

// #953: the per-run picker "Prep kept" opens. Dan chooses which kept, undrafted shows a single Prep run
// covers. #2365: every eligible row opens CHECKED, whatever its date, because Scout is the only surface
// that applies a lead time window and a show can only have reached this list by Dan keeping it. The
// selection is PER-RUN and transient: nothing persists, so reopening the sheet starts from every row
// again, and there is no stored "hold" flag. All of the sheet's wording lives in PrepSelectionCopy so it
// stays testable (#885).
struct PrepSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    // A value-type snapshot of each eligible prospect, so the sheet never holds a SwiftData model across
    // the run or reaches back into the store while it is open.
    struct Row: Identifiable {
        let id: String        // the prospect's naturalKey
        let groupName: String
        let detail: String    // venue and date, already rendered (may be empty)
    }

    let rows: [Row]
    let onRun: (Set<String>) -> Void
    // #1219: the whole queue as QueueItems, so the Run button can detect a self-booking clash between a
    // selected show and a committed show in ANY stage before launching (the batch half of the prep gate).
    let allItems: [QueueItem]

    // The checked rows. Seeded from the date default in init; every change after that is Dan's own toggle.
    @State private var selected: Set<String>
    @State private var pendingClashConfirm = false
    @State private var clashMessage = ""

    init(prospects: [Prospect], allItems: [QueueItem] = [],
         onRun: @escaping (Set<String>) -> Void) {
        self.onRun = onRun
        self.allItems = allItems
        self.rows = prospects.map { p in
            Row(id: p.naturalKey, groupName: p.groupName,
                detail: PrepSelectionCopy.rowDetail(venue: p.venue, performanceDate: p.performanceDate))
        }
        // #2365: every eligible show, decided in PrepQueueBuilder so this view holds no rule.
        _selected = State(initialValue: PrepQueueBuilder.prepDefaultSelection(prospects: prospects))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PrepSelectionCopy.title).font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Text(PrepSelectionCopy.subtitle)
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CappedScrollView(maxHeight: 360) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                        if row.id != rows.last?.id { Divider() }
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(PrepSelectionCopy.runButton(selected.count)) {
                    // #1219: if any selected show sits on a date that already holds a committed pitch,
                    // confirm past the possible double-booking before launching; otherwise run straight away.
                    if let message = SelfBookingCopy.prepConfirmMessage(
                        QueueModel.selfBookingPrepClashes(forKeys: selected, among: allItems)) {
                        clashMessage = message
                        pendingClashConfirm = true
                    } else {
                        onRun(selected)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(OVSpacing.lg)
        // #1249: first-party branded confirm (SelfBookingConfirmSheet), not a stock system dialog.
        .sheet(isPresented: $pendingClashConfirm) {
            SelfBookingConfirmSheet(
                title: SelfBookingCopy.prepConfirmTitle,
                message: clashMessage,
                proceedLabel: SelfBookingCopy.prepConfirmProceed,
                onProceed: { pendingClashConfirm = false; onRun(selected); dismiss() },
                onCancel: { pendingClashConfirm = false })
        }
        .frame(width: 460)
        .background(OVColor.canvas)
    }

    private func rowView(_ row: Row) -> some View {
        Toggle(isOn: binding(for: row.id)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.groupName).font(OVType.body).foregroundStyle(OVColor.ink)
                if !row.detail.isEmpty {
                    Text(row.detail).font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, OVSpacing.xs)
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(key) },
            set: { isOn in
                if isOn { selected.insert(key) } else { selected.remove(key) }
            }
        )
    }
}
