import SwiftUI
import SwiftData

// #924: the date picker a calendar-reason dismissal opens. Every calendar-reason dismissal opens this
// sheet, single-night or multi-night alike (revised after Dan walked the first build, 2026-07-15): there
// is no separate one-tap banner path.
//
// #2373: both pickers open on the night that was dismissed and nothing wider, because the default button
// blocks whatever they propose. Widening is Dan's to type.
//
// It writes through ProspectMutations.blockDaysOff, the same writer the one-tap path uses, so both go
// through DayOffEditing.add and its conflict sweep. A refused range keeps the sheet open with the reason
// showing (via the shared feedback banner), rather than closing on an error Dan never saw.
struct BlockDaysSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback
    @Environment(DayOffOfferRequest.self) private var offer

    let pending: DayOffOfferRequest.Pending
    // #1473: handed in by RootView rather than read from the environment. An environment lookup that came
    // back empty here would attach nothing and say nothing, and the resulting half-undo (the show back, the
    // night still blocked) is precisely the bug this closes, so it must not be reachable by accident.
    let undo: QueueUndoStack

    @State private var start: Date
    @State private var end: Date
    @State private var note: String

    init(pending: DayOffOfferRequest.Pending, undo: QueueUndoStack) {
        self.pending = pending
        self.undo = undo
        _start = State(initialValue: EasternDate.date(from: pending.start) ?? Date())
        _end = State(initialValue: EasternDate.date(from: pending.end) ?? Date())
        _note = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Block days off").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Text(DayOffOffer.pickerSubtitle(org: pending.org))
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DayOffRangeFields(start: $start, end: $end, note: $note)

            HStack {
                Button("Not now") { offer.clear(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Block these days") { block() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(OVSpacing.lg)
        .frame(width: 460)
        .background(OVColor.canvas)
        .actionFeedbackBanner()
    }

    // Block, then leave: if the range is bad, blockDaysOff surfaces the reason on the banner and returns
    // false, so the sheet stays open on the reason rather than closing on an error Dan never got to see.
    private func block() {
        let ok = ProspectMutations.blockDaysOff(start: EasternDate.dayString(from: start),
                                                end: EasternDate.dayString(from: end),
                                                note: note, context: context, feedback: feedback,
                                                undo: undo, undoDismissOf: pending.id)
        if ok { offer.clear(); dismiss() }
    }
}
