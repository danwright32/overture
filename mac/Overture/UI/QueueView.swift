import SwiftUI
import SwiftData

// The window Dan lives in: ranked performances, grouped by date, kept or dismissed.
struct QueueView: View {
    @Environment(\.modelContext) private var context

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
    @State private var pendingConfirm: PendingConfirm?
    @State private var showReconnect = false

    // The one email awaiting Dan's explicit confirm before it sends (#49).
    private struct PendingConfirm: Identifiable {
        let id: String   // prospect naturalKey
        let confirmation: SendConfirmation
    }

    private var items: [QueueItem] { prospects.map(QueueItem.init) }

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
    private var visible: [QueueItem] { QueueModel.queueOrder(filtered, today: today) }

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
                Button("OK", role: .cancel) {}
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
                    Label("Confirm bookings (\(pendingBookings))", systemImage: "checkmark.seal")
                }
                .help("Prospects where Downbeat detected a booking — confirm or dismiss each one")
            }
        }
    }

    private var sendConfirmBinding: Binding<Bool> {
        Binding(get: { pendingConfirm != nil }, set: { if !$0 { pendingConfirm = nil } })
    }

    private func sendConfirmMessage(_ pending: PendingConfirm) -> String {
        "To: \(pending.confirmation.recipient)\nSubject: \(pending.confirmation.subject)\n\nThis sends one email right now, to this recipient only. Nothing else goes out."
    }

    private var queueScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OVSpacing.xl) {
                masthead
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
            }
            .padding(.horizontal, OVSpacing.xl)
            .padding(.vertical, OVSpacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }


    private var masthead: some View {
        let summary = QueueModel.summary(visible)
        let priority = QueuePriorityBreakdown.summarize(visible)
        let pendingBookings = QueueModel.pendingBookingCount(items)
        return VStack(alignment: .leading, spacing: OVSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: OVSpacing.xs) {
                Text("Overture").font(OVType.wordmark).foregroundStyle(OVColor.forest)
                Circle().fill(OVColor.gold).frame(width: 7, height: 7)
            }
            Rectangle().fill(OVColor.gold.opacity(0.5)).frame(height: 1).frame(maxWidth: .infinity)
            Text("Performances worth pitching, ranked by fit. Keep the ones worth pursuing and dismiss the rest.")
                .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
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
            if priority.high > 0 {
                Text("\(priority.relationshipDriven) from a prior relationship · \(priority.meritDriven) on event merit")
                    .font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
            }
            HStack(spacing: OVSpacing.xs) {
                Text(prepStatus.summary(now: Date()))
                Text("·").foregroundStyle(OVColor.lineStrong)
                Text(ScoutStatus(lastScoutedAt: ScoutService.lastScoutedAt()).summary(now: Date()))
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
            keptToPrep: prospects.filter { $0.status == .queued && !$0.hasDraft }.count,
            prepRunning: PrepQueueService.isRunning(now: Date()),
            toReview: prospects.filter { $0.status == .drafted }.count,
            readyToSend: prospects.filter { $0.status == .approved && $0.sentAt == nil }.count,
            gmailConnected: GmailAuthManager.shared.isConnected,
            sendErrors: prospects.filter { $0.sendError != nil }.count,
            followUpsDue: FollowUp.due(from: prospects, now: Date()).count
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

    private func agentChip(_ s: AgentStatus) -> some View {
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
        PrepStatus(
            kept: prospects.filter { $0.status == .queued && !$0.hasDraft }.count,
            drafted: prospects.filter { $0.status == .drafted }.count,
            approved: prospects.filter { $0.status == .approved }.count,
            lastRunStartedAt: PrepQueueService.lastRunStartedAt,
            running: PrepQueueService.isRunning(now: Date())
        )
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

            ForEach(group.items) { item in
                ProspectRowView(
                    item: item,
                    today: today,
                    onKeep: { setStatus(item, .queued, nil) },
                    onDismiss: { reason in setStatus(item, .dismissed, reason) },
                    onApprove: { setStatus(item, .approved, nil) },
                    onUnapprove: { setStatus(item, .drafted, nil) },
                    onSkipDraft: { setStatus(item, .dismissed, .notInterested) },
                    onSaveDraft: { subject, body in saveDraft(item, subject, body) },
                    onSetOutcome: { outcome in setOutcome(item, outcome) },
                    onSetLostReason: { reason in setLostReason(item, reason) },
                    onSend: { requestSend(item) },
                    onMarkConfidenceReviewed: { markConfidenceReviewed(item) },
                    onCorrectClassification: { d, p in correctClassification(item, discipline: d, production: p) },
                    onConfirmBooking: { confirmBooking(item) },
                    onDismissBookingSuggestion: { dismissBookingSuggestion(item) },
                    gmailConnected: GmailAuthManager.shared.isConnected
                )
            }
        }
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

    private func setStatus(_ item: QueueItem, _ status: ReviewStatus, _ reason: DismissReason?) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.status = status
        model.dismissReasonRaw = reason?.rawValue
        try? context.save()
    }

    private func saveDraft(_ item: QueueItem, _ subject: String, _ body: String) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.draftSubject = subject
        model.draftBody = body
        model.draftEditedByDan = true
        try? context.save()
    }

    // Dan eyeballed a rules-uncertain classification and it's fine: clear the flag so it
    // stays cleared even across re-scouts (#32). Scout-owned confidence is untouched.
    private func markConfidenceReviewed(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.confidenceReviewedByDan = true
        try? context.save()
    }

    // Dan corrected a wrong classification. Calls ClassificationOverride.correct which
    // re-scores the prospect in place; the row's fit-reason line then hides (#60).
    private func correctClassification(_ item: QueueItem, discipline: Discipline?, production: Production?) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        ClassificationOverride.correct(model, discipline: discipline, production: production, now: Date())
        try? context.save()
    }

    private func setOutcome(_ item: QueueItem, _ outcome: Outcome) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.outcome = outcome
        model.outcomeSourceRaw = OutcomeSource.manual.rawValue
        model.outcomeAt = Date()
        model.bookingSuggested = false
        try? context.save()
    }

    private func confirmBooking(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.outcome = .booked
        model.outcomeSourceRaw = OutcomeSource.manual.rawValue
        model.outcomeAt = Date()
        model.bookingSuggested = false
        try? context.save()
    }

    private func dismissBookingSuggestion(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.bookingSuggested = false
        model.bookingSuggestionDismissed = true
        try? context.save()
    }

    private func setLostReason(_ item: QueueItem, _ reason: String) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.lostReason = QueueModel.normalizedLostReason(reason)
        try? context.save()
    }

    // Step 1 of an explicit send: show Dan exactly what will go out and wait for his
    // confirm (#49). Building the confirmation also re-checks sendability, so the dialog
    // only appears for an email that would actually send.
    private func requestSend(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let confirmation = SendConfirmation(prospect: model) else { return }
        pendingConfirm = PendingConfirm(id: item.id, confirmation: confirmation)
    }

    // Step 2: Dan confirmed. Send this one approved email via Gmail. One confirm,
    // one email. Never autonomous.
    private func performSend(_ naturalKey: String) {
        pendingConfirm = nil
        guard let model = prospects.first(where: { $0.naturalKey == naturalKey }) else { return }
        let sender = GmailSender(fromEmail: "dan@danwrightphotography.com")
        // Await the send off the synchronous button action so the main thread is never
        // blocked waiting on the Gmail token work (the old blocking bridge deadlocked here).
        Task {
            let sent = await SendService.sendOne(model, now: Date(), sender: sender)
            try? context.save()
            // If the send failed because the token was revoked/expired, sendOne cleared it;
            // surface a clear reconnect prompt rather than a silent per-row error (#50).
            if !sent && !GmailAuthManager.shared.isConnected {
                showReconnect = true
            }
        }
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
