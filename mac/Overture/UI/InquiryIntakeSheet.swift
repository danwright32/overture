import SwiftUI
import SwiftData

// #1435/#1436: "Log an inquiry." Dan hand-enters a direct hire inquiry (contact form or email) so it
// is tracked alongside the scout/pitch queue instead of living only in his inbox. Only the name is
// required; the event, date, and venue can all be unknown at intake. The soft duplicate note warns
// when he has already logged this event but never blocks: an under-specified inquiry must still save.
struct InquiryIntakeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var existing: [Inquiry]

    @State private var source: InquirySource = .directEmail
    @State private var name = ""
    @State private var email = ""
    @State private var eventName = ""
    @State private var hasDate = false
    @State private var date = Date()
    @State private var venue = ""
    @State private var notes = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var performanceDate: String? {
        hasDate ? EasternDate.dayString(from: date) : nil
    }

    private var duplicate: Inquiry? {
        let key = Inquiry.makeNaturalKey(eventName: eventName, performanceDate: performanceDate,
                                         venue: venue.isEmpty ? nil : venue)
        return InquiryIntake.duplicate(ofKey: key, in: existing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            header
            fields
            if duplicate != nil {
                Text("You've already logged an inquiry for this event. You can still add this one.")
                    .font(OVType.meta).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(OVSpacing.lg)
        .frame(width: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Log an inquiry").font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
            Text("Someone reaching out to hire you. You write the first reply yourself.")
                .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
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
                Text("Log inquiry").font(OVType.meta).foregroundStyle(OVColor.onForest)
                    .padding(.horizontal, OVSpacing.md).padding(.vertical, 5)
                    .background(Capsule().fill(OVColor.forest))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
    }

    private func save() {
        InquiryIntake.create(source: source, name: name, email: email, eventName: eventName,
                             performanceDate: performanceDate, venue: venue, notes: notes, in: context)
        dismiss()
    }
}
