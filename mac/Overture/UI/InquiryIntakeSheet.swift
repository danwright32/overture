import SwiftUI
import SwiftData

// #1435/#1436: "Log an inquiry." Dan hand-enters a direct hire inquiry (contact form or email) so it
// is tracked alongside the scout/pitch queue instead of living only in his inbox. Only the name is
// required; the event, date, and venue can all be unknown at intake. The soft duplicate note warns
// when he has already logged this event but never blocks: an under-specified inquiry must still save.
struct InquiryIntakeSheet: View {
    // #1504: nil logs a new inquiry, non-nil edits that one. The same sheet serves both so the fields
    // and their normalization cannot drift apart between logging and correcting.
    var editing: Inquiry?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback
    @Query private var existing: [Inquiry]

    @State private var source: InquirySource = .directEmail
    @State private var name = ""
    @State private var email = ""
    @State private var eventName = ""
    @State private var hasDate = false
    @State private var date = Date()
    @State private var venue = ""
    @State private var notes = ""
    @State private var loaded = false

    private var canSave: Bool { InquiryIntake.canSave(name: name) }

    private var performanceDate: String? {
        InquiryIntake.performanceDate(hasDate: hasDate, date: date)
    }

    private var duplicate: Inquiry? {
        let key = Inquiry.makeNaturalKey(eventName: eventName, performanceDate: performanceDate,
                                         venue: venue.isEmpty ? nil : venue)
        // Excluding the one being edited, or every inquiry Dan opens reports itself as already logged.
        return InquiryIntake.duplicate(ofKey: key, in: existing, excluding: editing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            header
            fields
            if duplicate != nil {
                // The second half matches the button's verb: on an edit there is nothing to "add".
                Text(InquiryCopy.intakeDuplicateWarning(isEditing: editing != nil))
                    .font(OVType.meta).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(OVSpacing.lg)
        .frame(width: 520)
        .onAppear(perform: loadIfEditing)
    }

    // Fields come from the record once, on open. Guarded so a redraw can't overwrite what Dan has
    // started typing (#dont-silently-discard-in-progress-input).
    private func loadIfEditing() {
        guard let editing, !loaded else { return }
        loaded = true
        source = editing.source
        name = editing.inquirerName
        email = editing.inquirerEmail ?? ""
        eventName = editing.eventName
        (hasDate, date) = InquiryIntake.editingDate(from: editing.performanceDate)
        venue = editing.venue ?? ""
        notes = editing.notes ?? ""
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(InquiryCopy.intakeTitle(isEditing: editing != nil))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
            // Only the intake case needs explaining what an inquiry is; on an edit Dan is looking at
            // one he already logged, so the line would tell him nothing he isn't already reading.
            if editing == nil {
                Text("Someone reaching out to hire you. You write the first reply yourself.")
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            Picker("How they reached you", selection: $source) {
                ForEach(InquirySource.allCases, id: \.self) { option in Text(option.label).tag(option) }
            }
            .pickerStyle(.segmented)

            TextField("Their name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Their email (optional)", text: $email).textFieldStyle(.roundedBorder)
            TextField("Event (optional)", text: $eventName).textFieldStyle(.roundedBorder)

            Toggle(isOn: $hasDate) {
                Text("The date is known").font(OVType.body).foregroundStyle(OVColor.ink)
            }
            .toggleStyle(.checkbox)
            if hasDate {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.field).labelsHidden()
            }

            TextField("Venue (optional)", text: $venue).textFieldStyle(.roundedBorder)
            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
            Button(action: save) {
                Text(InquiryCopy.intakeSaveButton(isEditing: editing != nil))
                    .font(OVType.meta).foregroundStyle(OVColor.onForest)
                    .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                    .background(Capsule().fill(OVColor.forest))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
    }

    private func save() {
        InquiryIntake.save(editing: editing, source: source, name: name, email: email,
                           eventName: eventName, performanceDate: performanceDate,
                           venue: venue, notes: notes, in: context, feedback: feedback)
        dismiss()
    }
}
