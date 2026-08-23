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
    // #2816: the watchlist, so a row's link back to the show can say whether it reaches the show's own
    // page or only the source's calendar (#1680). A @Query on the same precedent QueueView follows: a
    // source whose calendar address changes re-decides the label with no other prompting, and an empty
    // table would label every link as an event page, which is #1825's defect pointing the other way.
    @Query private var watchedSources: [WatchedSource]
    @State private var pending: PendingNudge?
    // #686: neither row here carries the reply text, AI reply drafter, or Mark… menu (the same
    // gap #683/#684 found and fixed on the Reached Out row); this jumps to the full card that
    // still has them, dismissing this sheet first since Archive opens as a sibling sheet on the
    // same RootView. #685: also carries the specific contact, so a multi-recipient show
    // highlights that one instead of just the whole card.
    var onOpenInArchive: (_ key: String, _ recipientId: String?) -> Void = { _, _ in }
    // #2967: confirming a conversation reaches Gmail, so this sheet needs the same way back from a dead
    // connection that every other consequential screen has. Defaulted to nothing only so a test can
    // render the sheet without one; RootView passes its own `connectGmail`.
    var onConnectGmail: () -> Void = {}
    // #682: the recipient Dan clicked "Send a follow-up" from on the Reached Out row, so this
    // sheet scrolls to and highlights that same entry instead of leaving him to find it again.
    // Clears RootView's own copy of the target once captured, so a later plain "Follow-ups" pill
    // click (with no specific recipient) doesn't re-highlight a stale one.
    // #468 (SUP-006): a nudge/closing-note send in flight, keyed by recipient id, same shape as
    // QueueView/ArchiveView's outboundSending/replySending, so this sheet's Send buttons get the
    // same live "Sending…" feedback instead of staying clickable during the send.
    @State private var sending: [String: Date] = [:]
    // #2967: which contact's conversation is being linked right now. The same shape QueueView's Reached
    // out row uses, and for the same reason: confirming reaches Gmail, so the control has to show three
    // visibly different states (at rest, working, failed) rather than one indefinite spinner.
    @State private var linkingConversationFor: String?
    @State private var showReconnect = false
    // #976: the section at the top of the scroll, bound so the list holds its place while its rows
    // rebuild. `prospects` is a @Query, so a reply-classify or Prep run re-emits it and rebuilds this
    // sheet, and a plain ScrollView drops its offset to the top on each one (the #974 shape). Pinned to
    // the top visible section, which is the granularity that holds up when a run reshuffles the rows
    // within. The recipient reveal below scrolls by a different identity (the contact's id), so this is
    // cleared when a reveal starts, letting proxy.scrollTo own that jump. Its own identity, not the
    // section's display title, so the scroll wiring never becomes a second copy of that copy (#843).
    private enum ScrollSection: Hashable {
        case afterTheShow, silent, stalledReplyDrafts, conversationsToConfirm
    }
    @State private var topSection: ScrollSection?

    // #948: each pending send now carries the branded SendConfirmation the shared SendConfirmSheet
    // renders (the same sheet the main draft send uses), instead of a preview string for a stock alert.
    private struct PendingNudge: Identifiable {
        let id: String        // prospect naturalKey
        let recipientId: String   // which contact on the show (#418 D)
        let confirmation: SendConfirmation
    }

    // #2878/#2828: every row this sheet renders, from the ONE place that also produces the number its
    // header states and the number the pill that opens it states. The three lists used to be derived
    // here, in a view body no test can reach, which is how a fourth thing (a stalled reply draft) could
    // be counted by the pill while this sheet listed nothing at all (L16, #863).
    //
    // #2397: the post-event prompts arrive already ordered by urgency then soonest event, and the silent
    // follow-ups oldest pitch first; both orderings live in DueWork.rows now.
    private var rows: DueWork.Rows {
        DueWork.rows(prospects: prospects, now: Date(), replyRunAlive: replyRunAlive)
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
    // #2878: a seam of the same shape and for the same reason as `gmailConnectedOverride` above. A
    // classify run that is still beating means nothing is stalled (#471), and a test has to be able to
    // render both sides of that without a live detached run.
    var replyRunAliveOverride: Bool?
    private var replyRunAlive: Bool { replyRunAliveOverride ?? ReplyClassifyService.isRunning(now: Date()) }

    var body: some View {
        // #2878: ONE derivation for the whole sheet, so the header, the empty test and the three lists
        // are three readings of one answer rather than three sweeps of the store that could disagree.
        // It used to be derived up to three times in this body (#1121's rule, in the other direction).
        let listed = rows
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Due").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                // #885: the SAME count RootView's badge shows, from the one definition, so the pill Dan
                // clicks and the sheet he lands on can never disagree.
                Text("\(listed.counts.total)")
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(OVSpacing.lg)
            Divider()
            if listed.isEmpty {
                // #2878: the sentence lives in EmptyState with its siblings, composed to name every
                // subject this sheet holds, including the stalled reply drafts (L11, #885).
                Text(EmptyState.followUpsSheet)
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(OVSpacing.xl)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: OVSpacing.lg) {
                            // #2816: built ONCE for both sections rather than per row (#1121).
                            let sourceCalendars = QueueModel.sourceCalendarIndex(watchedSources)
                            // #2919: one clock for the whole list, on the same rule, rather than each row
                            // reading `Date()` for itself and dating its own sentence a moment apart.
                            let now = Date()
                            // #2878: first, because it is the only one of the three that says something
                            // has gone WRONG. The other two are work arriving on schedule.
                            if !listed.stalledReplyDrafts.isEmpty {
                                section(StalledReplyDraftCopy.section) {
                                    ForEach(listed.stalledReplyDrafts, id: \.recipient.id) { d in
                                        stalledReplyDraftRow(d, sourceCalendars: sourceCalendars, now: now)
                                        Divider()
                                    }
                                }
                                .id(ScrollSection.stalledReplyDrafts)   // #976
                            }
                            // #2967: above "After the show" on purpose. This asks whether somebody
                            // replied at all, and the answer changes what a post-event prompt on the
                            // same show should even say, so it is the question to settle first.
                            if !listed.conversationsToConfirm.isEmpty {
                                section(ProposedConversationCopy.section) {
                                    ForEach(listed.conversationsToConfirm, id: \.recipient.id) { d in
                                        conversationToConfirmRow(d, sourceCalendars: sourceCalendars,
                                                                 now: now)
                                        Divider()
                                    }
                                }
                                .id(ScrollSection.conversationsToConfirm)   // #976
                            }
                            if !listed.afterTheShow.isEmpty {
                                section("After the show") {
                                    ForEach(listed.afterTheShow, id: \.recipient.id) { d in
                                        postEventRow(d, since: sending[d.recipient.id],
                                                     sourceCalendars: sourceCalendars, now: now); Divider()
                                    }
                                }
                                // #976: identity for the position modifier, so the top section pins.
                                .id(ScrollSection.afterTheShow)
                            }
                            if !listed.silent.isEmpty {
                                section("Silent follow-ups") {
                                    ForEach(Array(listed.silent.enumerated()), id: \.offset) { _, d in
                                        row(d, since: sending[d.recipient.id],
                                            sourceCalendars: sourceCalendars); Divider()
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
        // #2967: confirming reaches Gmail, so this sheet can meet a dead connection the same way the
        // Reached out row can. The SHARED alert (#631), never a second wording, and it carries the
        // Connect Gmail action rather than only the news, because a message naming what is wrong on a
        // surface with no way to act on it leaves Dan where he started (L80).
        .alert(GmailReconnectCopy.title, isPresented: $showReconnect) {
            Button(GmailReconnectCopy.connect) { onConnectGmail() }
            Button(GmailReconnectCopy.cancel, role: .cancel) {}
        } message: {
            Text(GmailReconnectCopy.afterLinkAttempt)
        }
        .actionFeedbackBanner()
    }

    // #2967: the conversation Overture thinks might be their reply, with the two answers Dan can give
    // it. The same question, the same words and the same two actions the Reached out row carries, from
    // the same copy constants: the row moved here because the number counting it lands him here, and a
    // second wording of one question is how two surfaces come to disagree about what is being asked.
    @ViewBuilder
    func conversationToConfirmRow(_ d: ProposedConversation.DueRecipient,
                                  sourceCalendars: [String: String], now: Date) -> some View {
        let candidate = d.candidate
        VStack(alignment: .leading, spacing: 3) {
            Text(d.prospect.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
            RowSourceLink(listingURL: d.prospect.sourceListingURL, sourceIds: d.prospect.sourceIds,
                          calendars: sourceCalendars)
            Text(ProposedConversationCopy.question).font(OVType.meta).foregroundStyle(OVColor.ink)
            Text(ProposedConversationCopy.sender(name: candidate.fromName,
                                                 address: candidate.fromAddress))
                .font(.system(size: 10)).foregroundStyle(OVColor.ink)
            Text(ProposedConversationCopy.detail(subject: candidate.subject,
                                                 sentAt: candidate.sentAt, now: now))
                .font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
            // What confirming DOES, beside the control that does it, so what Dan approves is exactly
            // what happens including who it reaches (L64).
            Text(ProposedConversationCopy.confirmDetail(address: candidate.fromAddress))
                .font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: OVSpacing.sm) {
                if linkingConversationFor == d.recipient.id {
                    ProgressView().controlSize(.small)
                    Text(ProposedConversationCopy.linking).font(OVType.meta)
                        .foregroundStyle(OVColor.inkSoft)
                } else {
                    Button(ProposedConversationCopy.confirm) {
                        linkProposedConversation(d.recipient, of: d.prospect)
                    }
                    .font(OVType.meta)
                    Button(ProposedConversationCopy.decline) {
                        declineProposedConversation(d.recipient)
                    }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func linkProposedConversation(_ r: Recipient, of p: Prospect) {
        linkingConversationFor = r.id
        Task { @MainActor in
            let outcome = await ConfirmProposedConversation().confirm(on: r, of: p, in: context)
            linkingConversationFor = nil
            switch outcome {
            case .notConnected: showReconnect = true
            case .failed(let reason), .refused(let reason):
                feedback.acknowledge(reason, tone: .warning)
            case .attached(_, let saveFailed):
                feedback.acknowledge(saveFailed ? ProposedConversationCopy.couldNotSaveLink
                                                : ProposedConversationCopy.linked,
                                     tone: saveFailed ? .warning : .info)
            }
        }
    }

    private func declineProposedConversation(_ r: Recipient) {
        ProposedConversation.decline(on: r)
        do {
            try context.save()
        } catch {
            feedback.acknowledge(ProposedConversationCopy.couldNotSaveLink, tone: .warning)
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
    // #2816: `sourceCalendars` is the watchlist's sourceId-to-calendar table, built once by the body and
    // handed down. No default: an empty table calls every link the show's own page, including the ones
    // that only reach the venue's calendar, so a caller that forgot it would get a confidently wrong
    // label instead of a compile error (L168).
    func row(_ d: FollowUp.DueRecipient, since: Date?, sourceCalendars: [String: String]) -> some View {
        let r = d.recipient
        return HStack(alignment: .top, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.prospect.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
                // #2816: the same way back to the show that the Reached out row carries, for the same
                // reason: this is the other surface where an open pitch is worked, and deciding whether
                // to nudge turns on the show as much as on the silence.
                RowSourceLink(listingURL: d.prospect.sourceListingURL, sourceIds: d.prospect.sourceIds,
                              calendars: sourceCalendars)
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
                    // #2876: opens the follow-up's send review; nothing leaves until the sheet's own Send.
                    sendButton(SendConfirmCopy.openReview,
                               hasAddress: SendGate.hasAddress(r.email)) { requestNudge(d) }
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
    // #2816: `sourceCalendars` for the same reason, and with no default for the same reason (L168). See
    // `row(_:since:sourceCalendars:)` above.
    // #2919: `now` for the same reason `since` and `sourceCalendars` are parameters, and with no default
    // for the same reason (L168): the answered line dates a real exchange, and a caller that forgot it
    // would silently get a sentence dated from some other moment rather than a compile error.
    func postEventRow(_ d: PostEventPrompt.DueRecipient, since: Date?,
                      sourceCalendars: [String: String], now: Date) -> some View {
        let p = d.prospect, r = d.recipient
        return HStack(alignment: .top, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
                // #2816: the show is over here, and the question is how it ended, which is exactly when
                // the listing is worth another look. Covered with its sibling rather than left as the one
                // open-pitch row without a way back (the class, not the instance).
                RowSourceLink(listingURL: p.sourceListingURL, sourceIds: p.sourceIds,
                              calendars: sourceCalendars)
                reasonPill(d.prompt.reason, color: PostEventPrompt.accent(for: d.prompt.kind).color)
                Text(r.email ?? "no contact").font(OVType.body).foregroundStyle(OVColor.inkSoft)
                // #2919, the sibling of the reached-out row and covered with it rather than left for a
                // later sweep (the class, not the instance). This row asks how the show ended and offers
                // the endings; asking that with no sign that a conversation ever happened is the same
                // defect, on the surface where the answer matters most. The same sentence, from the same
                // rule, so one exchange cannot be described in two different words on two screens.
                if let answered = AnsweredReplyNote.line(for: r, in: p, now: now) {
                    Text(answered).font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
                }
                // #3068: built by #1740 for this row and never rendered. The row asks how the show ended
                // and offers the endings; on a show Dan already walked away from, asking that with no
                // sign of the decision reads as a nudge about an event he is finished with. Reachable
                // through `reopenOutcome`, which clears the ending and leaves the stand-down stamp, so
                // the row comes back months after the decision with nothing recalling it.
                if let stoodDown = StandDownCopy.closingNoteOnStoodDownShow(
                    stoodDownAt: p.outreachStoodDownAt, now: now) {
                    Text(stoodDown).font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
                }
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

    // #2878/#2828: a reply draft Dan asked for that died on the way. The pill has counted these for a
    // long time and nothing listed them, so this is the row that number was always a promise about.
    //
    // It carries an action, because naming a problem with nowhere to go is its own defect (#80, #126):
    // "Draft it again" asks for the same draft on the same conversation, and "View in Archive" reaches
    // the full card where the reply text and the compose box are, so he can simply write it himself.
    // #710: threaded parameters and no defaults for the same reasons the two rows above have them (L168).
    func stalledReplyDraftRow(_ d: StalledReplyDraft.DueRecipient,
                              sourceCalendars: [String: String], now: Date) -> some View {
        let p = d.prospect, r = d.recipient
        return HStack(alignment: .top, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
                RowSourceLink(listingURL: p.sourceListingURL, sourceIds: p.sourceIds,
                              calendars: sourceCalendars)
                Text(r.email ?? "no contact").font(OVType.body).foregroundStyle(OVColor.inkSoft)
                Text(StalledReplyDraftCopy.line(requestedAt: d.requestedAt, now: now))
                    .font(.system(size: 10)).foregroundStyle(OVColor.rust)
            }
            Spacer(minLength: OVSpacing.sm)
            VStack(alignment: .trailing, spacing: 6) {
                // forestText, never forest: the brand green is a FILL token and measures 2.53 to 1 as
                // dark-theme text (ForestTextColourTests, #2264, L149).
                Button(StalledReplyDraftCopy.tryAgain) { draftAgain(prospect: p, recipient: r) }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forestText)
                Button("View in Archive") { onOpenInArchive(p.naturalKey, r.id) }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            }
        }
        .padding(.vertical, OVSpacing.xs)
        .padding(.horizontal, OVSpacing.xs)
        .id(r.id)
    }

    // The scoped drafter (#2129, consolidated as the one draftReply in #2944), so pressing this spends
    // on the one conversation Dan pressed it on rather than on every reply waiting. Re-stamping the
    // request is what takes this row out of the stalled list: it is no longer a dead run, it is a run
    // that has just started.
    private func draftAgain(prospect: Prospect, recipient: Recipient) {
        ProspectMutations.draftReply(prospect.naturalKey, recipient.id, prospects: prospects,
                                     context: context, feedback: feedback)
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
