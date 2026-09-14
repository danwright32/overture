import SwiftUI
import SwiftData

// Outcome patterns (#42): booking and response rates grouped by production / discipline /
// tier, over contacted prospects only, so Dan can see what converts before adjusting the
// rules by hand (the safe near-term shape of the deferred auto-tune, #4).
struct OutcomePatternsView: View {
    // #3859: this sheet has a `StallSurface` case of its own now, so a stall recorded while it is on
    // screen is attributed to it. #3762's rule follows from that: the surface a stall is attributed to
    // has to count its own rebuilds, or the record reads `passes: 0`, and `0` there says the surface did
    // not rebuild rather than that nobody counted (L11).
    //
    // Read as an OPTIONAL, on the same footing as every other environment object here, so a missed
    // injection is a pass nobody counted rather than a crash.
    @Environment(FreezeWatch.self) private var freezeWatch: FreezeWatch?
    // #3871: the whole store, HANDED DOWN rather than queried again here.
    //
    // It was `@Query private var prospects: [Prospect]`, a bare descriptor identical to the one RootView
    // already holds. Measured 2026-09-12 by #3764 on the live store, two identical bare descriptors held
    // by two live views share NOTHING: the second costs 99.6% of the first, 158.8 ms against 159.5 ms
    // over 1,238 rows, against an end to end store change of 350.7 ms. So this sheet used to add a whole
    // table read to every store change for as long as it was open.
    //
    // NO DEFAULT, for the reason ArchiveView's carries: an empty default renders an empty sheet that
    // looks exactly like an empty store (L168, L67).
    let prospects: [Prospect]
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
        // #3859: this surface counts its own rebuild. Bound to `_` rather than called as a statement
        // because `body` is a ViewBuilder, which takes a declaration and not a bare void expression.
        let _ = freezeWatch?.recordPass()
        // #3852: bound ONCE. `rows` is a computed property that tallies the whole prospect store, and it
        // was read twice in this body, once to ask whether it was empty and once to draw it, so opening
        // this sheet ran the tally twice for one question. A computed property reads as a free field
        // access at the call site and nothing there says what it costs (L383). Bound here rather than
        // pushed into a render pass because this view declares none, which is the rule
        // `ARepeatedDerivationIsFoundTests` states in its own failure message.
        let listed = rows
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("What converts").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Spacer()
                Button("Opener A/B") { showExperiments = true }
                DoneButton()
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
                    if listed.isEmpty {
                        Text("No outcomes yet. Once you've sent and recorded results, booking and response rates show up here.")
                            .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, OVSpacing.lg)
                    } else {
                        ForEach(listed, id: \.name) { row in
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
                    EmptyAnswerSection(prospects: prospects)
                    // Milestone 61 Phase 0.3: the shows a check wrote off that turned out to hold a
                    // route. The reader for the contradiction marker, which is the only record that
                    // survives the repair which removed the contradiction itself.
                    WrittenOffBacklogSection(prospects: prospects)
                }
                .padding(OVSpacing.lg)
            }
        }
        .frame(width: 480, height: 540)
        .background(OVColor.canvas)
        .popover(item: $auditTarget, arrowEdge: .trailing) { target in
            autoBookedList(for: target.value)
        }
        .sheet(isPresented: $showExperiments) { ExperimentReportView(prospects: prospects) }
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
