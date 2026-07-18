import SwiftUI
import SwiftData

// #953: the per-run picker "Prep kept" opens. Dan chooses which kept, undrafted shows a single Prep run
// covers, so a long lead-time show is not drafted before it is worth reaching out. Each row defaults by
// how far out its performance is (PrepQueueBuilder.defaultsIncludedInPrepRun): inside the four-month
// calendar horizon it opens checked, beyond it held. The selection is PER-RUN and transient: nothing
// persists, so reopening the sheet re-defaults by date, and there is no stored "hold" flag. All of the
// sheet's wording lives in PrepSelectionCopy so it stays testable (#885).
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

    // The checked rows. Seeded from the date default in init; every change after that is Dan's own toggle.
    @State private var selected: Set<String>

    init(prospects: [Prospect], now: Date = Date(), onRun: @escaping (Set<String>) -> Void) {
        self.onRun = onRun
        self.rows = prospects.map { p in
            Row(id: p.naturalKey, groupName: p.groupName,
                detail: PrepSelectionCopy.rowDetail(venue: p.venue, performanceDate: p.performanceDate))
        }
        let defaults = prospects
            .filter { PrepQueueBuilder.defaultsIncludedInPrepRun(performanceDate: $0.performanceDate, now: now) }
            .map(\.naturalKey)
        _selected = State(initialValue: Set(defaults))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PrepSelectionCopy.title).font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Text(PrepSelectionCopy.subtitle)
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                        if row.id != rows.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 360)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(PrepSelectionCopy.runButton(selected.count)) {
                    onRun(selected)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(OVSpacing.lg)
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
