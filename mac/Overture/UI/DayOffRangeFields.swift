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
                // #2254: the last day cannot be set before the first, and when the first moves past it it
                // is carried along. Both halves live here rather than in either sheet, so the Days off
                // form and the block-these-days picker cannot end up with different rules about the same
                // two fields.
                DatePicker("Last day", selection: $end, in: start..., displayedComponents: .date)
                // Pin the pickers left with a guaranteed gap on the right, so the year's stepper never
                // crowds the container edge (#901 walk fix).
                Spacer(minLength: OVSpacing.sm)
            }
            .font(.system(size: 12))
            .datePickerStyle(.compact)
            // The other half: a range constraint stops a bad END being picked, but it cannot stop the
            // FIRST day being moved past a good end, which is the case Dan actually hit.
            .onChange(of: start) { _, moved in
                end = DayOffEditing.endMovedWithStart(start: moved, end: end)
            }

            TextField("Why (optional): vacation, family, anything", text: $note)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
            Text("Both days are included, so a Friday to Sunday trip is three blocked days.")
                .font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
