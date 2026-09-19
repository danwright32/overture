import SwiftUI
import SwiftData

// #953: the per-run picker "Prep kept" opens. Dan chooses which kept, undrafted shows a single Prep run
// covers. #2365: every eligible row opens CHECKED, whatever its date, because Scout is the only surface
// that applies a lead time window and a show can only have reached this list by Dan keeping it. All of
// the sheet's wording lives in PrepSelectionCopy so it stays testable (#885).
//
// #3325 (plan 3.1, 3.2): and now, per run, WHICH NIGHTS. This reverses two things this comment used to
// promise, deliberately and in the same change (L613):
//
// - "The selection is per-run and transient: nothing persists." The night choices PERSIST: the launch
//   commits them to `Prospect.pitchedRunNights` / `skippedRunNights` before the run starts, because
//   Dan's answer 1 (2026-09-17) is that the choice is RECORDED. Which SHOWS a run covers is still
//   transient, exactly as before.
// - "The sheet never holds a SwiftData model." It still does not. The night plan it reads is a value
//   built once when the sheet opens (`PrepNightPlan`), and the commit happens in the caller, against the
//   store, after this sheet hands back its choices.
//
// The picker never dismisses a card and never calls `dropNight`, so it never re-keys a row: the keys this
// sheet holds stay the keys of the rows it shows (plan 3.2's hazard is not reachable from here). Unticking
// every night of a run leaves that show out of this run and says so; dismissing it is still the card's
// job, which asks for a reason (Dan, 2026-08-30).
struct PrepSelectionSheet: View {
    // #3859: this sheet has a `StallSurface` case of its own now, so a stall recorded while it is on
    // screen is attributed to it. #3762's rule follows from that: the surface a stall is attributed to
    // has to count its own rebuilds, or the record reads `passes: 0`, and `0` there says the surface did
    // not rebuild rather than that nobody counted (L11).
    //
    // Read as an OPTIONAL, on the same footing as every other environment object here, so a missed
    // injection is a pass nobody counted rather than a crash.
    @Environment(FreezeWatch.self) private var freezeWatch: FreezeWatch?
    @Environment(\.dismiss) private var dismiss

    // A value-type snapshot of each eligible prospect, so the sheet never holds a SwiftData model across
    // the run or reaches back into the store while it is open.
    struct Row: Identifiable {
        let id: String        // the prospect's naturalKey
        let groupName: String
        let detail: String    // venue and date, already rendered (may be empty)
    }

    // What the sheet hands back: the shows this run covers and, for each run whose nights it offered,
    // the per-night decisions to commit BEFORE the run starts (plan 3.6).
    struct Choice: Equatable {
        let keys: Set<String>
        let commits: [String: PrepNightPlan.Commit]
    }

    let rows: [Row]
    let onRun: (Choice) -> Void
    // #1219: the whole queue as QueueItems, so the Run button can detect a self-booking clash between a
    // selected show and a committed show in ANY stage before launching (the batch half of the prep gate).
    let allItems: [QueueItem]
    let plan: PrepNightPlan

    // The checked rows. Seeded from the date default in init; every change after that is Dan's own toggle.
    @State private var selected: Set<String>
    // #3325: the ticked nights of each per-night run, seeded from the plan's defaults.
    @State private var ticks: [String: Set<String>]
    // Which disclosures are open now, and which were ever opened: a run Dan looked at commits `chosen`.
    @State private var expanded: Set<String>
    @State private var opened: Set<String>
    @State private var pendingClashConfirm = false
    @State private var clashMessage = ""
    // #3366: the title varies with WHICH kind of clash was found, so it is staged beside the message
    // rather than being a constant on the sheet.
    @State private var clashTitle = ""
    // The clock the commit is stamped with. Injected so a rendering or a test does not read the wall clock.
    private let now: () -> Date

    init(prospects: [Prospect], allItems: [QueueItem] = [], plan: PrepNightPlan = .empty,
         now: @escaping () -> Date = Date.init,
         onRun: @escaping (Choice) -> Void) {
        self.onRun = onRun
        self.allItems = allItems
        self.plan = plan
        self.now = now
        // #3375: ordered before it is mapped, through the rule in PrepQueueBuilder rather than one
        // spelled here, so the sheet holds no ordering of its own to drift.
        self.rows = PrepQueueBuilder.prepSelectionOrder(prospects: prospects).map { p in
            Row(id: p.naturalKey, groupName: p.groupName,
                detail: PrepSelectionCopy.rowDetail(venue: p.venue, performanceDate: p.performanceDate))
        }
        // #2365: every eligible show, decided in PrepQueueBuilder so this view holds no rule.
        _selected = State(initialValue: PrepQueueBuilder.prepDefaultSelection(prospects: prospects))
        var seededTicks: [String: Set<String>] = [:]
        var open: Set<String> = []
        for (key, run) in plan.runs {
            guard let nights = run.perNight else { continue }
            seededTicks[key] = Set(nights.filter(\.defaultTicked).map(\.date))
            if run.opensByDefault { open.insert(key) }
        }
        _ticks = State(initialValue: seededTicks)
        _expanded = State(initialValue: open)
        _opened = State(initialValue: open)
    }

    // The shows this press would actually prep: a checked row, less any per-night run with no night left.
    private var launching: Set<String> {
        selected.filter { key in
            guard plan.runs[key]?.perNight != nil else { return true }
            return !(ticks[key] ?? []).isEmpty
        }
    }

