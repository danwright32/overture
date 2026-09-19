import SwiftUI

// #3620: the fields for blocking one weekday every week, the sibling of `DayOffRangeFields` and built from
// the same controls (a native compact date picker, a rounded text field, the same type sizes), so the Days
// off form reads as one form whichever kind of block is being added. The parent owns the bindings, the
// button and any refusal, as it does for the range.
struct WeeklyDayOffFields: View {
    @Binding var weekday: Int
    @Binding var hasFirst: Bool
    @Binding var first: Date
    @Binding var hasLast: Bool
    @Binding var last: Date
    @Binding var note: String

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            HStack(spacing: OVSpacing.md) {
                Picker("Every", selection: $weekday) {
                    ForEach(WeeklyDayOffEditing.weekdays, id: \.number) { day in
                        Text(day.name).tag(day.number)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer(minLength: OVSpacing.sm)
            }
            // Both bounds are optional, and all four combinations mean something (#3620's table), so each is
            // a box he ticks rather than a date that is always there and always means something.
            HStack(spacing: OVSpacing.md) {
                Toggle("From", isOn: $hasFirst)
                if hasFirst {
                    DatePicker("From", selection: $first, displayedComponents: .date).labelsHidden()
                }
                Toggle("Until", isOn: $hasLast)
                if hasLast {
                    DatePicker("Until", selection: $last, in: (hasFirst ? first : .distantPast)...,
                               displayedComponents: .date).labelsHidden()
                }
                Spacer(minLength: OVSpacing.sm)
            }
            .datePickerStyle(.compact)
            // The same carry-along rule the range form has (#2254): an end before the start is never shown.
            .onChange(of: first) { _, moved in
                last = DayOffEditing.endMovedWithStart(start: moved, end: last)
            }

            TextField("Why (optional): rehearsal, class, anything", text: $note)
                .textFieldStyle(.roundedBorder)
        }
        .font(.system(size: 12))
    }
}
