import SwiftUI

// #924: the first-day / last-day / why fields for blocking a stretch of days off, shared by the Days off
// sheet's add form and the block-these-days picker that a dismissal opens, so the two never drift into
// two slightly different date forms. The parent owns the bindings, the button, and any validation message;
// this is just the fields.
struct DayOffRangeFields: View {
    @Binding var start: Date
    @Binding var end: Date
    @Binding var note: String

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            HStack(spacing: OVSpacing.md) {
                DatePicker("First day", selection: $start, displayedComponents: .date)
                DatePicker("Last day", selection: $end, displayedComponents: .date)
                // Pin the pickers left with a guaranteed gap on the right, so the year's stepper never
                // crowds the container edge (#901 walk fix).
                Spacer(minLength: OVSpacing.sm)
            }
            .font(.system(size: 12))
            .datePickerStyle(.compact)

            TextField("Why (optional): vacation, family, anything", text: $note)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
            Text("Both days are included, so a Friday to Sunday trip is three blocked days.")
                .font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