    private var choice: Choice {
        let keys = launching
        var commits: [String: PrepNightPlan.Commit] = [:]
        let stamp = now()
        for key in keys {
            if let c = plan.commit(key: key, ticked: ticks[key] ?? [], opened: opened.contains(key), now: stamp) {
                commits[key] = c
            }
        }
        return Choice(keys: keys, commits: commits)
    }

    var body: some View {
        // #3859: this surface counts its own rebuild. Bound to `_` rather than called as a statement
        // because `body` is a ViewBuilder, which takes a declaration and not a bare void expression.
        let _ = freezeWatch?.recordPass()
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PrepSelectionCopy.title).font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Text(PrepSelectionCopy.subtitle)
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                // #3311: a calendar that could not be read says so ONCE, here, rather than letting every
                // unmarked night read as a clear one.
                if plan.calendar == .couldNotRead {
                    Text(PrepSelectionCopy.calendarUnread)
                        .font(.system(size: 12)).foregroundStyle(OVColor.rust)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            CappedScrollView(maxHeight: 360) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                        if row.id != rows.last?.id { Divider() }
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(PrepSelectionCopy.runButton(launching.count)) {
                    let keys = launching
                    // #1219: a selected show sitting on a date that already holds a committed pitch.
                    // #3366: and a selected show sitting on a night the CALENDAR has spoken for.
                    // #3325: judged per NIGHT for a run whose nights the sheet offers, through the plan,
                    // which asks the same predicate the card's own clash comes from.
                    let selfBooking = SelfBookingCopy.prepConfirmMessage(
                        QueueModel.selfBookingPrepClashes(forKeys: keys, among: allItems))
                    let calendar = PrepLaunchCopy.calendarClashMessage(
                        plan.calendarClashes(forKeys: keys, ticks: ticks, among: allItems))
                    if let message = PrepLaunchCopy.combinedMessage(selfBooking: selfBooking,
                                                                    calendar: calendar),
                       let title = PrepLaunchCopy.confirmTitle(selfBooking: selfBooking != nil,
                                                               calendar: calendar != nil) {
                        clashMessage = message
                        clashTitle = title
                        pendingClashConfirm = true
                    } else {
                        onRun(choice)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(launching.isEmpty)
            }
        }
        .padding(OVSpacing.lg)
        // #1249: first-party branded confirm (SelfBookingConfirmSheet), not a stock system dialog.
        .sheet(isPresented: $pendingClashConfirm) {
            SelfBookingConfirmSheet(
                title: clashTitle,
                message: clashMessage,
                proceedLabel: PrepLaunchCopy.proceedLabel,
                onProceed: { pendingClashConfirm = false; onRun(choice); dismiss() },
                onCancel: { pendingClashConfirm = false })
        }
        .frame(width: 460)
        .background(OVColor.canvas)
    }

    private func rowView(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            Toggle(isOn: binding(for: row.id)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.groupName).font(OVType.body).foregroundStyle(OVColor.ink)
                    if !row.detail.isEmpty {
                        Text(row.detail).font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
                    }
                }
            }
            .toggleStyle(.checkbox)
            nightsView(row)
                .padding(.leading, 20)
        }
        .padding(.vertical, OVSpacing.xs)
    }

    @ViewBuilder
    private func nightsView(_ row: Row) -> some View {
        switch plan.runs[row.id]?.nights {
        case .perNight(let nights)?:
            let chosen = ticks[row.id] ?? []
            DisclosureGroup(isExpanded: expandedBinding(for: row.id)) {
                // Built INSIDE the disclosure's closure (plan 3.1): the sheet is not a lazy container,
                // so nights built outside would be constructed for every run whether or not it is open.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(PrepSelectionCopy.weeks(nights.map(\.date)), id: \.label) { week in
                        Text(week.label)
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(OVColor.inkFaint)
                            .padding(.top, 4)
                        ForEach(nights.filter { week.nights.contains($0.date) }) { night in
                            nightRow(night, run: row.id)
                        }
                    }
                }
                .padding(.top, 2)
            } label: {
                Text(PrepSelectionCopy.nightsSummary(ticked: chosen.count, of: nights.count))
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
            }
            .disabled(!selected.contains(row.id))
            if selected.contains(row.id) && chosen.isEmpty {
                Text(PrepSelectionCopy.noNightLeft)
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .notRecorded?:
            Text(PrepSelectionCopy.nightsNotRecorded)
                .font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        case .single?, nil:
            EmptyView()
        }
    }

    private func nightRow(_ night: PrepNightPlan.Night, run key: String) -> some View {
        Toggle(isOn: nightBinding(run: key, night: night.date)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(PrepSelectionCopy.nightLabel(night.date)).font(.system(size: 12)).foregroundStyle(OVColor.ink)
                if let note = PrepSelectionCopy.clashNote(night.clash) {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(isBlocked(night.clash) ? OVColor.rust : OVColor.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func isBlocked(_ clash: PrepNightPlan.Clash) -> Bool {
        if case .blocked = clash { return true }
        return false
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(key) },
            set: { isOn in
                if isOn { selected.insert(key) } else { selected.remove(key) }
            }
        )
    }

    private func expandedBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(key) },
            set: { isOpen in
                if isOpen { expanded.insert(key); opened.insert(key) } else { expanded.remove(key) }
            }
        )
    }

    private func nightBinding(run key: String, night: String) -> Binding<Bool> {
        Binding(
            get: { ticks[key]?.contains(night) ?? false },
            set: { isOn in
                var set = ticks[key] ?? []
                if isOn { set.insert(night) } else { set.remove(night) }
                ticks[key] = set
                opened.insert(key)   // touching a night is looking at the run
            }
        )
    }
}
