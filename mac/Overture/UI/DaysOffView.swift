import SwiftUI
import SwiftData

// #901: the days Overture won't pitch Dan for.
//
// Two sections, held apart in WORDS, because they are different kinds of fact and he can only edit one of
// them. His booked shoots come from Downbeat and are read-only here. His days off are his, typed in as a
// RANGE ("the 14th through the 22nd", not nine clicks), and removable in one.
//
// The sheet also has to say something the app has never said: that Downbeat has told it about no booked
// shoots at all. An empty list with no explanation reads as "you have nothing booked", which is a
// different claim and a false one. The sentence lives in DaysOffAttention, next to the rule that decides
// whether to show it, rather than in this view where nothing could test it (#863).
struct DaysOffView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback
    @Query(sort: \DayOff.startDate) private var daysOff: [DayOff]

    // Built fresh on each render from the export plus the rows above, so the sheet cannot show a calendar
    // that disagrees with the one the scout will use.
    private var calendar: BlockedCalendar {
        ScoutService.blockedCalendar(export: DownbeatBridge.loadedExport(), context: context)
    }

    // #925: bound, not merely read, so pressing "Hide this for a week" redraws this sheet and the toolbar
    // behind it at once. Read through DaysOffAttention, never interpreted here: the value is a timestamp,
    // and a view deciding for itself what a timestamp means is how the toolbar and the sheet would come to
    // different answers about the same fact.
    @AppStorage(DaysOffAttention.snoozeKey) private var snoozedUntil: Double = 0

    @State private var showAdd = false
    @State private var newStart = Date()
    @State private var newEnd = Date()
    @State private var newNote = ""
    @State private var addMessage: String?
    // #928: the add form's state as it was when Dan opened it, so Done can tell a real edit (a moved picker
    // or a typed note) from a form he only opened and left alone, and nag only for the former.
    @State private var addBaseline: DayOffEditing.AddDraft?
    // #901 walk fix: Dan opened the add form, changed the dates, and clicked Done, expecting that to
    // block them; it discarded them silently. Now Done, while the form is open, asks first.
    @State private var confirmUnsaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(OVColor.line)

            if showAdd { addForm; Divider().overlay(OVColor.line) }

            ScrollView {
                VStack(alignment: .leading, spacing: OVSpacing.lg) {
                    bookedShoots
                    myDaysOff
                }
                .padding(OVSpacing.lg)
            }
            .frame(maxHeight: 460)
        }
        .frame(width: 560)
        .background(OVColor.canvas)
        .actionFeedbackBanner()
        .confirmationDialog("You entered days off but haven't blocked them yet.",
                            isPresented: $confirmUnsaved, titleVisibility: .visible) {
            Button("Block these days") {
                // Block, then leave: if the range is bad, keep the sheet open with the reason showing
                // rather than closing on an error he never got to see.
                add()
                if addMessage == nil { dismiss() }
            }
            Button("Discard them", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) { }
        }
    }

    // The add form's editable state right now, in the same ISO-day form the helper compares against.
    private var currentDraft: DayOffEditing.AddDraft {
        DayOffEditing.AddDraft(startDay: EasternDate.dayString(from: newStart),
                               endDay: EasternDate.dayString(from: newEnd),
                               note: newNote)
    }

    // Done, but not at the cost of the range he just typed: the decision lives in the tested helper, so
    // it cannot quietly regress to a bare dismiss(). #928: it also does not nag when the open form was
    // never actually edited.
    private func done() {
        if DayOffEditing.closeNeedsConfirmation(addFormOpen: showAdd, draft: currentDraft, baseline: addBaseline) {
            confirmUnsaved = true
        } else {
            dismiss()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Days off").font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
                Text("The days Overture won't pitch you for.")
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
            }
            Spacer()
            Button(DayOffEditing.addButtonTitle(isOpen: showAdd)) {
                if !showAdd { addBaseline = currentDraft }   // #928: snapshot the form as it opens
                showAdd.toggle(); addMessage = nil
            }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(OVColor.forest)
            Button("Done") { done() }.keyboardShortcut(.defaultAction)
        }
        .padding(OVSpacing.lg)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            // #924: the date fields are shared with the block-these-days picker a dismissal opens, so the
            // two forms cannot drift.
            DayOffRangeFields(start: $newStart, end: $newEnd, note: $newNote)

            if let addMessage {
                Text(addMessage).font(.system(size: 11)).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Block these days") { add() }
            }
        }
        // #901 walk fix: `lg`, matching the header and the section list above and below it. At `md` the
        // date pickers sat tighter to the edge than everything else in the sheet, so "First day" looked
        // like it was running off the side.
        .padding(OVSpacing.lg)
        .background(OVColor.surfaceSunk)
    }

    // #1417: the add and its refusals live in DayOffMutations. What stays here is this form's own state,
    // which is why .notSaved leaves it open: closing it is this screen's way of saying the range was
    // blocked, and it must not say that over a write that failed.
    private func add() {
        switch DayOffMutations.add(start: EasternDate.dayString(from: newStart),
                                   end: EasternDate.dayString(from: newEnd),
                                   note: newNote, context: context, feedback: feedback) {
        case .added:
            addMessage = nil; newNote = ""; showAdd = false
        case .refused(let text):
            addMessage = text
        case .notSaved:
            break
        }
    }

    // #925: away for a week, and it says so without pretending anything was solved. The sheet stays open:
    // the next thing he should do is block the days himself, and that form is right here.
    private func snooze() {
        DaysOffAttention.snooze(now: Date())
        feedback.acknowledge(ActionAck.daysOffSnoozed(), tone: .warning)
    }

    // MARK: - Downbeat's half: read-only, and honest about being empty

    private var bookedShoots: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            sectionHeading("Booked shoots", systemImage: "camera",
                           count: calendar.days.filter { $0.kind == .bookedShoot }.count)

            // #925: the explanation is gated on the FACT (no upcoming shoots), never on the snooze. The
            // snooze silences the toolbar mark, and only that. Hiding this sentence too would put the
            // empty list straight back to reading as "you have nothing booked", which is a different
            // claim and a false one, and it is the exact misreading this whole feature exists to stop.
            if !calendar.hasUpcomingBookedShoot(today: QueueModel.easternToday()) {
                Text(DaysOffAttention.noBookedShootsExplanation)
                    .font(.system(size: 11)).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
                // The dismiss lives HERE, under the explanation, and not on the toolbar button itself.
                // Putting a warning away should cost Dan the ten seconds of having read what he is putting
                // away; a one-click silence from the masthead is how a warning gets dismissed reflexively
                // and then forgotten. Offered only while the mark is actually up.
                if DaysOffAttention.needsALook(calendar) {
                    Button(DaysOffAttention.snoozeButtonTitle) { snooze() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OVColor.forest)
                        .padding(.top, 2)
                }
            } else {
                ForEach(calendar.days.filter { $0.kind == .bookedShoot }, id: \.key) { day in
                    HStack(spacing: OVSpacing.sm) {
                        Text(EasternDate.dayLabel(day.date) ?? day.date)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(OVColor.ink)
                        Text(day.name ?? "A shoot")
                            .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
                        Spacer()
                        Text("From Downbeat").font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    // MARK: - Dan's half: his to add and remove

    private var myDaysOff: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            sectionHeading("Days you blocked", systemImage: "calendar", count: daysOff.count)

            if daysOff.isEmpty {
                Text("Nothing blocked. Add a vacation and Overture will stop pitching you for those nights.")
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
            } else {
                ForEach(daysOff) { row in
                    HStack(spacing: OVSpacing.sm) {
                        Text(QueueModel.runDateLabel(start: row.startDate, end: row.endDate))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(OVColor.ink)
                        if let note = row.note {
                            Text(note).font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
                        }
                        Spacer()
                        Button("Remove") { remove(row) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OVColor.forest)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    // #1417: lives in DayOffMutations now, so the removal, its Undo, and the rule that neither claims
    // success before the change is saved are testable (#863).
    private func remove(_ row: DayOff) {
        DayOffMutations.remove(row, context: context, feedback: feedback)
    }

    private func sectionHeading(_ title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: OVSpacing.xxs) {
            Image(systemName: systemImage).font(.system(size: 11))
            Text(title).font(.system(size: 12, weight: .semibold))
            Text("(\(count))").font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
        }
        .foregroundStyle(OVColor.ink)
    }
}
