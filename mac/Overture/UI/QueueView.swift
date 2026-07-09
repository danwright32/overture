import SwiftUI
import SwiftData
import AppKit

// The window Dan lives in: ranked performances, grouped by date, kept or dismissed.
struct QueueView: View {
    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback   // #285: shared acknowledgment surface

    // Dismissed prospects drop out of the queue; the rest sort date asc, fit desc. The
    // "hide untouched-gone" rule (#133) lives in QueueModel.queueOrder, not here, because a
    // compound predicate overruns the #Predicate type-checker.
    @Query(
        filter: #Predicate<Prospect> { $0.statusRaw != "dismissed" },
        sort: [SortDescriptor(\Prospect.performanceDate, order: .forward),
               SortDescriptor(\Prospect.fitScore, order: .reverse)]
    )
    private var prospects: [Prospect]

    @State private var disciplineFilter: String?
    @State private var highOnly = false
    @State private var showPendingBookingsOnly = false
    @State private var pipeline: Pipeline = .toSend
    @State private var pendingConfirm: PendingSend?
    @State private var showReconnect = false
    // #436: in-flight sends, so a tapped Send shows a live "Sending…" state instead of a dead button.
    // Outbound keyed by prospect natural key; replies keyed by recipient id. Cleared when the await ends.
    @State private var outboundSending: [String: Date] = [:]
    @State private var replySending: [String: Date] = [:]

    // #236: a lead opened from an OmniFocus deep link. When it changes, the queue switches to the
    // pipeline holding it, clears filters that would hide it, scrolls to it, and briefly highlights it.
    @Binding var deepLinkedKey: String?
    @State private var highlightedKey: String?

    // #308: the new leads from a tapped multi-lead away alert. When it changes, the queue enters a
    // focused mode showing exactly those leads (a flat list, ignoring the pipeline split and filters so
    // even a booked lead that falls out of both pipelines still appears), with a "Show all" exit.
    @Binding var deepLinkedKeys: [String]?
    @State private var focusedKeys: [String]?
    // #338: the heading focusedSection shows while focused. nil falls back to the #308
    // away-leads phrasing; a stage-pill tap sets an explicit one instead.
    @State private var focusedHeading: String?

    // #488: lets the Reconnect Gmail alert start the same OAuth flow the onboarding screen uses,
    // instead of just telling Dan to go find the button himself.
    var onConnectGmail: () -> Void = {}
    // #338: the Follow-ups pill reuses the existing FollowUpsView sheet (owned by RootView)
    // instead of a second filtered-list implementation of the same thing.
    var onShowFollowUps: () -> Void = {}

    private var items: [QueueItem] { prospects.map(QueueItem.init) }

    // #217: split the queue into people still to email and people already reached out to.
    enum Pipeline: String, CaseIterable {
        case toSend, reachedOut
        var label: String { self == .toSend ? "To send" : "Reached out" }
    }

    // Contacted RECIPIENTS Dan is still working, ordered by when to next reach out to that contact
    // (soonest first). Booked, lost, and finished-sequence recipients drop off (ReachedOutQueue
    // returns no next date). #652: one entry per recipient, so a multi-contact show can appear more
    // than once here, each with its own contact and its own timing.
    private var reachedOutRecipients: [(prospect: Prospect, recipient: Recipient, next: Date)] {
        ReachedOutQueue.activeWithDates(from: prospects, now: Date())
    }
    private var reachedOutKeys: Set<String> { Set(reachedOutRecipients.map(\.prospect.naturalKey)) }

    private var filtered: [QueueItem] {
        items.filter { item in
            if let d = disciplineFilter, item.discipline != d { return false }
            if highOnly, !item.isHighFit { return false }
            if showPendingBookingsOnly, !item.bookingSuggested { return false }
            return true
        }
    }

    // What the queue actually shows: the filtered set windowed to the bookable date range
    // (past hidden, beyond-horizon hidden) with too-close events demoted to the bottom,
    // computed live against today so it stays correct between scout runs.
    private var visible: [QueueItem] {
        QueueModel.toSendQueue(filtered, reachedOutKeys: reachedOutKeys, today: today)
    }

