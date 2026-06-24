import SwiftUI
import SwiftData

// Outcome patterns (#42): booking and response rates grouped by production / discipline /
// tier, over contacted prospects only, so Dan can see what converts before adjusting the
// rules by hand (the safe near-term shape of the deferred auto-tune, #4).
struct OutcomePatternsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var prospects: [Prospect]
    @State private var dimension: OutcomePatterns.Dimension = .production

    private var rows: [(name: String, tally: OutcomeTally)] {
        OutcomePatterns.rankedTallies(from: prospects, by: dimension)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("What converts").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(OVSpacing.lg)

            Picker("Group by", selection: $dimension) {
                ForEach(OutcomePatterns.Dimension.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, OVSpacing.lg)
            .padding(.bottom, OVSpacing.sm)
            Divider()

            if rows.isEmpty {
                Text("No outcomes yet. Once you've sent and recorded results, booking and response rates show up here.")
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(OVSpacing.xl)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: OVSpacing.xs) {
                        ForEach(rows, id: \.name) { row in
                            patternRow(name: row.name, tally: row.tally)
                            Divider()
                        }
                    }
                    .padding(OVSpacing.lg)
                }
            }
        }
        .frame(width: 480, height: 540)
        .background(OVColor.canvas)
    }

    private func patternRow(name: String, tally: OutcomeTally) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label(for: name)).font(OVType.groupName).foregroundStyle(OVColor.ink)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                let lowSample = OutcomePatterns.isLowSample(tally)
                Text("\(tally.booked) booked of \(tally.contacted)\(lowSample ? "" : percent(tally.bookingRate))")
                    .foregroundStyle(OVColor.ink)
                if lowSample {
                    Text("too few to tell").foregroundStyle(OVColor.inkFaint)
                } else {
                    Text("\(tally.replied + tally.booked) replied\(percent(tally.responseRate))")
                        .foregroundStyle(OVColor.inkSoft)
                }
            }
            .font(OVType.meta)
        }
        .padding(.vertical, OVSpacing.xs)
    }

    private func percent(_ rate: Double?) -> String {
        guard let rate else { return "" }
        return " · \(Int((rate * 100).rounded()))%"
    }

    private func label(for name: String) -> String {
        // Values are short slugs ("self", "agency", "choral", "high"); a readable cap is enough.
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
