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
    // #686: neither row here carries the reply text, AI reply drafter, or Mark… menu (the same
    // gap #683/#684 found and fixed on the Reached Out row); this jumps to the full card that
    // still has them, dismissing this sheet first since Archive opens as a sibling sheet on the
    // same RootView. #685: also carries the specific contact, so a multi-recipient show
    // highlights that one instead of just the whole card.
    var onOpenInArchive: (_ key: String, _ recipientId: String?) -> Void = { _, _ in }
    // #682: the recipient Dan clicked "Send a follow-up" from on the Reached Out row, so this
    // sheet scrolls to and highlights that same entry instead of leaving him to find it again.
    var initialHighlightRecipientId: String? = nil
    // Clears RootView's own copy of the target once captured, so a later plain "Follow-ups" pill
    // click (with no specific recipient) doesn't re-highlight a stale one.
    var onHighlightConsumed: () -> Void = {}
    @State private var highlightedRecipientId: String?
    // #468 (SUP-006): a nudge/closing-note send in flight, keyed by recipient id, same shape as
    // QueueView/ArchiveView's outboundSending/replySending, so this sheet's Send buttons get the
    // same live "Sending…" feedback instead of staying clickable during the send.
    @State private var sending: [String: Date] = [:]
    // #976: the section at the top of the scroll, bound so the list holds its place while its rows
    // rebuild. `prospects` is a @Query, so a reply-classify or Prep run re-emits it and rebuilds this
    // sheet, and a plain ScrollView drops its offset to the top on each one (the #974 shape). Pinned to
    // the top visible section, which is the granularity that holds up when a run reshuffles the rows
    // within. The recipient reveal below scrolls by a different identity (the contact's id), so this is
    // cleared when a reveal starts, letting proxy.scrollTo own that jump. Its own identity, not the
    // section's display title, so the scroll wiring never becomes a second copy of that copy (#843).
    private enum ScrollSection: Hashable { case conversations, silent }
    @State private var topSection: ScrollSection?

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

    // #948: each pending send now carries the branded SendConfirmation the shared SendConfirmSheet
    // renders (the same sheet the main draft send uses), instead of a preview string for a stock alert.
    private struct PendingNudge: Identifiable {
        let id: String        // prospect naturalKey
        let recipientId: String   // which contact on the show (#418 D)
        let confirmation: SendConfirmation
    }

    private struct PendingConversation: Identifiable {
        let id: String        // prospect naturalKey
        let recipientId: String   // which contact on the show (#652)
        let isClosing: Bool
        let confirmation: SendConfirmation
    }

    private var due: [FollowUp.DueRecipient] {
        FollowUp.dueRecipients(from: prospects, now: Date())
            .sorted { ($0.recipient.sentAt ?? .distantPast) < ($1.recipient.sentAt ?? .distantPast) }
    }

    // Already ordered by urgency then soonest event in ConversationReminder.dueRecipients
    // (domain-owned, #652: per-recipient so one contact on a show can be due while another isn't).
    private var conversationDue: [ConversationReminder.DueRecipient] {
        ConversationReminder.dueRecipients(from: prospects, now: Date(), config: reminderConfig)
    }

    private var gmailConnected: Bool { GmailAuthManager.shared.isConnected }
    private var isEmpty: Bool { due.isEmpty && conversationDue.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Due").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                // #885: the SAME count RootView's badge shows, from the one definition, so the pill Dan
                // clicks and the sheet he lands on can never disagree.
                Text("\(DueWork.counts(prospects: prospects, now: Date(), reminder: reminderConfig).total)")
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(OVSpacing.lg)
            Divider()
            if isEmpty {
                Text("Nothing to act on. Leads you've emailed show up here for a gentle follow-up, active conversations for a re-touch, and they drop off the moment they reply, book, or you close them out.")
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(OVSpacing.xl)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: OVSpacing.lg) {
                            if !conversationDue.isEmpty {
                                section("Conversations") {
                                    ForEach(conversationDue, id: \.recipient.id) { d in
                                        conversationRow(d, since: sending[d.recipient.id]); Divider()
                                    }
                                }
                                // #976: identity for the position modifier, so the top section pins.
                                .id(ScrollSection.conversations)
                            }
                            if !due.isEmpty {
                                section("Silent follow-ups") {
                                    ForEach(Array(due.enumerated()), id: \.offset) { _, d in
                                        row(d, since: sending[d.recipient.id]); Divider()
                                    }
                                }
                                .id(ScrollSection.silent)   // #976
                            }
                        }
                        .scrollTargetLayout()
                        .padding(OVSpacing.lg)
                    }
                    // #976: hold the scroll on the top visible section across a @Query rebuild (topSection).
                    .scrollPosition(id: $topSection, anchor: .top)
                    // #682: reuses ArchiveReveal's cancellation-safe scroll-after-delay timing
                    // (the same one ArchiveView uses for its own search/deep-link jumps) instead
                    // of a second copy of that logic.
                    .task(id: highlightedRecipientId) {
                        guard let key = highlightedRecipientId else { return }
                        // #976: release the pinned section so a rebuild during this jump cannot restore
                        // the old top over the contact we are revealing; the scrollTo below owns it.
                        topSection = nil
                        await ArchiveReveal.scrollAfterDelay(key: key) { key in
                            withAnimation { proxy.scrollTo(key, anchor: .center) }
                        }
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        if highlightedRecipientId == key { highlightedRecipientId = nil }
                    }
                }
            }
        }
        .frame(width: 500, height: 560)
        .background(OVColor.canvas)
        // #948: the follow-up and conversation-note confirmations are the same branded SendConfirmSheet
        // the main draft send uses (From / To / Subject / body preview), not a stock system alert. All
        // three consequential sends now look and read the same.
        .sheet(item: $pending) { p in
            SendConfirmSheet(confirmation: p.confirmation,
                             onSend: { performNudge(p.id, p.recipientId) },
                             onCancel: { pending = nil })
        }
        .sheet(item: $pendingConversation) { p in
            SendConfirmSheet(confirmation: p.confirmation,
                             onSend: { performConversationNudge(p.id, p.recipientId, isClosing: p.isClosing) },
                             onCancel: { pendingConversation = nil })
        }
        .actionFeedbackBanner()
        .onAppear {
            guard let key = initialHighlightRecipientId else { return }
            highlightedRecipientId = key
            onHighlightConsumed()
        }
    }

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            Text(title.uppercased()).font(OVType.tag).foregroundStyle(OVColor.inkFaint)
            content()
        }
    }

    // A silent follow-up to one contact (#45, per-recipient #418 D).
    // #710: `since` is threaded explicitly (not read from `self.sending[r.id]` internally) so this
    // is directly testable with ViewInspector, the same prop-threading shape DraftReviewView and
    // ProspectRowView already use, rather than fighting an owned @State from outside a view instance.
    func row(_ d: FollowUp.DueRecipient, since: Date?) -> some View {
        let r = d.recipient
        return HStack(alignment: .top, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.prospect.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
                Text(FollowUp.nudgeLabel(email: r.email, followUpCount: r.followUpCount))
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                if let line = SendFailureLine.text(for: r.sendError) {
                    Text(line).font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(2)
                }
            }
            Spacer(minLength: OVSpacing.sm)
            VStack(alignment: .trailing, spacing: 6) {
                if let since {
                    LiveRunLabel(base: "Sending", since: since, timeout: RunTimeouts.send,
                                 font: OVType.meta, color: OVColor.inkSoft)
                } else {
                    sendButton("Send nudge", enabled: gmailConnected && (r.email?.isEmpty == false)) { requestNudge(d) }
                }
                // #686: reply text, AI reply drafter, and Mark… only exist on the full card in Archive.
                Button("View in Archive") { onOpenInArchive(d.prospect.naturalKey, r.id) }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            }
        }
        .padding(.vertical, OVSpacing.xs)
        .padding(.horizontal, OVSpacing.xs)
        .background(highlightedRecipientId == r.id ? OVColor.gold.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .id(r.id)
    }

    // A conversation reminder (#111, per-recipient #652): tagged by reason, with the action its kind
    // calls for, scoped to ONE contact on the show. #710: see row(_:since:) above for why `since`
    // is an explicit parameter instead of an internal `self.sending[r.id]` read.
    func conversationRow(_ d: ConversationReminder.DueRecipient, since: Date?) -> some View {
        let p = d.prospect, r = d.recipient
        return HStack(alignment: .top, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
                reasonPill(d.reminder.reason, color: ConversationReminder.accent(for: d.reminder.kind).color)
                Text(r.email ?? "no contact").font(OVType.body).foregroundStyle(OVColor.inkSoft)
                // #316: the durable failure surface. A real send failure persists on the recipient
                // (SendService sets sendError), so it stays visible here until the next successful
                // send clears it, unlike the fading banner a later success can overwrite first.
                if let line = SendFailureLine.text(for: r.sendError) {
                    Text(line).font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(2)
                }
            }
            Spacer(minLength: OVSpacing.sm)
            VStack(alignment: .trailing, spacing: 6) {
                if let since {
                    LiveRunLabel(base: "Sending", since: since, timeout: RunTimeouts.send,
                                 font: OVType.meta, color: OVColor.inkSoft)
                } else {
                    switch d.reminder.kind {
                    case .active(let state):
                        sendButton("Send nudge", enabled: gmailConnected && r.email != nil) {
                            requestConversationNudge(d, kind: .active(state))
                        }
                        Button("Remind me later") { remindLater(d) }
                            .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    case .closing:
                        sendButton("Send closing note", enabled: gmailConnected && r.email != nil) {
                            requestConversationNudge(d, kind: .closing)
                        }
                    case .suggested:
                        // An AI guess awaiting Dan: confirm it (onto the timed track) or correct it.
                        sendButton("Confirm", enabled: true) { confirm(d) }
                        setStateMenu(d, label: "Change")
                    case .needsState:
                        setStateMenu(d, label: "Set a state")
                    }
                }
                // #686: reply text, AI reply drafter, and Mark… only exist on the full card in Archive.
                Button("View in Archive") { onOpenInArchive(d.prospect.naturalKey, r.id) }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            }
        }
        .padding(.vertical, OVSpacing.xs)
        .padding(.horizontal, OVSpacing.xs)
        .background(highlightedRecipientId == r.id ? OVColor.gold.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .id(r.id)
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
        .help(GmailCopy.sendHelp(connected: gmailConnected, whenConnected: "Review and send"))
    }

    private func setStateMenu(_ d: ConversationReminder.DueRecipient, label: String = "Set a state") -> some View {
        ConversationStateMenu(currentState: d.recipient.conversationState, label: label) { setState(d, $0) }
    }

    private func requestNudge(_ d: FollowUp.DueRecipient) {
        // #948: the branded confirmation is built from the same FollowUp.nudgeContent the sender reads,
        // so what Dan sees on the sheet (From / To / Subject / body) is exactly what goes out. The old
        // preview derived its subject from nudgeSubject while the send used replySubject: two subjects.
        guard let confirmation = SendConfirmation(followUpFor: d.recipient, of: d.prospect) else { return }
        pending = PendingNudge(id: d.prospect.naturalKey, recipientId: d.recipient.id, confirmation: confirmation)
    }

    private func requestConversationNudge(_ d: ConversationReminder.DueRecipient, kind: ConversationReminder.Kind) {
        let p = d.prospect, r = d.recipient
        let isClosing: Bool
        if case .closing = kind { isClosing = true } else { isClosing = false }
        // Nil for a kind that is a prompt, not a sendable email (handled by confirm / set-a-state).
        guard let confirmation = SendConfirmation(conversationNudgeFor: r, of: p, kind: kind) else { return }
        pendingConversation = PendingConversation(id: p.naturalKey, recipientId: r.id,
                                                  isClosing: isClosing, confirmation: confirmation)
    }

    // #468 (SUP-006): routed through ProspectMutations so this sheet's send gets the same
    // in-flight LiveRunLabel every other send surface already shows, instead of a bare Task with
    // the button left clickable.
    private func performNudge(_ naturalKey: String, _ recipientId: String) {
        pending = nil
        ProspectMutations.sendFollowUp(naturalKey, recipientId, prospects: prospects, context: context, feedback: feedback,
                                       markSending: { sending[$0] = Date() },
                                       clearSending: { sending[$0] = nil })
    }

    private func performConversationNudge(_ naturalKey: String, _ recipientId: String, isClosing: Bool) {
        pendingConversation = nil
        ProspectMutations.sendConversationNudge(naturalKey, recipientId, isClosing: isClosing,
                                                prospects: prospects, context: context, feedback: feedback,
                                                markSending: { sending[$0] = Date() },
                                                clearSending: { sending[$0] = nil })
    }

    private func remindLater(_ d: ConversationReminder.DueRecipient) {
        d.recipient.remindLater(now: Date())
        if context.saveOrWarn(org: d.prospect.groupName, feedback: feedback) {
            // #285: the row drops off the due list, which could read as "sent"; say it was snoozed.
            feedback.acknowledge(ActionAck.remindLater(org: d.prospect.groupName))
        }
    }

    private func setState(_ d: ConversationReminder.DueRecipient, _ state: ConversationState) {
        d.recipient.setConversationState(state, now: Date())
        d.prospect.resumePausedRecipients()
        context.saveOrWarn(org: d.prospect.groupName, feedback: feedback)
    }

    private func confirm(_ d: ConversationReminder.DueRecipient) {
        d.recipient.confirmConversationState(now: Date())
        context.saveOrWarn(org: d.prospect.groupName, feedback: feedback)
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
    let container = try! ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let ctx = container.mainContext
    let longAgo = Date(timeIntervalSinceNow: -30 * 86_400)

    // Active "wants to book" reminder: state set long ago, event still well ahead.
    let a = previewProspect("Aurora Strings", event: "2026-12-01")
    let aContact = Recipient(id: "emma@aurorastrings.example", email: "emma@aurorastrings.example", provenance: .act)
    aContact.sendState = .sent; aContact.sentAt = longAgo
    aContact.setConversationState(.wantsToBook, now: longAgo)
    a.setRecipients([aContact])
    ctx.insert(a)

    // Post-event closing note: the show has passed, still unbooked.
    let b = previewProspect("Lumen Dance", event: "2020-01-01")
    let bContact = Recipient(id: "info@lumendance.example", email: "info@lumendance.example", provenance: .act)
    bContact.sendState = .sent; bContact.sentAt = longAgo
    bContact.setConversationState(.interested, now: longAgo)
    b.setRecipients([bContact])
    ctx.insert(b)

    // Replied but uncategorized: prompt to set a state.
    let c = previewProspect("City Brass Band", event: "2026-11-01")
    let cContact = Recipient(id: "hello@citybrass.example", email: "hello@citybrass.example", provenance: .act)
    cContact.sendState = .sent; cContact.sentAt = longAgo; cContact.replied = true
    c.setRecipients([cContact])
    ctx.insert(c)

    // A plain silent follow-up (no conversation state, no reply).
    let d = previewProspect("Old Town Opera", event: "2026-10-01")
    let dContact = Recipient(id: "box@oldtownopera.example", email: "box@oldtownopera.example", provenance: .act)
    dContact.sendState = .sent; dContact.sentAt = longAgo
    d.setRecipients([dContact])
    ctx.insert(d)

    return FollowUpsView().modelContainer(container).environment(ActionFeedback())
}
