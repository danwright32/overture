import SwiftUI
import SwiftData

// Everything due for a touch, in one place (#45, #111): silent leads that need a gentle nudge, and
// ACTIVE conversations that need a re-touch, a reply, or a gracious closing note. Each is sent only
// on Dan's explicit confirm, nothing autonomous; the silent sequence stops the moment someone
// replies, and a conversation reminder steps forward when Dan acts on it or resolves when booked/lost.
struct FollowUpsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ActionFeedback.self) private var feedback   // #285
    @Query private var prospects: [Prospect]
    @State private var pending: PendingNudge?
    @State private var pendingConversation: PendingConversation?
    @State private var showSettings = false

    // The persisted reminder cadence (#178), tunable from the settings popover below. @AppStorage on
    // the same keys ConversationReminderConfig reads, so the loaded config and the steppers stay in
    // step. Defaults to the baked values, so timing is unchanged until Dan edits.
    @AppStorage(ConversationReminderConfig.Keys.wantsToBook)
    private var wantsToBookDays = ConversationReminderConfig().wantsToBookDays
    @AppStorage(ConversationReminderConfig.Keys.hasQuestion)
    private var hasQuestionDays = ConversationReminderConfig().hasQuestionDays
    @AppStorage(ConversationReminderConfig.Keys.interested)
    private var interestedDays = ConversationReminderConfig().interestedDays
    @AppStorage(ConversationReminderConfig.Keys.leadBuffer)
    private var leadBufferDays = ConversationReminderConfig().leadBufferDays

    private var reminderConfig: ConversationReminderConfig {
        ConversationReminderConfig(interestedDays: interestedDays, wantsToBookDays: wantsToBookDays,
                                   hasQuestionDays: hasQuestionDays, leadBufferDays: leadBufferDays)
    }

    private struct PendingNudge: Identifiable {
        let id: String        // prospect naturalKey
        let recipientId: String   // which contact on the show (#418 D)
        let recipient: String
        let preview: String
    }

    private struct PendingConversation: Identifiable {
        let id: String        // prospect naturalKey
        let recipient: String
        let preview: String
        let isClosing: Bool
    }

    private var due: [FollowUp.DueRecipient] {
        FollowUp.dueRecipients(from: prospects, now: Date())
            .sorted { ($0.recipient.sentAt ?? .distantPast) < ($1.recipient.sentAt ?? .distantPast) }
    }

    // Already ordered by urgency then soonest event in ConversationReminder.due (domain-owned).
    private var conversationDue: [(Prospect, ConversationReminder.DueReminder)] {
        ConversationReminder.due(from: prospects, now: Date(), config: reminderConfig)
    }

    private var gmailConnected: Bool { GmailAuthManager.shared.isConnected }
    private var isEmpty: Bool { due.isEmpty && conversationDue.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Due").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Text("\(due.count + conversationDue.count)").font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
                    .help("Adjust reminder timing")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { ReminderSettingsView() }
                Button("Done") { dismiss() }
            }
            .padding(OVSpacing.lg)
            Divider()
            if isEmpty {
                Text("Nothing to act on. Leads you've emailed show up here for a gentle follow-up, active conversations for a re-touch, and they drop off the moment they reply, book, or you close them out.")
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(OVSpacing.xl)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: OVSpacing.lg) {
                        if !conversationDue.isEmpty {
                            section("Conversations") {
                                ForEach(conversationDue, id: \.0.naturalKey) { p, reminder in
                                    conversationRow(p, reminder); Divider()
                                }
                            }
                        }
                        if !due.isEmpty {
                            section("Silent follow-ups") {
                                ForEach(Array(due.enumerated()), id: \.offset) { _, d in row(d); Divider() }
                            }
                        }
                    }
                    .padding(OVSpacing.lg)
                }
            }
        }
        .frame(width: 500, height: 560)
        .background(OVColor.canvas)
        .alert("Send this follow-up now?",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { p in
            Button("Send") { performNudge(p.id, p.recipientId) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { p in
            Text("To: \(p.recipient)\n\n\(p.preview)\n\nThis sends one follow-up right now, to this recipient only. Nothing else goes out.")
        }
        .alert("Send this note now?",
               isPresented: Binding(get: { pendingConversation != nil }, set: { if !$0 { pendingConversation = nil } }),
               presenting: pendingConversation) { p in
            Button("Send") { performConversationNudge(p.id, isClosing: p.isClosing) }
            Button("Cancel", role: .cancel) { pendingConversation = nil }
        } message: { p in
            Text("To: \(p.recipient)\n\n\(p.preview)\n\nThis sends one message right now, to this recipient only."
                + (p.isClosing ? " It also closes the lead out (kept warm for next time)." : ""))
        }
        .actionFeedbackBanner()
    }

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            Text(title.uppercased()).font(OVType.tag).foregroundStyle(OVColor.inkFaint)
            content()
        }
    }

    // A silent follow-up to one contact (#45, per-recipient #418 D).
    private func row(_ d: FollowUp.DueRecipient) -> some View {
        let r = d.recipient
        return HStack(alignment: .top, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.prospect.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
                Text("\(r.email ?? "no contact") · nudge \(r.followUpCount + 1) of \(FollowUpConfig().maxFollowUps)")
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                if let line = SendFailureLine.text(for: r.sendError) {
                    Text(line).font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(2)
                }
            }
            Spacer(minLength: OVSpacing.sm)
            sendButton("Send nudge", enabled: gmailConnected && (r.email?.isEmpty == false)) { requestNudge(d) }
        }
        .padding(.vertical, OVSpacing.xs)
    }

    // A conversation reminder (#111): tagged by reason, with the action its kind calls for.
    private func conversationRow(_ p: Prospect, _ reminder: ConversationReminder.DueReminder) -> some View {
        HStack(alignment: .top, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
                reasonPill(reminder.reason, color: ConversationReminder.accent(for: reminder.kind).color)
                Text(p.contactEmail ?? "no contact").font(OVType.body).foregroundStyle(OVColor.inkSoft)
                sendFailureLine(p)
            }
            Spacer(minLength: OVSpacing.sm)
            VStack(alignment: .trailing, spacing: 6) {
                switch reminder.kind {
                case .active(let state):
                    sendButton("Send nudge", enabled: gmailConnected && p.contactEmail != nil) {
                        requestConversationNudge(p, kind: .active(state))
                    }
                    Button("Remind me later") { remindLater(p) }
                        .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                case .closing:
                    sendButton("Send closing note", enabled: gmailConnected && p.contactEmail != nil) {
                        requestConversationNudge(p, kind: .closing)
                    }
                case .suggested:
                    // An AI guess awaiting Dan: confirm it (onto the timed track) or correct it.
                    sendButton("Confirm", enabled: true) { confirm(p) }
                    setStateMenu(p, label: "Change")
                case .needsState:
                    setStateMenu(p, label: "Set a state")
                }
            }
        }
        .padding(.vertical, OVSpacing.xs)
    }

    // #316: the durable failure surface. A real send failure is persisted on the prospect
    // (SendService sets sendError), so it stays visible here until the next successful send clears it,
    // unlike the fading banner, which a later success can overwrite before Dan sees it.
    @ViewBuilder private func sendFailureLine(_ p: Prospect) -> some View {
        if let line = SendFailureLine.text(for: p.sendError) {
            Text(line).font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(2)
        }
    }

    private func reasonPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(OVType.tag).fontWeight(.medium).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.25)))
    }

    private func sendButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(OVType.meta).foregroundStyle(OVColor.onForest)
                .padding(.horizontal, OVSpacing.md).padding(.vertical, 6)
                .background(Capsule().fill(OVColor.forest))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(gmailConnected ? "Review and send" : "Connect Gmail first")
    }

    private func setStateMenu(_ p: Prospect, label: String = "Set a state") -> some View {
        Menu(label) {
            ForEach(ConversationState.allCases, id: \.self) { s in
                Button(s.label) { setState(p, s) }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .font(OVType.meta)
    }

    private func requestNudge(_ d: FollowUp.DueRecipient) {
        guard let email = d.recipient.email else { return }
        let preview = "Subject: \(FollowUp.nudgeSubject(groupName: d.prospect.groupName))\n\n"
            + FollowUp.nudgeBody(contactName: d.recipient.name, groupName: d.prospect.groupName,
                                 venue: d.prospect.venue, attempt: d.recipient.followUpCount + 1)
        pending = PendingNudge(id: d.prospect.naturalKey, recipientId: d.recipient.id, recipient: email, preview: preview)
    }

    private func requestConversationNudge(_ p: Prospect, kind: ConversationReminder.Kind) {
        guard let email = p.contactEmail else { return }
        let body: String
        var closing = false
        switch kind {
        case .active(let state):
            body = ConversationReminder.nudgeBody(for: state, contactName: p.contactName, groupName: p.groupName, venue: p.venue)
        case .closing:
            body = ConversationReminder.closingNudgeBody(contactName: p.contactName, groupName: p.groupName, venue: p.venue)
            closing = true
        case .needsState, .suggested:
            return   // not a sendable nudge; handled by confirm / set-a-state
        }
        pendingConversation = PendingConversation(id: p.naturalKey, recipient: email, preview: body, isClosing: closing)
    }

    private func performNudge(_ naturalKey: String, _ recipientId: String) {
        pending = nil
        guard let p = prospects.first(where: { $0.naturalKey == naturalKey }),
              let r = p.recipients.first(where: { $0.id == recipientId }) else { return }
        let org = p.groupName
        // Await off the synchronous button action so the main thread never blocks on the Gmail
        // token work (the old blocking send bridge deadlocked here).
        Task {
            let sent = await SendService.sendFollowUp(r, of: p, now: Date(),
                                                      sender: GmailSender(fromEmail: "dan@danwrightphotography.com"))
            do {
                try context.save()
                // #285: the send fires async in a sheet; acknowledge it ran, success or failure.
                feedback.acknowledge(ActionAck.followUpSent(org: org, success: sent),
                                     tone: sent ? .info : .warning)
            } catch {
                // #499: same risk as #477, the follow-up may have sent while the local record
                // of it did not; never let that look like nothing happened.
                feedback.acknowledge(ActionAck.sendNotConfirmed(org: org), tone: .warning)
            }
        }
    }

    private func performConversationNudge(_ naturalKey: String, isClosing: Bool) {
        pendingConversation = nil
        guard let p = prospects.first(where: { $0.naturalKey == naturalKey }) else { return }
        let org = p.groupName
        let kind: ConversationReminder.Kind = isClosing ? .closing : .active(p.conversationState ?? .wantsToBook)
        Task {
            let sent = await SendService.sendConversationNudge(p, kind: kind, now: Date(),
                                                        sender: GmailSender(fromEmail: "dan@danwrightphotography.com"))
            do {
                try context.save()
                // #285: same async-in-a-sheet acknowledgment, with closing-note vs nudge wording.
                feedback.acknowledge(ActionAck.conversationNudge(org: org, closing: isClosing, success: sent),
                                     tone: sent ? .info : .warning)
            } catch {
                // #499: same risk as #477, the nudge may have sent while the local record of it
                // did not; never let that look like nothing happened.
                feedback.acknowledge(ActionAck.sendNotConfirmed(org: org), tone: .warning)
            }
        }
    }

    private func remindLater(_ p: Prospect) {
        p.remindLater(now: Date())
        do {
            try context.save()
            // #285: the row drops off the due list, which could read as "sent"; say it was snoozed.
            feedback.acknowledge(ActionAck.remindLater(org: p.groupName))
        } catch {
            feedback.acknowledge(ActionAck.saveFailed(org: p.groupName), tone: .warning)
        }
    }

    private func setState(_ p: Prospect, _ state: ConversationState) {
        p.setConversationState(state, now: Date())
        do {
            try context.save()
        } catch {
            feedback.acknowledge(ActionAck.saveFailed(org: p.groupName), tone: .warning)
        }
    }

    private func confirm(_ p: Prospect) {
        p.confirmConversationState(now: Date())
        do {
            try context.save()
        } catch {
            feedback.acknowledge(ActionAck.saveFailed(org: p.groupName), tone: .warning)
        }
    }
}

private func previewProspect(_ group: String, event: String?) -> Prospect {
    Prospect(naturalKey: group, groupName: group, discipline: "music", venue: "Carnegie Hall",
             performanceDate: event, sourceListingURL: nil, websiteURL: nil,
             priorRelationship: "warm", production: "self", profile: "strong", coverage: "likely_uncovered",
             fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
             possibleMatchSource: nil, possibleMatchName: nil)
}

#Preview("Due (populated)") {
    let container = try! ModelContainer(for: Prospect.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let ctx = container.mainContext
    let longAgo = Date(timeIntervalSinceNow: -30 * 86_400)

    // Active "wants to book" reminder: state set long ago, event still well ahead.
    let a = previewProspect("Aurora Strings", event: "2026-12-01")
    a.contactEmail = "emma@aurorastrings.example"; a.sentAt = longAgo
    a.outcome = .replied; a.conversationState = .wantsToBook; a.conversationStateSetAt = longAgo
    ctx.insert(a)

    // Post-event closing note: the show has passed, still unbooked.
    let b = previewProspect("Lumen Dance", event: "2020-01-01")
    b.contactEmail = "info@lumendance.example"; b.sentAt = longAgo
    b.outcome = .replied; b.conversationState = .interested; b.conversationStateSetAt = longAgo
    ctx.insert(b)

    // Replied but uncategorized: prompt to set a state.
    let c = previewProspect("City Brass Band", event: "2026-11-01")
    c.contactEmail = "hello@citybrass.example"; c.sentAt = longAgo; c.outcome = .replied
    ctx.insert(c)

    // A plain silent follow-up (no conversation state, no reply).
    let d = previewProspect("Old Town Opera", event: "2026-10-01")
    d.contactEmail = "box@oldtownopera.example"; d.sentAt = longAgo
    ctx.insert(d)

    return FollowUpsView().modelContainer(container).environment(ActionFeedback())
}
