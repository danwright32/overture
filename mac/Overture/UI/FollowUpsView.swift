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
    // #686: neither row here carries the reply text, AI reply drafter, or Mark… menu (the same
    // gap #683/#684 found and fixed on the Reached Out row); this jumps to the full card that
    // still has them, dismissing this sheet first since Archive opens as a sibling sheet on the
    // same RootView. #685: also carries the specific contact, so a multi-recipient show
    // highlights that one instead of just the whole card.
    var onOpenInArchive: (_ key: String, _ recipientId: String?) -> Void = { _, _ in }
    // #682: the recipient Dan clicked "Send a follow-up" from on the Reached Out row, so this
    // sheet scrolls to and highlights that same entry instead of leaving him to find it again.
    // Clears RootView's own copy of the target once captured, so a later plain "Follow-ups" pill
    // click (with no specific recipient) doesn't re-highlight a stale one.
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
    private enum ScrollSection: Hashable { case afterTheShow, silent }
    @State private var topSection: ScrollSection?

    // #948: each pending send now carries the branded SendConfirmation the shared SendConfirmSheet
    // renders (the same sheet the main draft send uses), instead of a preview string for a stock alert.
    private struct PendingNudge: Identifiable {
        let id: String        // prospect naturalKey
        let recipientId: String   // which contact on the show (#418 D)
        let confirmation: SendConfirmation
    }

    private var due: [FollowUp.DueRecipient] {
        FollowUp.dueRecipients(from: prospects, now: Date())
            .sorted { ($0.recipient.sentAt ?? .distantPast) < ($1.recipient.sentAt ?? .distantPast) }
    }

    // #2397: the post-event prompts, already ordered by urgency then soonest event in
    // PostEventPrompt.dueRecipients. The conversation-state chase that used to fill this section is
    // retired along with the states it chased; what is left is triggered by the show's DATE.
    private var postEventDue: [PostEventPrompt.DueRecipient] {
        PostEventPrompt.dueRecipients(from: prospects, now: Date())
    }

    // #1770: the cached flag, not the disk read. As written before, this re-opened and JSON-decoded the
    // token file on EVERY access, and the body below reads it once per send button it draws.
    // #2546: a seam, not a stored copy of the answer. The app never passes this, so it keeps reading the
    // live connection through the computed property below, which is what SwiftUI's observation watches;
    // holding the value in a stored property instead would freeze it at the view's construction and stop
    // a reconnect redrawing these rows. A test has to render both sides of the Gmail gate, and the
    // singleton cannot be set from one.
    var gmailConnectedOverride: Bool?
    private var gmailConnected: Bool { gmailConnectedOverride ?? GmailConnection.shared.isConnected }
    private var isEmpty: Bool { due.isEmpty && postEventDue.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Due").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                // #885: the SAME count RootView's badge shows, from the one definition, so the pill Dan
                // clicks and the sheet he lands on can never disagree.
                Text("\(DueWork.counts(prospects: prospects, now: Date()).total)")
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(OVSpacing.lg)
            Divider()
            if isEmpty {
                Text("Nothing to act on. Shows you've emailed appear here for a gentle follow-up, and again once the date has passed so you can close them out. They drop off the moment you record how one ended.")
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(OVSpacing.xl)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: OVSpacing.lg) {
                            if !postEventDue.isEmpty {
                                section("After the show") {
                                    ForEach(postEventDue, id: \.recipient.id) { d in
                                        postEventRow(d, since: sending[d.recipient.id]); Divider()
                                    }
                                }
                                // #976: identity for the position modifier, so the top section pins.
                                .id(ScrollSection.afterTheShow)
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
                             onSend: { performNudge(p.id, p.recipientId, body: nil) },
                             onCancel: { pending = nil },
                             // #2575: the words in the box are the words that send.
                             onSendEdited: { performNudge(p.id, p.recipientId, body: $0) })
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
                    sendButton("Send nudge", hasAddress: SendGate.hasAddress(r.email)) { requestNudge(d) }
                }
                standDownMenu(prospect: d.prospect, recipient: r)
                // #686: reply text, AI reply drafter, and Mark… only exist on the full card in Archive.
                Button("View in Archive") { onOpenInArchive(d.prospect.naturalKey, r.id) }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            }
        }
        .padding(.vertical, OVSpacing.xs)
        .padding(.horizontal, OVSpacing.xs)
        .id(r.id)
    }

    // #2397: a post-event prompt, tagged by reason, with the action its kind calls for. #710: see
    // row(_:since:) above for why `since` is an explicit parameter rather than an internal read.
    func postEventRow(_ d: PostEventPrompt.DueRecipient, since: Date?) -> some View {
        let p = d.prospect, r = d.recipient
        return HStack(alignment: .top, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
                reasonPill(d.prompt.reason, color: PostEventPrompt.accent(for: d.prompt.kind).color)
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
                    // #2710: both kinds land here now. Neither is an email: the final follow-up is the
                    // last thing Overture sends a silent contact, so what is left after the show is Dan
                    // recording how it ended, from the row he is standing on. The two differ only in the
                    // sentence beside them, which `PostEventPrompt.reason` decides.
                    CloseOutMenu(outcomes: ShowOutcome.menu(wasPitched: p.wasPitched)) { outcome in
                        ProspectMutations.recordOutcome(QueueItem(p), outcome, prospects: prospects,
                                                        context: context, feedback: feedback)
                    }
                }
                // #686: reply text, AI reply drafter, and Mark… only exist on the full card in Archive.
                Button("View in Archive") { onOpenInArchive(d.prospect.naturalKey, r.id) }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            }
        }
        .padding(.vertical, OVSpacing.xs)
        .padding(.horizontal, OVSpacing.xs)
        .id(r.id)
    }

    private func reasonPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(OVType.tag).fontWeight(.medium).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.25)))
    }

    // #2546: takes the FACT (has this contact an address) rather than a pre-computed `enabled`, so the
    // one call below decides both whether the button works and what is said while it does not.
    //
    // The tooltip used to be `sendHelp(connected:whenConnected:)`, which reads "Review and send" whenever
    // Gmail is connected. That is the wrong sentence for the other cause this button refuses on: a
    // contact with no address got a dead button and a tooltip promising it would send (L11).
    private func sendButton(_ title: String, hasAddress: Bool, action: @escaping () -> Void) -> some View {
        let refusal = SendGate.reason(gmailConnected: gmailConnected, hasAddress: hasAddress)
        return VStack(alignment: .trailing, spacing: 2) {
            Button(action: action) {
                Text(title).font(OVType.meta).foregroundStyle(OVColor.onForest)
                    .padding(.horizontal, OVSpacing.md).padding(.vertical, 6)
                    .background(Capsule().fill(OVColor.forest))
            }
            .buttonStyle(.plain)
            .disabled(refusal != nil)
            // A dimmed control with no label is unreadable to VoiceOver as well as to the eye.
            .accessibilityHint(refusal ?? "")
            .help(refusal ?? "Review and send")
            // Said on screen and not only in the tooltip, which is invisible at rest (L49). Under the
            // button rather than beside it: these rows are already tight to the right edge.
            ControlRefusalLine(reason: refusal, alignment: .trailing)
        }
    }

    private func requestNudge(_ d: FollowUp.DueRecipient) {
        // #948: the branded confirmation is built from the same FollowUp.nudgeContent the sender reads,
        // so what Dan sees on the sheet (From / To / Subject / body) is exactly what goes out. The old
        // preview derived its subject from nudgeSubject while the send used replySubject: two subjects.
        guard let confirmation = SendConfirmation(followUpFor: d.recipient, of: d.prospect) else { return }
        pending = PendingNudge(id: d.prospect.naturalKey, recipientId: d.recipient.id, confirmation: confirmation)
    }


    // #468 (SUP-006): routed through ProspectMutations so this sheet's send gets the same
    // in-flight LiveRunLabel every other send surface already shows, instead of a bare Task with
    // the button left clickable.
    private func performNudge(_ naturalKey: String, _ recipientId: String, body: String?) {
        pending = nil
        ProspectMutations.sendFollowUp(naturalKey, recipientId, prospects: prospects, context: context, feedback: feedback,
                                       body: body,
                                       markSending: { sending[$0] = Date() },
                                       clearSending: { sending[$0] = nil })
    }


    // #1740: Dan's way of saying "I'm not going to action this". Both futures are offered because he
    // asked to choose each time (2026-07-30): standing the contact down for good, or pushing it out one
    // gap. Secondary styling on purpose, never as loud as Send: declining is the quieter action, and the
    // row sits one click from sending a real email to a stranger.
    // The nudge row's version: decline this event's pitch, at either grain, or push it out one gap.
    @ViewBuilder private func standDownMenu(prospect: Prospect, recipient: Recipient) -> some View {
        Menu(StandDownCopy.menu) {
            Button(StandDownCopy.stop) { standDown(prospect: prospect, recipient: recipient, scope: .contact) }
            Button(StandDownCopy.stopShow) { standDown(prospect: prospect, recipient: recipient, scope: .show) }
            Button(StandDownCopy.pushOut()) {
                pushOut(prospect: prospect, recipient: recipient, track: .nudge)
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
    }

    // The closing-note row's version, and it is a different decision: this note is about the NEXT event,
    // so declining it is not declining the show. "Not sent but also done" (Dan, 2026-07-30).

    private func standDown(prospect: Prospect, recipient: Recipient, scope: StandDownScope) {
        ProspectMutations.standDown(prospect: prospect, recipient: recipient, scope: scope, now: Date())
        guard context.saveOrWarn(org: prospect.groupName, feedback: feedback) else { return }
        // Undo, because the row this replaces is one click from Send nudge and the decision removes work
        // from a queue. The acknowledgement carries it, which is the shape every surface outside the
        // queue's own Cmd+Z uses.
        feedback.acknowledge(ActionAck.outreachStoodDown(org: prospect.groupName, scope: scope),
                             action: .init(label: "Undo") {
                                 ProspectMutations.resumeStandDown(prospect: prospect,
                                                                   recipient: recipient, scope: scope)
                                 context.saveOrWarn(org: prospect.groupName, feedback: feedback)
                             })
    }


    private func pushOut(prospect: Prospect, recipient: Recipient, track: StandDownTrack) {
        let now = Date()
        // Only the clock this row actually runs on. Moving both would stamp the conversation track's
        // anchor on a silent contact that has no conversation yet, and that anchor wins over the state's
        // own date later, so a nudge pushed out today would make the contact's FIRST conversation
        // reminder read as already overdue the moment a state is set.
        switch track {
        case .nudge: recipient.remindLaterAboutNudge(now: now)
        case .conversation: recipient.remindLater(now: now)
        }
        guard context.saveOrWarn(org: prospect.groupName, feedback: feedback) else { return }
        feedback.acknowledge(ActionAck.nudgePushedOut(org: prospect.groupName,
                                                      days: FollowUpConfig().gapDays))
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

    // #2397: post-event closing note. The show has passed and nobody ever wrote back.
    let b = previewProspect("Lumen Dance", event: "2020-01-01")
    let bContact = Recipient(id: "info@lumendance.example", email: "info@lumendance.example", provenance: .act)
    bContact.sendState = .sent; bContact.sentAt = longAgo
    bContact.gmailMessageId = "preview-b"
    b.setRecipients([bContact])
    ctx.insert(b)

    // #2397: the other post-event kind. The show has passed and somebody DID write back, so there is
    // nothing to send and Dan is asked to say how it ended.
    let c = previewProspect("City Brass Band", event: "2020-02-01")
    let cContact = Recipient(id: "hello@citybrass.example", email: "hello@citybrass.example", provenance: .act)
    cContact.sendState = .sent; cContact.sentAt = longAgo; cContact.gmailMessageId = "preview-c"
    cContact.reopenOnReply(at: longAgo)
    c.setRecipients([cContact])
    ctx.insert(c)

    // A plain silent follow-up (nothing has come back, and the show is still ahead).
    let d = previewProspect("Old Town Opera", event: "2026-10-01")
    let dContact = Recipient(id: "box@oldtownopera.example", email: "box@oldtownopera.example", provenance: .act)
    dContact.sendState = .sent; dContact.sentAt = longAgo
    d.setRecipients([dContact])
    ctx.insert(d)

    return FollowUpsView().modelContainer(container).environment(ActionFeedback())
}
