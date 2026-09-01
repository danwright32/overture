import SwiftUI
import SwiftData

// Outcome patterns (#42): booking and response rates grouped by production / discipline /
// tier, over contacted prospects only, so Dan can see what converts before adjusting the
// rules by hand (the safe near-term shape of the deferred auto-tune, #4).
struct OutcomePatternsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var prospects: [Prospect]
    @State private var dimension: OutcomePatterns.Dimension = .production
    @State private var auditTarget: AuditTarget?
    // #5 Phase 4: the opener A/B report opens from here, its analytics sibling, since the toolbar is full.
    @State private var showExperiments = false

    // The segment whose auto-detected bookings the drill-down popover is showing (#212).
    private struct AuditTarget: Identifiable { let value: String; var id: String { value } }

    private var rows: [(name: String, tally: OutcomeTally)] {
        OutcomePatterns.rankedTallies(from: prospects, by: dimension)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("What converts").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Spacer()
                Button("Opener A/B") { showExperiments = true }
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

            // #2989: the empty branch is INSIDE the scroll now rather than replacing it. It used to
            // stand alone, which meant the two report sections below existed only for a store that
            // already had outcomes: a fresh store showed one sentence and nothing else, and neither
            // report could be found at all. That is #1547's defect, a section rendered in one branch of
            // a conditional and absent from the state Dan is actually in.
            ScrollView {
                VStack(alignment: .leading, spacing: OVSpacing.xs) {
                    if rows.isEmpty {
                        Text("No outcomes yet. Once you've sent and recorded results, booking and response rates show up here.")
                            .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, OVSpacing.lg)
                    } else {
                        ForEach(rows, id: \.name) { row in
                            patternRow(name: row.name, tally: row.tally)
                            Divider()
                        }
                    }
                        // #2688: what Dan's genre corrections are teaching, HERE rather than behind a
                        // toolbar button of its own.
                        //
                        // `ToolbarConsolidationGuardTests` pins the toolbar's button count deliberately,
                        // and says why: SwiftUI's builder tops out at ten children, the row already
                        // overflows into the macOS ">>" menu, so a new button is never free and whoever
                        // adds one has to decide what it displaces. The answer here is nothing, because it
                        // does not belong there: this is a report Dan reads when he chooses, and it is a
                        // sibling of the one on this very sheet. Both say what his own decisions add up to.
                    GenreCorrectionsSection()
                    // #2989: what the empty contact answers are claiming, and the one contradiction
                    // visible without opening a card.
                    EmptyAnswerSection()
                    // Milestone 61 Phase 0.3: the shows a check wrote off that turned out to hold a
                    // route. The reader for the contradiction marker, which is the only record that
                    // survives the repair which removed the contradiction itself.
                    WrittenOffBacklogSection()
                }
                .padding(OVSpacing.lg)
            }
        }
        .frame(width: 480, height: 540)
        .background(OVColor.canvas)
        .popover(item: $auditTarget, arrowEdge: .trailing) { target in
            autoBookedList(for: target.value)
        }
        .sheet(isPresented: $showExperiments) { ExperimentReportView() }
    }

    private func patternRow(name: String, tally: OutcomeTally) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(OutcomePatterns.slugLabel(name)).font(OVType.groupName).foregroundStyle(OVColor.ink)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                // #885: the sentences and the low-sample suppression are OutcomePatterns', not this
                // view's. What is left here is layout.
                Text(OutcomePatterns.bookedLine(tally))
                    .foregroundStyle(OVColor.ink)
                if OutcomePatterns.isLowSample(tally) {
                    Text("too few to tell").foregroundStyle(OVColor.inkFaint)
                } else {
                    Text(OutcomePatterns.repliedLine(tally))
                        .foregroundStyle(OVColor.inkSoft)
                    bookingSplit(name: name, tally: tally)
                }
                // #2251: how the lost ones ended, a confirmed silence named apart from a refusal.
                // OUTSIDE the low-sample branch above, because these are counts rather than a rate, and
                // the suppression there exists for percentages that read as signal over two shows.
                if let lost = OutcomePatterns.lostSplitLine(tally) {
                    Text(lost).foregroundStyle(OVColor.inkSoft)
                }
            }
            .font(OVType.meta)
        }
        .padding(.vertical, OVSpacing.xs)
    }

    // Show how the bookings were counted (#117): auto-detected from a Downbeat match versus
    // confirmed by Dan, so a wrong attribution can't silently skew the rate he is told to trust.
    // The auto-detected count is tappable (#212): it opens a drill-down of those exact bookings
    // so Dan can audit them. Empty when there are no bookings to attribute.
    @ViewBuilder private func bookingSplit(name: String, tally: OutcomeTally) -> some View {
        if tally.booked > 0 {
            HStack(spacing: 4) {
                if tally.bookedAuto > 0 {
                    Button { auditTarget = AuditTarget(value: name) } label: {
                        Text(OutcomePatterns.autoDetectedLine(tally)).underline()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OVColor.forestText)
                    .help("Show which bookings were auto-detected")
                    if tally.bookedManual > 0 {
                        Text("·").foregroundStyle(OVColor.inkFaint)
                    }
                }
                if tally.bookedManual > 0 {
                    Text(OutcomePatterns.confirmedByYouLine(tally)).foregroundStyle(OVColor.inkFaint)
                }
            }
        }
    }

    // The drill-down behind a segment's "auto-detected" count (#212): the actual bookings counted,
    // oldest first, so Dan can confirm the rate is built on real matches (and catch a wrong one).
    private func autoBookedList(for value: String) -> some View {
        let bookings = OutcomePatterns.autoBookedBookings(from: prospects, by: dimension, value: value)
        return VStack(alignment: .leading, spacing: OVSpacing.sm) {
            Text("Auto-detected bookings").font(OVType.groupName).foregroundStyle(OVColor.ink)
            ForEach(bookings) { b in
                VStack(alignment: .leading, spacing: 1) {
                    Text(b.groupName).foregroundStyle(OVColor.ink)
                    let detail = [b.performanceDate, b.venue].compactMap { $0 }.joined(separator: " · ")
                    if !detail.isEmpty {
                        Text(detail).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    }
                }
            }
        }
        .padding(OVSpacing.lg)
        .frame(width: 280, alignment: .leading)
    }

}