    private var disciplines: [String] {
        Array(Set(items.map(\.discipline))).sorted()
    }

    private var today: String { QueueModel.easternToday() }

    // The big scroll tree is lifted into a typed sub-view so the main body stays small and
    // the editor type-checks it quickly (#56); the real compiler was always fine.
    // Kept deliberately small: the toolbar, alerts, and their bindings are extracted so no
    // single expression sits near the SwiftUI type-checker's complexity threshold (#122).
    var body: some View {
        mainContent
            .alert("Send this email now?", isPresented: sendConfirmBinding, presenting: pendingConfirm) { pending in
                Button("Send") { performSend(pending.id) }
                Button("Cancel", role: .cancel) { pendingConfirm = nil }
            } message: { pending in
                Text(sendConfirmMessage(pending))
            }
            .alert("Reconnect Gmail", isPresented: $showReconnect) {
                Button("Connect Gmail") { onConnectGmail() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your Gmail access has expired or was revoked, so nothing was sent. Click Connect Gmail to reconnect, then try Send again.")
            }
    }

    private var mainContent: some View {
        queueScroll
            .background(OVColor.canvas)
            .toolbar { bookingsToolbar }
    }

    @ToolbarContentBuilder
    private var bookingsToolbar: some ToolbarContent {
        let pendingBookings = QueueModel.pendingBookingCount(items)
        if pendingBookings > 0 {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showPendingBookingsOnly.toggle()
                } label: {
                    // Active state (#118): filled seal + forest tint when the filter is engaged,
                    // mirroring the high-fit chip's active treatment, so it's clear why rows are
                    // hidden instead of "where did my rows go?".
                    Label("Confirm bookings (\(pendingBookings))",
                          systemImage: showPendingBookingsOnly ? "checkmark.seal.fill" : "checkmark.seal")
                }
                .foregroundStyle(showPendingBookingsOnly ? OVColor.forest : OVColor.inkSoft)
                .help(showPendingBookingsOnly
                      ? "Showing only the \(pendingBookings) pending booking\(pendingBookings == 1 ? "" : "s"). Click to show the whole queue again."
                      : "Show only prospects where Downbeat detected a booking, to confirm or dismiss each one")
            }
        }
    }

    private var sendConfirmBinding: Binding<Bool> {
        Binding(get: { pendingConfirm != nil }, set: { if !$0 { pendingConfirm = nil } })
    }

    private func sendConfirmMessage(_ pending: PendingSend) -> String {
        "To: \(pending.confirmation.recipient)\nSubject: \(pending.confirmation.subject)\n\nThis sends one email right now, to this recipient only. Nothing else goes out."
    }

    private var queueScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: OVSpacing.xl) {
                    masthead
                    // #308: a tapped multi-lead away alert focuses the queue on exactly those leads;
                    // otherwise the normal pipeline view shows.
                    if let focused = focusedKeys {
                        focusedSection(focused)
                    } else {
                        pipelineContent
                    }
                }
                .padding(.horizontal, OVSpacing.xl)
                .padding(.vertical, OVSpacing.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: deepLinkedKey) { _, key in
                if let key { navigateToLead(key, proxy: proxy) }
            }
            .onChange(of: deepLinkedKeys) { _, keys in
                if let keys, !keys.isEmpty { focusOnLeads(keys, proxy: proxy) }
            }
        }
    }

    // The normal queue: pipeline picker plus the to-send date groups or the reached-out list. Lifted
    // out of queueScroll so the focused/normal branch stays a small expression (#122).
    @ViewBuilder private var pipelineContent: some View {
        Picker("Pipeline", selection: $pipeline) {
            ForEach(Pipeline.allCases, id: \.self) { p in
                Text(p == .toSend ? "To send (\(visible.count))"
                                  : "Reached out (\(reachedOutRecipients.count))").tag(p)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if pipeline == .toSend {
            QueueFilterBar(
                disciplines: disciplines,
                activeDiscipline: $disciplineFilter,
                highOnly: $highOnly
            )
            let groups = QueueModel.groupByDate(visible)
            if groups.isEmpty {
                emptyState
            } else {
                ForEach(groups) { group in
                    dateSection(group)
                }
            }
        } else {
            reachedOutList
        }
    }

    // #308: the focused new-leads view a tapped multi-lead away alert lands on, exactly the leads named
    // in the alert, as a flat list (booked leads that drop out of both pipelines still appear because it
    // filters all non-dismissed prospects, not the windowed queue). "Show all" returns to the queue.
    @ViewBuilder private func focusedSection(_ keys: [String]) -> some View {
        let wanted = Set(keys)
        let rows = items.filter { wanted.contains($0.id) }
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(focusedHeading ?? "\(rows.count) new lead\(rows.count == 1 ? "" : "s") while you were away")
                    .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Spacer()
                Button("Show all") { focusedKeys = nil; focusedHeading = nil }
            }
            .padding(.bottom, OVSpacing.xxs)
            .overlay(alignment: .bottom) { Rectangle().fill(OVColor.line).frame(height: 1) }
            if rows.isEmpty {
                Text("These leads are no longer in your queue.")
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft)
            } else {
                ForEach(rows) { item in prospectRow(item) }
            }
        }
    }

    // #308: enter the focused new-leads view and scroll its first (still-visible) lead into view.
    // Clears the request once handled, mirroring navigateToLead (#236). #674: a lead dismissed
    // between the notification firing and Dan tapping it is no longer in `items` at all, so this
    // scrolls to the first key that's actually there instead of blindly the first key named in the
    // (possibly stale) notification.
    private func focusOnLeads(_ keys: [String], proxy: ScrollViewProxy) {
        focusedKeys = keys
        deepLinkedKeys = nil
        let target = QueueModel.firstVisibleKey(keys, among: items)
        DispatchQueue.main.async {
            if let target { withAnimation { proxy.scrollTo(target, anchor: .top) } }
        }
    }

    // #338: tapping a stage pill (Prep/Review/Send) focuses the queue on exactly the prospects in
    // that stage, reusing the same #308 focused-list view instead of a second filtering mechanism.
    private func focusOnStage(_ status: AgentStatus) {
        focusedHeading = "\(status.name): \(status.detail)"
        focusedKeys = StageNavigation.naturalKeys(forStage: status.name, in: prospects)
    }

    // #236: land on a deep-linked lead: switch to the pipeline holding it, clear filters that would
    // hide it, scroll it into view, and briefly highlight it. Clears the request once handled.
    private func navigateToLead(_ key: String, proxy: ScrollViewProxy) {
        focusedKeys = nil   // #308: leave any focused new-leads view so the row is reachable in the queue
        pipeline = reachedOutKeys.contains(key) ? .reachedOut : .toSend
        disciplineFilter = nil
        highOnly = false
        showPendingBookingsOnly = false
        highlightedKey = key
        deepLinkedKey = nil
        // Let the pipeline/filter change lay out before scrolling to the row.
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(key, anchor: .center) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if highlightedKey == key { highlightedKey = nil }
        }
    }


    private var masthead: some View {
        let summary = QueueModel.summary(visible)
        let priority = QueuePriorityBreakdown.summarize(visible)
        let pendingBookings = QueueModel.pendingBookingCount(items)
        return VStack(alignment: .leading, spacing: OVSpacing.sm) {
            HStack(spacing: OVSpacing.xs) {
                Text("Overture").font(OVType.wordmark).foregroundStyle(OVColor.forest)
                #if DEBUG
                // #377: a live app and a Debug build can be open side by side showing different
                // data, so the masthead must make it unmistakable which window this is.
                Text("Debug")
                    .font(OVType.tag)
                    .foregroundStyle(OVColor.gold)
                    .padding(.horizontal, OVSpacing.sm).padding(.vertical, 2)
                    .background(Capsule().fill(OVColor.gold.opacity(0.15)))
                #endif
            }
            Rectangle().fill(OVColor.gold.opacity(0.5)).frame(height: 1).frame(maxWidth: .infinity)
            HStack(spacing: OVSpacing.xs) {
                Text("\(summary.total)").fontWeight(.semibold).foregroundStyle(OVColor.ink)
                Text("in the queue").foregroundStyle(OVColor.inkFaint)
                Text("/").foregroundStyle(OVColor.lineStrong)
                Text("\(summary.high)").fontWeight(.semibold).foregroundStyle(OVColor.gold)
                Text("high-fit").foregroundStyle(OVColor.inkFaint)
                if pendingBookings > 0 {
                    Text("/").foregroundStyle(OVColor.lineStrong)
                    Text("\(pendingBookings)").fontWeight(.semibold).foregroundStyle(OVColor.forest)
                    Text("to confirm").foregroundStyle(OVColor.inkFaint)
                }
            }
            .font(.system(size: 12))
            // #92: shows whether high-fit is mostly warm orgs (relationship) or genuinely strong
            // cold events (merit), so an over-filled high tier is visible before recalibrating.
            // #335: phrased as "Of the N high-fit: ..." so it reads as a breakdown, not a new total.
            if let breakdown = priority.highFitBreakdownLabel() {
                Text(breakdown)
                    .font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
            }
            HStack(spacing: OVSpacing.xs) {
                Text(ScoutStatus(lastScoutedAt: ScoutService.lastScoutedAt()).summary(now: Date()))
                Text("·").foregroundStyle(OVColor.lineStrong)
                Text(prepStatus.summary(now: Date()))
            }
            .font(.system(size: 11))
            .foregroundStyle(OVColor.inkFaint)
            agentStrip
        }
    }

    // Per-stage "where am I needed" indicators (#15): each stage shows a coloured dot plus
    // a label (never colour alone), with a roll-up so needs-attention is unmissable.
    private var agentInputs: AgentInputs {
        AgentInputs(
            // #338: the SAME criteria StageNavigation uses to pick which prospects a pill's tap
            // focuses on, so the count shown always matches what tapping it navigates to.
            keptToPrep: StageNavigation.naturalKeys(forStage: "Prep", in: prospects).count,
            prepRunning: PrepQueueService.isRunning(now: Date()),
            toReview: StageNavigation.naturalKeys(forStage: "Review", in: prospects).count,
            readyToSend: StageNavigation.naturalKeys(forStage: "Send", in: prospects).count,
            gmailConnected: GmailAuthManager.shared.isConnected,
            sendErrors: prospects.filter { $0.sendError != nil }.count,
            followUpsDue: FollowUp.dueRecipients(from: prospects, now: Date()).count,
            stalledReplyDrafts: prospects.reduce(0) { sum, p in
                let runAlive = ReplyClassifyService.isRunning(now: Date())
                return sum + p.recipients.filter { $0.isReplyDraftStalled(now: Date(), runAlive: runAlive) }.count
            },
            stuckSends: prospects.reduce(0) { sum, p in
                sum + p.recipients.filter { $0.isSendStuck(now: Date()) }.count
            },
            degradedReplyTracking: prospects.reduce(0) { sum, p in
                sum + p.recipients.filter(\.replyTrackingDegraded).count
            }
        )
    }

    private var agentStrip: some View {
        let statuses = AgentRoster.statuses(agentInputs)
        let needs = AgentRoster.needsYouCount(statuses)
        return VStack(alignment: .leading, spacing: OVSpacing.xs) {
            if needs > 0 {
                Text("\(needs) need\(needs == 1 ? "s" : "") you")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(OVColor.rust)
            }
            WrapHStack(spacing: OVSpacing.xs, lineSpacing: OVSpacing.xs) {
                ForEach(statuses) { agentChip($0) }
            }
        }
        .padding(.top, OVSpacing.xxs)
    }

    // #338: real navigation, not just a status indicator. Follow-ups reuses the existing
    // FollowUpsView sheet; Prep/Review/Send focus the queue on that stage's prospects.
    private func agentChip(_ s: AgentStatus) -> some View {
        Button {
            if s.name == "Follow-ups" {
                onShowFollowUps()
            } else {
                focusOnStage(s)
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(agentColor(s.state)).frame(width: 6, height: 6)
                Text(s.name).font(OVType.tag)
                    .foregroundStyle(s.state == .idle ? OVColor.inkFaint : OVColor.ink)
                if s.state != .idle {
                    Text(s.detail).font(OVType.tag).foregroundStyle(OVColor.inkSoft)
                }
            }
            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 5)
            .background(Capsule().fill(s.state == .idle ? Color.clear : agentColor(s.state).opacity(0.12)))
            .overlay(Capsule().strokeBorder(OVColor.line, lineWidth: s.state == .idle ? 1 : 0))
        }
        .buttonStyle(.plain)
        .help(s.detail)
    }

    private func agentColor(_ state: AgentState) -> Color {
        switch state {
        case .idle: return OVColor.inkFaint
        case .working: return OVColor.forest
        case .needsAttention: return OVColor.gold
        case .error: return OVColor.rust
        }
    }

    private var prepStatus: PrepStatus {
        PrepStatus.from(prospects: prospects,
                        lastRunStartedAt: PrepQueueService.lastRunStartedAt,
                        running: PrepQueueService.isRunning(now: Date()))
    }

    private func dateSection(_ group: QueueModel.DateGroup) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: OVSpacing.sm) {
                if !group.weekday.isEmpty {
                    Text(group.weekday.uppercased()).font(.system(size: 11, weight: .semibold))
                        .tracking(1.4).foregroundStyle(OVColor.inkFaint)
                }
                Text(group.monthDay).font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                if !group.year.isEmpty {
                    Text(group.year).font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
                }
            }
            .padding(.bottom, OVSpacing.xxs)
            .overlay(alignment: .bottom) { Rectangle().fill(OVColor.line).frame(height: 1) }

            ForEach(group.items) { item in prospectRow(item) }
        }
    }

    // #217/#652: contacts Dan has already pitched, ordered by when to next reach out to each one
    // (soonest first). A flat list rather than date groups, since the next-reach-out order is what
    // matters here. One row per RECIPIENT: a multi-contact show with two contacts due at different
    // times appears twice, each labeled with that contact's own timing. #661: a lightweight row
    // (group name, this one contact, timing, and the state control), not the entire show card, so
    // two contacts due on the same show don't render as two large, nearly-identical cards.
    @ViewBuilder private var reachedOutList: some View {
        let dated = reachedOutRecipients
        if dated.isEmpty {
            VStack(spacing: OVSpacing.xs) {
                Text("No one to follow up with").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Text("Once you have sent a pitch, the people you are waiting to hear back from show up here, soonest follow-up first. They drop off when you book them, mark them lost, or the follow-ups run out.")
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, OVSpacing.hero)
            .padding(.horizontal, OVSpacing.xl)
        } else {
            let now = Date()
            VStack(alignment: .leading, spacing: OVSpacing.sm) {
                ForEach(dated, id: \.recipient.id) { pair in
                    reachedOutRow(pair, now: now)
                    Divider()
                }
            }
        }
    }

    // #661: group name, this one contact, timing, and the conversation-state control (the shared
    // ConversationStateControl, #652/#661), plus a link to Follow-ups once it's actually due, since
    // that screen already owns the real nudge/reply-sending flow rather than a second copy of it here.
    private func reachedOutRow(_ pair: (prospect: Prospect, recipient: Recipient, next: Date), now: Date) -> some View {
        let p = pair.prospect, r = pair.recipient
        return HStack(alignment: .top, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
                Text(r.email ?? r.name ?? "no contact").font(OVType.body).foregroundStyle(OVColor.inkSoft)
                if let line = SendFailureLine.text(for: r.sendError) {
                    Text(line).font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(2)
                }
            }
            Spacer(minLength: OVSpacing.sm)
            VStack(alignment: .trailing, spacing: 6) {
                Text(ReachedOutQueue.timingLabel(next: pair.next, now: now))
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                if r.replied {
                    ConversationStateControl(
                        currentState: r.conversationState, stateSource: r.conversationStateSource,
                        onSet: { state in
                            ProspectMutations.setRecipientConversationState(QueueItem(p), r.id, state,
                                                                            prospects: prospects, context: context, feedback: feedback)
                        },
                        onConfirm: {
                            ProspectMutations.confirmRecipientConversationState(QueueItem(p), r.id,
                                                                                prospects: prospects, context: context, feedback: feedback)
                        })
                }
                if ReachedOutQueue.isDueNow(next: pair.next, now: now) {
                    Button("Send a follow-up") { onShowFollowUps() }
                        .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forest)
                }
            }
        }
        .padding(.vertical, OVSpacing.xs)
    }

    private func prospectRow(_ item: QueueItem) -> some View {
        ProspectRowFactory.row(item, today: today, prospects: prospects, context: context, feedback: feedback,
                              highlightedKey: highlightedKey, outboundSendSince: outboundSending[item.id],
                              replySendSince: { rid in replySending[rid] },
                              onSend: { requestSend(item) }, onSendReply: { rid in sendReply(item, rid) })
    }

    private var emptyState: some View {
        VStack(spacing: OVSpacing.xs) {
            Text(items.isEmpty ? "Nothing scouted yet" : "Nothing matches this filter")
                .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            Text(items.isEmpty
                 ? "Run the scout to comb the venue calendars. Ranked candidates land here for review."
                 : "Try a different discipline, or clear the high-fit filter.")
                .font(OVType.body).foregroundStyle(OVColor.inkSoft).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, OVSpacing.hero)
        .padding(.horizontal, OVSpacing.xl)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(OVColor.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }

    // Step 1 of an explicit send: show Dan exactly what will go out and wait for his confirm (#49).
    private func requestSend(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let confirmation = SendConfirmation(prospect: model) else { return }
        pendingConfirm = PendingSend(id: item.id, confirmation: confirmation)
    }

    private func performSend(_ naturalKey: String) {
        pendingConfirm = nil
        ProspectMutations.performSend(naturalKey, prospects: prospects, context: context, feedback: feedback,
                                      markSending: { outboundSending[$0] = Date() },
                                      clearSending: { outboundSending[$0] = nil },
                                      onNeedsReconnect: { showReconnect = true })
    }

    private func sendReply(_ item: QueueItem, _ recipientId: String) {
        ProspectMutations.sendReply(item, recipientId, prospects: prospects, context: context, feedback: feedback,
                                    markSending: { replySending[$0] = Date() },
                                    clearSending: { replySending[$0] = nil },
                                    onNeedsReconnect: { showReconnect = true })
    }
}

