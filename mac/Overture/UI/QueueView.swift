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
    @State private var pendingConfirm: PendingConfirm?
    @State private var showReconnect = false

    // #236: a lead opened from an OmniFocus deep link. When it changes, the queue switches to the
    // pipeline holding it, clears filters that would hide it, scrolls to it, and briefly highlights it.
    @Binding var deepLinkedKey: String?
    @State private var highlightedKey: String?

    // #308: the new leads from a tapped multi-lead away alert. When it changes, the queue enters a
    // focused mode showing exactly those leads (a flat list, ignoring the pipeline split and filters so
    // even a booked lead that falls out of both pipelines still appears), with a "Show all" exit.
    @Binding var deepLinkedKeys: [String]?
    @State private var focusedKeys: [String]?

    // The one email awaiting Dan's explicit confirm before it sends (#49).
    private struct PendingConfirm: Identifiable {
        let id: String   // prospect naturalKey
        let confirmation: SendConfirmation
    }

    private var items: [QueueItem] { prospects.map(QueueItem.init) }

    // #217: split the queue into people still to email and people already reached out to.
    enum Pipeline: String, CaseIterable {
        case toSend, reachedOut
        var label: String { self == .toSend ? "To send" : "Reached out" }
    }

    // Contacted prospects Dan is still working, ordered by when to next reach out (soonest first).
    // Booked, lost, and finished-sequence leads drop off (ReachedOutQueue returns no next date).
    private var reachedOutItems: [QueueItem] {
        ReachedOutQueue.active(from: prospects, now: Date()).map(QueueItem.init)
    }
    private var reachedOutKeys: Set<String> { Set(reachedOutItems.map(\.id)) }

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

    private func sendConfirmMessage(_ pending: PendingConfirm) -> String {
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
                                  : "Reached out (\(reachedOutItems.count))").tag(p)
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

    // #308: the focused new-leads view a tapped multi-lead away alert lands on — exactly the leads named
    // in the alert, as a flat list (booked leads that drop out of both pipelines still appear because it
    // filters all non-dismissed prospects, not the windowed queue). "Show all" returns to the queue.
    @ViewBuilder private func focusedSection(_ keys: [String]) -> some View {
        let wanted = Set(keys)
        let rows = items.filter { wanted.contains($0.id) }
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(rows.count) new lead\(rows.count == 1 ? "" : "s") while you were away")
                    .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Spacer()
                Button("Show all") { focusedKeys = nil }
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

    // #308: enter the focused new-leads view and scroll its first lead into view. Clears the request
    // once handled, mirroring navigateToLead (#236).
    private func focusOnLeads(_ keys: [String], proxy: ScrollViewProxy) {
        focusedKeys = keys
        deepLinkedKeys = nil
        DispatchQueue.main.async {
            if let first = keys.first { withAnimation { proxy.scrollTo(first, anchor: .top) } }
        }
    }

    // #236: land on a deep-linked lead — switch to the pipeline holding it, clear filters that would
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
            Text("Overture").font(OVType.wordmark).foregroundStyle(OVColor.forest)
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

    // #217: people Dan has already pitched, ordered by when to next reach out (soonest first).
    // A flat list rather than date groups, since the next-reach-out order is what matters here.
    @ViewBuilder private var reachedOutList: some View {
        let rows = reachedOutItems
        if rows.isEmpty {
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
            let dated = ReachedOutQueue.activeWithDates(from: prospects, now: now)
            let labels = Dictionary(dated.map { ($0.prospect.naturalKey, ReachedOutQueue.timingLabel(next: $0.next, now: now)) },
                                    uniquingKeysWith: { a, _ in a })
            VStack(alignment: .leading, spacing: OVSpacing.sm) {
                ForEach(rows) { item in prospectRow(item, reachOutLabel: labels[item.id]) }
            }
        }
    }

    private func prospectRow(_ item: QueueItem, reachOutLabel: String? = nil) -> some View {
        let model = prospects.first(where: { $0.naturalKey == item.id })
        let row = ProspectRowView(
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
            onSetConversationState: { state in setConversationState(item, state) },
            onConfirmConversationState: { confirmConversationState(item) },
            onDismissReply: { dismissReply(item) },
            onMarkContact: { rid, resolution, bounced in markContact(item, rid, resolution, bounced) },
            onDismissContactReply: { rid in dismissContactReply(item, rid) },
            onDraftReply: { rid in draftReply(item, rid) },
            onSendReply: { rid in sendReply(item, rid) },
            onCopyReply: { rid in copyReply(item, rid) },
            onMarkConfidenceReviewed: { markConfidenceReviewed(item) },
            onCorrectClassification: { d, p in correctClassification(item, discipline: d, production: p) },
            onConfirmBooking: { confirmBooking(item) },
            onDismissBookingSuggestion: { dismissBookingSuggestion(item) },
            onRejectBooking: { rejectBooking(item) },
            gmailConnected: GmailAuthManager.shared.isConnected,
            reachOutLabel: reachOutLabel
        )
        // #236: tag each row with its key so a deep link can scroll to it, and highlight the target.
        let highlighted = highlightedKey == item.id
        let framed = row
            .padding(highlighted ? OVSpacing.sm : 0)
            .background(highlighted ? OVColor.gold.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .id(item.id)
        // #244: a sent draft Dan hand-edited is a voice-learning candidate. Let him opt a poor
        // example out (or back in) from a right-click, so the loop never learns from a rushed send.
        if let model, model.sentAt != nil, model.originalDraftBody != nil {
            return AnyView(framed.contextMenu {
                Button(model.excludedFromVoiceLearning ? "Learn from this email again"
                                                       : "Don't learn from this email") {
                    toggleVoiceLearning(item)
                }
            })
        }
        return AnyView(framed)
    }

    // #244: flip whether this prospect's edited-and-sent draft feeds the voice-learning loop.
    private func toggleVoiceLearning(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.excludedFromVoiceLearning.toggle()
        try? context.save()
        // #285: a context-menu toggle changes nothing visible on the row, so say it ran.
        feedback.acknowledge(ActionAck.voiceLearning(excluded: model.excludedFromVoiceLearning,
                                                     org: item.groupName))
    }

    // Dan marked an auto-detected Gmail reply as not real (#219): revert it and remember that reply
    // so it does not re-flag, while a genuinely new reply still will.
    private func dismissReply(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.dismissAutoReply(now: Date())
        try? context.save()
    }

    // #418 B2 — Dan hand-marks one contact's outcome from the conversation surface (attribution only
    // for Booked; never sets the lead booking). Stamps the manual source so detection won't overwrite.
    private func markContact(_ item: QueueItem, _ recipientId: String,
                             _ resolution: RecipientResolution?, _ bounced: Bool) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.markOutcomeManually(resolution: resolution, bounced: bounced) }
        try? context.save()
    }

    // #418 B1 — dismiss a wrongly auto-detected reply for ONE contact (#219, per-recipient).
    private func dismissContactReply(_ item: QueueItem, _ recipientId: String) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.dismissAutoReply() }
        try? context.save()
    }

    // #420 C6 — request an AI-drafted reply for ONE contact: stamp the request (drives the progress +
    // needs-attention timeout) and launch the detached classify+drafter run. Request-response feel.
    private func draftReply(_ item: QueueItem, _ recipientId: String) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.replyDraftRequestedAt = Date() }
        try? context.save()
        _ = try? ReplyClassifyService.startClassify(from: context, now: Date())
    }

    // #421 — send Dan's approved AI reply on the contact's own thread, off the main thread (same
    // non-blocking pattern as performSend); surface a reconnect prompt if the token was revoked.
    private func sendReply(_ item: QueueItem, _ recipientId: String) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let recipient = model.recipients.first(where: { $0.id == recipientId }) else { return }
        let sender = GmailSender(fromEmail: "dan@danwrightphotography.com")
        Task {
            let sent = await SendService.sendReplyDraft(recipient, of: model, now: Date(), sender: sender)
            try? context.save()
            if !sent && !GmailAuthManager.shared.isConnected { showReconnect = true }
        }
    }

    // #421 copy-out — copy the draft to the clipboard for Dan to paste into the Gmail thread he's
    // reading, and mark the contact replied-in-Gmail (consumes the draft, re-anchors the clock).
    private func copyReply(_ item: QueueItem, _ recipientId: String) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let recipient = model.recipients.first(where: { $0.id == recipientId }),
              let body = recipient.replyDraftBody, !body.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        model.updateRecipient(id: recipientId) { $0.recordRepliedInGmail(now: Date()) }
        try? context.save()
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
        model.applyEdit(subject: subject, body: body)
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

    private func setConversationState(_ item: QueueItem, _ state: ConversationState) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.setConversationState(state, now: Date())
        try? context.save()
    }

    private func confirmConversationState(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.confirmConversationState(now: Date())
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

    // Dan rejected a wrong auto-detected booking (#203): revert it to no-response and remember the
    // booking id so reconcileBooked never re-books from that exact match.
    private func rejectBooking(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.rejectAutoBooking(bookingId: model.autoBookedFromBookingId, now: Date())
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