private struct QueueFilterBar: View {
    let disciplines: [String]
    @Binding var activeDiscipline: String?
    @Binding var highOnly: Bool

    var body: some View {
        WrapHStack(spacing: OVSpacing.xs, lineSpacing: OVSpacing.xs) {
            chip("All disciplines", active: activeDiscipline == nil) { activeDiscipline = nil }
            ForEach(disciplines, id: \.self) { d in
                chip(QueueModel.disciplineLabel(d), active: activeDiscipline == d) {
                    activeDiscipline = activeDiscipline == d ? nil : d
                }
            }
            Button { highOnly.toggle() } label: {
                HStack(spacing: 5) {
                    Circle().fill(highOnly ? OVColor.gold : OVColor.inkFaint).frame(width: 6, height: 6)
                    Text("High-fit only").font(OVType.tag)
                }
                .foregroundStyle(highOnly ? OVColor.gold : OVColor.inkSoft)
                .padding(.horizontal, OVSpacing.sm).padding(.vertical, 6)
                .background(Capsule().fill(highOnly ? OVColor.gold.opacity(0.15) : .clear))
            }
            .buttonStyle(.plain)
        }
    }

    private func chip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(OVType.tag)
                .foregroundStyle(active ? OVColor.onForest : OVColor.inkSoft)
                .padding(.horizontal, OVSpacing.sm).padding(.vertical, 6)
                .background(Capsule().fill(active ? OVColor.forest : Color.clear))
        }
        .buttonStyle(.plain)
    }
}
