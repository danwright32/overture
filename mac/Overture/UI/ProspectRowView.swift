import SwiftUI

// One editorial "call sheet" entry. High-fit prospects carry a gold edge; the fit
// score reads like a grade. Keep and Dismiss act on the local store directly.
struct ProspectRowView: View {
    // #1533: the genre editor, opened from the genre line in the header.
    @State private var showGenreEditor = false
    // #1274: the manual-rename sheet and its in-progress text.
    @State private var showingRename = false
    @State private var renameDraft = ""
    // #2007: the write-it-yourself editor.
    @State private var showingManualPrep = false

    let item: QueueItem
    let today: String
    let onKeep: () -> Void
    let onDismiss: (ShowOutcome) -> Void
    var onUnapprove: () -> Void = {}
    var onSkipDraft: () -> Void = {}
    // #367
    var onReprep: (_ mode: ReprepMode) -> Void = { _ in }
    // #2007: Dan prepped this show by hand, and what he wrote.
    var onPrepManually: (_ email: String, _ name: String?, _ subject: String, _ body: String, _ sendsTogether: Bool) -> Void = { _, _, _, _, _ in }
    // #2007: what the editor already knows about who to send to. A closure, so a card that is merely
    // OFFERING the control pays nothing: nothing is looked up until the sheet opens.
    var manualPrepPrefill: () -> ManualPrepPrefill.Result = {
        ManualPrepPrefill.Result(filled: nil, suggestions: [], emptyReason: .nothingFound)
    }
    var onSaveDraft: (_ subject: String, _ body: String) -> Void = { _, _ in }
    // #2010: Dan's own opening for one contact, passed through to the draft review screen.
    var onSaveOpening: (_ recipientId: String, _ opening: String) -> Void = { _, _ in }
    var onSaveJointOpening: (_ opening: String) -> Void = { _ in }   // #2033
    var onSetSendsTogether: (_ together: Bool) -> Void = { _ in }   // #2034
    var onSetLostReason: (String) -> Void = { _ in }
    var onSend: () -> Void = {}
    var onOverrideSalutationReview: () -> Void = {}
    var onOverrideDraftLint: () -> Void = {}
    var onDismissReply: () -> Void = {}
    // #1752: Dan says where this card's ROOM is. Optional rather than a no-op default, because the
    // control is only drawn where something is wired to handle it: a link that silently does nothing is
    // worse than no link, and the queue is not the only surface that renders this row.
    var onNameRoom: ((_ venue: String, _ location: String) -> Void)?
    // #1630: the copy-then-confirm control for a form-only show.
    var onBeginFormPitch: (_ recipientId: String, _ formURL: String) -> Void = { _, _ in }
    var onRecordFormPitch: (_ recipientId: String) -> Void = { _ in }
    var onCancelFormPitch: (_ recipientId: String) -> Void = { _ in }
    var onMarkContact: (_ recipientId: String, _ resolution: RecipientResolution?, _ bounced: Bool) -> Void = { _, _, _ in }
    // #2395: the show reached an ending. One callback for all five, because they are one vocabulary and
    // one write (ProspectMutations.recordOutcome), not five buttons each doing their own thing.
    var onRecordOutcome: (ShowOutcome) -> Void = { _ in }
    var onReopenOutcome: () -> Void = {}
    var onSetRecipientConversationState: (_ recipientId: String, _ state: ConversationState) -> Void = { _, _ in }
    var onConfirmRecipientConversationState: (_ recipientId: String) -> Void = { _ in }
    var onAddRecipient: (_ email: String, _ name: String?) -> Void = { _, _ in }
    var onRemoveRecipient: (_ recipientId: String) -> Void = { _ in }
    // #2392: an address struck on the TRIAGE card, before the show is prepped. It takes the whole
    // address rather than a recipient id because the two kinds are removed by different routes: one has a
    // Recipient row on this show, the other is printed from the organisation's own answer and has none.
    var onRemoveContactAddress: (_ address: QueueItem.DisplayedAddress) -> Void = { _ in }
    var onDismissContactReply: (_ recipientId: String) -> Void = { _ in }
    var onDismissContactBounce: (_ recipientId: String) -> Void = { _ in }
    var onDismissVenueMatch: (_ recipientId: String) -> Void = { _ in }
    var onDismissPressContactMatch: (_ recipientId: String) -> Void = { _ in }
    var onDismissDuplicateContactMatch: (_ recipientId: String) -> Void = { _ in }
    var onDraftReply: (_ recipientId: String) -> Void = { _ in }
    var onSendReply: (_ recipientId: String) -> Void = { _ in }
    var onCopyReply: (_ recipientId: String) -> Void = { _ in }
    var onEditReplyDraft: (_ recipientId: String, _ body: String) -> Void = { _, _ in }
    var onCancelReplyDraft: () -> Void = {}   // #1038: stop the detached reply-classify + drafter run
    var onCorrectClassification: (Discipline) -> Void = { _ in }
    var onRename: (String) -> Void = { _ in }   // #1274: Dan renames a scout-generated name
    var onResetGroupName: () -> Void = {}        // #1274: hand the name back to the scout
    // #2261: Dan asks for this show's frozen reachability answer to be researched again.
    // #2267: the press now RUNS it, so the call site raises the spend confirmation and starts the check.
    var onRequestRecheck: () -> Void = {}
    // #2267: whether ANY detached run holds the single slot (a probe or a Prep share it, #1323), so the
    // control greys out instead of failing after the press. Handed in like `gmailConnected` rather than
    // read here: it is one fact about the app, identical for every row, and reading it per card is the
    // #1770 defect.
    var prepRunning: Bool = false
    // #2267: whether a reachability check specifically is in flight. Separate from the line above because
    // a Prep run occupying the slot must grey the control WITHOUT making the card claim its own check is
    // under way, which would be a running label over work that is not happening.
    var probeRunning: Bool = false
    var onConfirmBooking: () -> Void = {}
    var onDismissBookingSuggestion: () -> Void = {}
    var onRejectBooking: () -> Void = {}
    // #611: dismisses the "already has its own photographer" fit-risk flag as a false positive.
    var onDismissAlreadyCoveredFlag: () -> Void = {}
    var onClearConflict: () -> Void = {}   // #901: "I can shoot this anyway"
    // #769: Dan marks (or releases) the whole ORG as do-not-contact, not just this show.
    var onSetOrgDoNotContact: (Bool) -> Void = { _ in }
    // #753: Dan's verdict on a performer match. Confirming unlocks the warm drafting tone; rejecting
    // reverts the score to exactly what the scout had (#752).
    var onConfirmPerformerMatch: () -> Void = {}
    var onDismissPerformerMatch: () -> Void = {}
    // Only ever passed non nil by Archive (the Queue never shows a dismissed prospect), so
    // this has zero effect on any existing Queue row.
    var onRestore: (() -> Void)? = nil
    var gmailConnected: Bool = false
    // #436: in-flight send timestamps so the row shows a live "Sending…" state (see DraftReviewView).
    var outboundSendSince: Date? = nil
    var replySendSince: (_ recipientId: String) -> Date? = { _ in nil }
    // #685: which contact, if any, to highlight inside this card's Contacts section.
    var highlightedRecipientId: String? = nil
    // #992: the "Too far" filter is engaged, so a revealed row shows WHY it was placed out of range.
    // Off by default (Archive and the normal queue never show this line).
    var showingTooFar: Bool = false
    // #991: Dan's stored town refusals, so the too-far reason line reads the union (seed + his refusals),
    // and the Dismiss menu can offer to add this row's town.
    var userExcludedTowns: Set<String> = []
    var allowedSeedTowns: Set<String> = []
    var onExcludeTown: () -> Void = {}
    // #1719: the producer/house correction. Takes the standing Dan wants in force, so the same callback
    // serves the correction and its undo.
    var onCorrectProducer: (ProducerOverrideEditing.Standing) -> Void = { _ in }

    private var timing: QueueModel.Timing {
        QueueModel.displayTiming(performanceDate: item.performanceDate, runEndDate: item.runEndDate,
                                 today: today, isBooked: item.isBooked)
    }

    // A booking (confirmed or suggested) owns the forest FILL + border, so the best-contact highlight below
    // defers to it rather than competing on the same colour.
    private var isBookingHighlighted: Bool { item.bookingSuggested || item.isBooked }

    // #1648: the reachability accent bar and tint that used to live here are GONE. The card carried two
    // competing signals (a gold outline for a high fit, a forest bar for a found contact), so reading a
    // date meant decoding two schemes at once and a fit-0 show could look more prominent than a fit-9
    // one. Reachability now feeds the SCORE instead, so the one outline says everything and the signal
    // survives sorting and filtering, which a border never did.

    private var rowFill: Color {
        if isBookingHighlighted { return OVColor.forest.opacity(0.12) }
        return OVColor.surface
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            HStack(alignment: .top, spacing: OVSpacing.md) {
                if item.isBooked { bookedSeal } else { fitSeal }
                VStack(alignment: .leading, spacing: OVSpacing.xs) {
                    header
                    showSummaryNote
                    tooFarReasonNote
                    feedStatusFlag
                    if !item.fitReason.isEmpty && !item.classificationOverriddenByDan {
                        Text(item.fitReason)
                            .font(OVType.reason)
                            .foregroundStyle(OVColor.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)   // #340: let the caveat breathe instead of crowding the metadata
                    }
                    tags
                    possibleMatchQuestion
                    relatedRunNote
                    linkedEngagementNote
                    orgDoNotContactFlag
                    bookingSuggestionFlag
                    alreadyCoveredFlag
                    performerMatchFlag
                    autoBookedTag
                    links
                }
                Spacer(minLength: OVSpacing.sm)
                actions
            }
            if item.hasDraft {
                DraftReviewView(
                    item: item,
                    onUnapprove: onUnapprove,
                    onSkip: onSkipDraft,
                    onReprep: onReprep,
                    onSaveDraft: onSaveDraft,
                    onSaveOpening: onSaveOpening,
                    onSaveJointOpening: onSaveJointOpening,
                    onSetSendsTogether: onSetSendsTogether,
                    onSetLostReason: onSetLostReason,
                    onSend: onSend,
                    onOverrideSalutationReview: onOverrideSalutationReview,
                    onOverrideDraftLint: onOverrideDraftLint,
                    onDismissReply: onDismissReply,
                    onBeginFormPitch: onBeginFormPitch,
                    onRecordFormPitch: onRecordFormPitch,
                    onCancelFormPitch: onCancelFormPitch,
                    onMarkContact: onMarkContact,
                    onRecordOutcome: onRecordOutcome,
                    onReopenOutcome: onReopenOutcome,
                    onSetOrgDoNotContact: onSetOrgDoNotContact,
                    onSetRecipientConversationState: onSetRecipientConversationState,
                    onConfirmRecipientConversationState: onConfirmRecipientConversationState,
                    onDismissContactReply: onDismissContactReply,
                    onDismissContactBounce: onDismissContactBounce,
                    onDismissVenueMatch: onDismissVenueMatch,
                    onDismissPressContactMatch: onDismissPressContactMatch,
                    onDismissDuplicateContactMatch: onDismissDuplicateContactMatch,
                    onAddRecipient: onAddRecipient,
                    onRemoveRecipient: onRemoveRecipient,
                    onDraftReply: onDraftReply,
                    onSendReply: onSendReply,
                    onCopyReply: onCopyReply,
                    onEditReplyDraft: onEditReplyDraft,
                    onCancelReplyDraft: onCancelReplyDraft,
                    gmailConnected: gmailConnected,
                    outboundSendSince: outboundSendSince,
                    replySendSince: replySendSince,
                    highlightedRecipientId: highlightedRecipientId
                )
                .padding(.leading, 64 + OVSpacing.md)
            }
        }
        .padding(OVSpacing.md)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(rowFill)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    item.bookingSuggested || item.isBooked ? OVColor.forest.opacity(0.9)
                        : item.isHighFit ? OVColor.gold.opacity(0.45)
                        : OVColor.line,
                    lineWidth: item.bookingSuggested || item.isBooked ? 2 : 1)
        )
        .sheet(isPresented: $showingRename) { renameSheet }
        // #2007: the prefill is looked up HERE, inside the presentation closure, not on the card. It walks
        // every prospect and reads the booking-history file, and a queue is hundreds of cards, so a card
        // merely OFFERING the control must pay nothing (`ManualPrepOnScreenTests` holds that).
        .sheet(isPresented: $showingManualPrep) {
            ManualPrepSheet(groupName: item.groupName, prefill: manualPrepPrefill(),
                            onSave: onPrepManually)
        }
    }

    // #1274: the manual-rename sheet. Save commits Dan's name (empty input is ignored by the mutation);
    // "Reset to scout name" only appears once he has actually renamed it, so the scout owns the name again.
    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            Text("Rename show")
                .font(OVType.groupName)
                .foregroundStyle(OVColor.ink)
            Text("Replaces the scout's name on this row. Your name stays put across future scouts.")
                .font(OVType.body)
                .foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Show name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitRename)
            HStack {
                if item.groupNameOverriddenByDan {
                    Button("Reset to scout name") {
                        onResetGroupName()
                        showingRename = false
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(OVColor.inkSoft)
                }
                Spacer()
                Button("Cancel") { showingRename = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commitRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(OVSpacing.lg)
        .frame(width: 380)
    }

    private func commitRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRename(trimmed)
        showingRename = false
    }

    private var fitSeal: some View {
        VStack(spacing: 2) {
            Text("\(item.fitScore)")
                .font(OVType.fitNumber)
                .foregroundStyle(item.isHighFit ? OVColor.gold : OVColor.inkFaint)
            Text(QueueModel.fitLabel(isHighFit: item.isHighFit))
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(item.isHighFit ? OVColor.gold : OVColor.inkFaint)
        }
        .frame(width: 64)
        .padding(.top, 2)
    }

    // Replaces the fit seal once a prospect is booked, so the row reads unmistakably as done
    // rather than as a lead to pitch (#198).
    private var bookedSeal: some View {
        VStack(spacing: 3) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 22))
                .foregroundStyle(OVColor.forest)
            Text("BOOKED")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(OVColor.forest)
        }
        .frame(width: 64)
        .padding(.top, 2)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            // #1533: the genre the scout read, and the place to fix it when it read wrong. The amber
            // unsure-classification badge that used to host the editor is gone (it claimed to be unsure
            // of a genre it had never measured, and asked for a production type Dan does not research),
            // so the correction moved onto the line that STATES the genre. Same shape as the #1274 rename
            // pencil two lines below: a quiet correction to a scout-owned field, which then survives
            // every later scout. Nothing prompts; the row only answers when Dan disagrees.
            // #1742: and it now LOOKS like the place to fix it. "Quiet" was implemented as invisible:
            // gold, tracked, all-caps text with a tooltip renders identically to every other section
            // caption in this app, so the row could not answer when Dan disagreed, because nothing told
            // him there was anything to ask. He reported the missing feature from a screenshot while
            // looking at it. The chevron sits after the word AT REST, not on hover: a hover cue does not
            // exist in a screenshot, or to anyone scanning the queue without moving the mouse.
            Button {
                showGenreEditor = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(QueueModel.disciplineLabel(item.discipline).uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(OVColor.gold)
                    // Faint rather than gold, in the register of the title's rename pencil: gold is
                    // reserved for what Dan can act on, and the genre WORD is the thing he reads.
                    Image(systemName: GenreControlCopy.icon)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(OVColor.inkFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(GenreControlCopy.help)
            .accessibilityLabel(GenreControlCopy.accessibilityLabel(for: item.discipline))
            .popover(isPresented: $showGenreEditor) { genreEditorPopover }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.groupName)
                    .font(OVType.groupName)
                    .foregroundStyle(item.disappearedFromFeed ? OVColor.inkFaint : OVColor.ink)
                    .strikethrough(item.disappearedFromFeed, color: OVColor.rust)
                // #1274: a subtle pencil to rename an awkward scout-generated name. Opens a sheet
                // prefilled with the current name; Dan's edit then survives every future scout.
                Button {
                    renameDraft = item.groupName
                    showingRename = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OVColor.inkFaint)
                }
                .buttonStyle(.plain)
                .help("Rename this show")
            }
            // #1687: who is playing, between the title (the what) and the venue (the where). Dan's
            // placement, 2026-07-29. Deliberately bare, no "presented by" label wrapped around it: he
            // chose the name alone. Whether it appears at all is decided in QueueModel (tested), because
            // showing it unconditionally would name the room on half the queue.
            if let presenterLine = item.presenterLine {
                Text(presenterLine)
                    .font(OVType.body)
                    .foregroundStyle(OVColor.inkSoft)
            }
            // #1823: nothing is said here about a show whose listing named no organiser. #1788 put a line
            // in this slot to send Dan looking for a company the listing had not named; #1861 removed that
            // errand by pursuing every performer such a bill names, so the line changed nothing he or the
            // system did, while sitting directly under the line naming the act (#843's exact shape).
            // #1731: and where Overture's own verdict is what withheld the name, say that here too, in the
            // slot the name would have used. Dan asks "why is no presenter named?" while looking at this
            // card, so answering it on a separate sheet meant the answer never met the question.
            if let readAsBuilding = item.readAsTheBuildingNote {
                Text(readAsBuilding)
                    .font(OVType.body)
                    .foregroundStyle(OVColor.inkSoft)
            }
            // #340: give the metadata a calmer hierarchy instead of cramming venue, timing and date
            // onto one dot-separated line. Venue is the "where" on its own line; the "when" (date plus
            // the relative timing cue) sits beneath it, smaller and de-emphasized, with the timing
            // keeping its urgency colour.
            // #342: when the venue is a known hall, show its parent building inline ("…, Carnegie Hall")
            // and the city/state as a fainter line beneath, so any venue is locatable at a glance.
            let venueInfo = VenueDisplay.resolve(item.venue, location: item.location)
            Text(venueInfo.nameLine)
                .font(OVType.body)
                .foregroundStyle(OVColor.inkSoft)
            // #1744: a show whose place is not known says so, instead of rendering exactly like one whose
            // city was simply left off the card. Those were the same screen before, which is why a
            // Dominican Republic show and a Manhattan show sat in the queue looking identical (L11), and
            // it is why Dan went looking for a town refusal on a row that could never offer one.
            //
            // Rare by design, and only worth a line because it is rare: measured against the live store
            // 2026-07-29, the fill places 341 of the 342 rows that used to look like this.
            if let placeLine = venueInfo.locationLine {
                // #1752: when the city could not be established, the line carries the way to fix it. A
                // notice that names the room and then classifies itself as informational tells Dan
                // exactly what is wrong and gives him nowhere to go (L80). The answer is about the ROOM,
                // so it reaches every show played there rather than only this card.
                if placeLine.isUnknown, let room = item.venue, let onNameRoom {
                    HStack(spacing: OVSpacing.xs) {
                        Text(placeLine.text)
                            .font(OVType.meta.weight(.regular))
                            .foregroundStyle(OVColor.inkSoft)
                        NameRoomControl(room: room) { onNameRoom(room, $0) }
                    }
                } else {
                    Text(placeLine.text)
                        .font(OVType.meta.weight(.regular))
                        .foregroundStyle(placeLine.isUnknown ? OVColor.inkSoft : OVColor.inkFaint)
                }
            }
            HStack(spacing: 6) {
                Text(QueueModel.runDateLabel(start: item.performanceDate, end: item.runEndDate))
                    .foregroundStyle(OVColor.inkFaint)
                // #1699: the curtain time, when the source published one. Most sources do not, and those
                // cards render byte-for-byte as they did before this: no separator, no placeholder.
                // Dan's call from the rendered options (2026-08-02): the SAME weight as the date beside
                // it, so it reads as part of the when rather than competing with it.
                if let startTime = QueueModel.cardStartTime(startTimes: item.performanceStartTimes,
                                                            timesVary: item.startTimesVary) {
                    Text("·").foregroundStyle(OVColor.lineStrong)
                    // #1699: when the nights differ, the summary carries the real schedule on hover
                    // (Dan's call, 2026-08-02), because "Times vary" is the MAJORITY of timed cards and
                    // on its own it answers nothing he needs.
                    //
                    // The tooltip is ATTACHED only when there is something to say, rather than handing
                    // `help` an empty string and trusting macOS to render nothing from it. A card with a
                    // single plain time is the common case and must not grow an empty hover box on the
                    // strength of an assumption about framework behaviour that nothing here can test.
                    if let nightTimes = QueueModel.nightTimesTooltip(item.nightStartTimes) {
                        Text(startTime).foregroundStyle(OVColor.inkFaint).help(nightTimes)
                    } else {
                        Text(startTime).foregroundStyle(OVColor.inkFaint)
                    }
                }
                // #843: on a booked row the seal already says "BOOKED", so the timing token would repeat
                // it. The decision lives in the model, tested, not in this ternary.
                if QueueModel.headerShowsTimingLine(isBooked: item.isBooked) {
                    Text("·").foregroundStyle(OVColor.lineStrong)
                    Text(timing.label)
                        // #1122: an underway run reads with the act-now colour too, not the faint
                        // "plenty of time" grey, since its remaining window is by definition short.
                        .foregroundStyle(timing.urgency == .imminent || timing.urgency == .underway ? OVColor.rust
                                         : timing.urgency == .booked ? OVColor.forest : OVColor.inkFaint)
                }
            }
            .font(OVType.meta.weight(.regular))
        }
    }

    // Shown only on a prospect Dan was pursuing that has since vanished from the feed (#133):
    // a struck-through title plus this note, so a cancelled/pulled show he kept isn't mistaken
    // for still happening. Untouched ones are filtered out of the queue entirely.
    @ViewBuilder private var feedStatusFlag: some View {
        if item.disappearedFromFeed {
            HStack(spacing: 5) {
                Image(systemName: "calendar.badge.exclamationmark")
                Text("No longer in the feed, may be cancelled")
            }
            .ovPill(.warning)
            .padding(.top, 2)
            .help("This show was in an earlier scout but has dropped out of the venue feed across the last two scouts, so it was likely cancelled or pulled. Your keep/dismiss history is preserved.")
        }
    }

    // #992: shown only while the "Too far" filter is engaged, and only on a row the gate positively
    // placed out of range. Sits right under the location line it explains. The sentence is decided in
    // QueueModel (tested); this view only draws it.
    @ViewBuilder private var tooFarReasonNote: some View {
        if showingTooFar, let reason = item.tooFarReason(userExcludedTowns: userExcludedTowns,
                                                         allowedSeedTowns: allowedSeedTowns) {
            HStack(spacing: 5) {
                Image(systemName: "location.slash")
                Text(reason)
            }
            .font(OVType.tag)
            .foregroundStyle(OVColor.inkSoft)
            .padding(.top, 2)
        }
    }

    // #1824: what the Prep run found this show actually IS, read off the show's own listing page. It sits
    // directly under the header because it is a fact about the SHOW (the name, room and date above it say
    // who and where, and never what), ahead of the fit reason, which is about something else entirely.
    //
    // When there is no summary it says why instead, and only when the run gave a reason: every draft
    // written before this existed has none, and a line on all of those would assert something nobody
    // measured.
    @ViewBuilder private var showSummaryNote: some View {
        if let line = ShowSummaryCopy.line(summary: item.showSummary, absence: item.showSummaryAbsence) {
            Text(line)
                .font(OVType.tag)
                .foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    // #2080: the card used to carry what the pitch was about to claim about this room, and the nights
    // behind it (#1887). Dan, on 2026-08-04: "i don't need to know what the pitch will say in the scout
    // queue. we should remove that." The verification moment it existed for now lives in the draft
    // itself, which he reads before every send, so a wrong venue history claim is still caught, one step
    // later and by the only reader whose judgment the claim depends on.

    @ViewBuilder private var relatedRunNote: some View {
        if let note = QueueModel.relatedRunNote(item) {
            Text(note)
                .font(OVType.tag)
                .foregroundStyle(OVColor.inkSoft)
                .padding(.top, 2)
        }
    }

    // #939: distinct from relatedRunNote above (same venue, a separate run).
    @ViewBuilder private var linkedEngagementNote: some View {
        if let note = QueueModel.linkedEngagementNote(item) {
            Text(note)
                .font(OVType.tag)
                .foregroundStyle(OVColor.inkSoft)
                .padding(.top, 2)
        }
    }

    // #1929: the possible-match question, on its own line rather than in the pill row. It ends in a
    // show's name, so it is as long as that name is, and a pill cannot wrap inside itself. Gold,
    // because it is still the "you may know these people" signal the pills carry, and it is a question
    // Dan can answer.
    @ViewBuilder private var possibleMatchQuestion: some View {
        if let question = QueueModel.possibleMatchQuestion(item) {
            Text(question)
                .font(OVType.tag)
                .foregroundStyle(OVColor.gold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    @ViewBuilder private var tags: some View {
        let history = QueueModel.historyFlag(item)
        FlowTags(tags: [
            QueueModel.productionLabel(item.production).map { Tag(text: $0, tone: item.production == "self" ? .good : .warn) },
            QueueModel.coverageLabel(item.coverage).map { Tag(text: $0, tone: item.coverage == "likely_uncovered" ? .good : .warn) },
            history.map { Tag(text: $0, tone: .history) },
            // #596: surface at a glance when more than one recipient was found (e.g. 2 named
            // performers, #366), so Dan doesn't have to expand the row to notice.
            item.contactCountLabel.map { Tag(text: $0, tone: .info) },
            // #879/#1136: which model wrote this draft, so the Archive can compare landed emails against
            // ones that didn't by model. Via rowDraftTraceLabel, which shows it ONLY once the draft-review
            // panel is gone (no draft body): while the panel renders it shows the same line next to
            // "Edited" (#846), so a row badge there would state it twice (#1136). This is the durable tag
            // that survives after the panel stops rendering.
            item.rowDraftTraceLabel.map { Tag(text: $0, tone: .info) },
        ].compactMap { $0 })
        .padding(.top, 2)
    }


    // #1145/#1308: the reachability note read on Scout, where keep or dismiss is decided (#1586), so Dan
    // doesn't dismiss a reachable show in favour of one he can't email. It stays on the card through the
    // later stages, but Scout is the moment it is FOR.
    // Before a probe it is the calm, advisory Layer 1 "Hard to reach" heuristic;
    // after a probe it is the firm "Email found" (forest) or "No email found" (rust). A decision aid, never
    // a gate. The decision lives in the model (item.reachabilityBadge), tested; this only renders it.
    @ViewBuilder private var reachabilityFlag: some View {
        switch item.reachabilityBadge() {
        case .none:
            EmptyView()
        case .hardToReach:
            reachabilityNote(icon: "envelope", text: ReachabilityCopy.hardToReachBadge,
                             tone: Reachability.tone(for: .hardToReach), help: ReachabilityCopy.hardToReachHelp)
        case .noEmailFound:
            // #1722: same badge, same rust tone, same icon. Only the SENTENCE varies, so a check that
            // found the room's own address and refused it stops reporting that it found nothing. With no
            // reason recorded this is byte-identical to what it always said.
            reachabilityNote(icon: "envelope.badge",
                             text: ReachabilityCopy.emptyAnswerBadge(item.reachabilityEmptyReason),
                             tone: Reachability.tone(for: .noEmailFound),
                             help: ReachabilityCopy.emptyAnswerHelp(item.reachabilityEmptyReason))
        case .weakContactOnly:
            // #1324: gold, the caution between the rust "none" and the forest "found": an address exists,
            // but only a weak (venue/press) one.
            reachabilityNote(icon: "envelope.badge",
                             text: ReachabilityCopy.weakContactBadge(
                                reason: item.weakContactHoldReason ?? .venueOrPress),
                             tone: Reachability.tone(for: .weakContactOnly),
                             // #1798: the sentence names the hold this row actually has. Decided on the
                             // model (testable), never re-derived here.
                             help: ReachabilityCopy.weakContactHelp(
                                reason: item.weakContactHoldReason ?? .venueOrPress))
        case .contactFormOnly:
            // #1626: gold, which Dan reserves for what he can act on. There IS a way through here; it
            // just costs him a few minutes at their site instead of a send.
            reachabilityNote(icon: "square.and.pencil", text: ReachabilityCopy.contactFormOnlyBadge,
                             tone: Reachability.tone(for: .contactFormOnly), help: ReachabilityCopy.contactFormOnlyHelp)
        case .staleProbe:
            // #1325: a clock icon in the calm ink tone: advisory, not alarming. The earlier firm result
            // has aged out, so it asks for a re-check rather than asserting reachable or not.
            reachabilityNote(icon: "clock.arrow.circlepath", text: ReachabilityCopy.staleProbeBadge,
                             tone: Reachability.tone(for: .staleProbe), help: ReachabilityCopy.staleProbeHelp)
        case .checkMissedIt:
            // #1724: a plain question mark in the same calm tone as a stale result. Both mean "no current
            // answer here"; neither is a finding. Deliberately NOT the rust envelope of "No email found",
            // which this row would be misreporting as a search that finished, and not the envelope family
            // at all: no address was ever in question here, because nothing looked for one.
            reachabilityNote(icon: "questionmark.circle", text: ReachabilityCopy.checkMissedItBadge,
                             tone: Reachability.tone(for: .checkMissedIt), help: ReachabilityCopy.checkMissedItHelp)
        case .emailFound:
            // #1598 Phase 5: an answer inherited from another show by the same organisation looks exactly
            // like one paid for here, Dan's call. The ONLY difference is the hover text, which says where
            // it came from, so the card never quietly implies this particular show was researched.
            // #1628, Dan's call 2026-07-28: when NOTHING found was verified, the badge says so itself
            // rather than a caveat printed beside every address. One verified contact is enough to keep
            // the plain wording, so a weaker sibling beside it never raises a warning.
            reachabilityNote(icon: "envelope.open",
                             text: item.onlyUnverifiedEmailsFound
                                 ? ReachabilityCopy.unverifiedEmailFoundBadge
                                 : ReachabilityCopy.emailFoundBadge,
                             tone: Reachability.tone(for: .emailFound,
                                                     onlyUnverified: item.onlyUnverifiedEmailsFound),
                             // The hover has to follow the WORDING. When the badge says nothing found
                             // was verified, the explanation must say what that means; leaving the plain
                             // "a check found a contact you can email" there explains the wrong thing.
                             help: item.onlyUnverifiedEmailsFound
                                 ? ReachabilityCopy.unverifiedEmailFoundHelp
                                 : item.inheritedReachability.map {
                                     ReachabilityCopy.inheritedEmailFoundHelp(organisation: $0.organisation)
                                 } ?? ReachabilityCopy.emailFoundHelp)
        }
    }

    // #1597 follow-up (Dan's walk of the Debug build): the badge says an address exists but never which
    // one, and that is the thing he actually needs while triaging. "info@thevenue.com" and
    // "anna@annapierre.com" wear the same badge and are completely different decisions.
    //
    // ALL of them, his call, including the weak ones: on a self-produced show two named performers may
    // both have been found, and showing only the first silently hides the second, which is exactly the
    // case where finding both was the hard part (#366). Weak addresses show too, because seeing that the
    // only thing found was the venue front desk is what makes that verdict legible instead of something
    // he has to take on trust.
    //
    // Styled as the row's meta line (the city and date), his spec, so it reads as a quiet fact about the
    // show rather than as another control competing with Keep and Dismiss.
    @ViewBuilder private var reachabilityAddresses: some View {
        // #1598 Phase 5: which addresses (this show's own, or the organisation's when it has none) is a
        // rule, not a rendering detail, so it lives on the item where a test can reach it.
        let emails = item.displayedContactEmails
        if !emails.isEmpty {
            // #1628: this column prints the addresses and NOTHING else. A per-address "not verified"
            // caveat lived here briefly and went through three layouts (trailing the address, leading it,
            // then its own grid column); every one broke the column, the last by squeezing it until long
            // addresses wrapped. Dan's call, 2026-07-28: the caveat belongs in the badge above, said once,
            // and this line goes back to being a plain right-justified list of addresses.
            VStack(alignment: .trailing, spacing: 1) {
                ForEach(item.displayedContactAddresses) { address in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        // #2392: the strike, before the prep run. The same xmark.circle the draft-review
                        // panel uses for a still-pending contact (ContactRowControls), so removing an
                        // address means the same thing and looks the same wherever Dan meets it.
                        //
                        // Visible at rest, not on hover: an interactive element styled like static text
                        // ships as an invisible feature (L49), and this one exists precisely because he
                        // was looking straight at the addresses with nothing to do about them.
                        // Withheld once this address has been written to, or once the show is resolved:
                        // the same rule the review panel's own leading X follows, decided in
                        // ContactRowControls so the two surfaces cannot drift into offering one action
                        // at two different levels of exposure.
                        if ContactRowControls.strikeIsOffered(
                            sendState: address.sendState,
                            showIsResolved: item.sentAt != nil || item.isBooked) {
                            Button { onRemoveContactAddress(address) } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(OVColor.inkFaint)
                            }
                            .buttonStyle(.plain)
                            .help(ReachabilityCopy.removeAddressHelp)
                            .accessibilityLabel(ReachabilityCopy.removeAddressLabel(address.email))
                        }
                        Text(address.email)
                            .font(OVType.meta)
                            .foregroundStyle(OVColor.inkSoft)
                            .textSelection(.enabled)
                            // Wrap rather than truncate: an address Dan cannot read in full is no better
                            // than no address, and this column is narrow.
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        } else {
            // #1626: no address, but a form on the act's own site. The link goes exactly where the
            // address would have gone, because it answers the same question ("how do I reach them"),
            // and it is a real link so Dan can go straight there rather than copying a name into a
            // search box.
            // Labelled with the SITE, not with the words "contact form": the pill directly above already
            // says that, and what Dan needs from this line is the same thing the address line gives him,
            // WHO he would be writing to. "jakebergmagic.com" and "shop.copeland.band" are different
            // decisions in the way "info@thevenue.com" and "anna@annapierre.com" are.
            // #1628: no caveat here either. Every contact form is unverified by definition (the runbook
            // maps form-or-DM to low confidence unconditionally), so a warning on all of them would say
            // nothing the "Contact form only" pill above does not already say.
            ForEach(item.displayedContactForms, id: \.self) { url in
                Link(destination: url) {
                    Text(QueueModel.contactFormSiteLabel(url))
                        .underline()
                }
                .font(OVType.meta)
                .foregroundStyle(OVColor.forest)
                .multilineTextAlignment(.trailing)
            }
        }
    }

    private func reachabilityNote(icon: String, text: String, tone: OVPillTone, help: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(text)
        }
        .ovPill(tone)
        .help(help)
        .padding(.top, 2)
    }

    // A possible booking that needs Dan's explicit sign-off before it locks (#114).
    // Gold tone (positive, not a warning), the capsule idiom the row's other flags share.
    @ViewBuilder private var bookingSuggestionFlag: some View {
        if item.bookingSuggested {
            Menu {
                Button("Confirm booking") { onConfirmBooking() }
                Button("Not a booking") { onDismissBookingSuggestion() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Possible booking, confirm?")
                }
                .ovPill(.pending)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("A booking was detected that needs your confirmation. Tap to confirm or dismiss.")
            .padding(.top, 2)
        }
    }

    // #611: a fit-risk Prep's own research found, e.g. the org's site names its own photographer.
    // Rust tone (a caution, not an opportunity), mirroring bookingSuggestionFlag's capsule idiom.
    // Never changes fitScore/tier; Dan decides himself whether to deprioritize or skip.
    @ViewBuilder private var alreadyCoveredFlag: some View {
        if let note = item.alreadyCoveredNote, !item.alreadyCoveredDismissed {
            Menu {
                Button("Not actually covered") { onDismissAlreadyCoveredFlag() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(note)
                }
                .ovPill(.warning)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Prep's research found this show may already have its own photographer. Tap if that's wrong.")
            .padding(.top, 2)
        }
    }

    // #769: this org asked Dan to stop emailing them. The most consequential state a row can carry, so
    // it is stated plainly rather than tucked into a menu, and it stays releasable: a mis-click here
    // must not silently cost him an org forever.
    @ViewBuilder private var orgDoNotContactFlag: some View {
        if item.orgDoNotContact {
            Menu {
                Button("Allow contact again") { onSetOrgDoNotContact(false) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "hand.raised.fill")
                    Text("Do not contact")
                }
                .ovPill(.warning)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("This org asked not to be contacted, so none of their shows will be scouted or emailed. Tap to allow contact again.")
            .padding(.top, 2)
        }
    }

    // #753: Prep matched this show's PERFORMER (not its org) to someone Dan has already shot, and
    // warmed the lead accordingly (#585). Unlike alreadyCoveredFlag, this one has ALREADY moved
    // fitScore/tier, so the row must be able to both explain the change and take it back.
    //
    // Two states, because an unconfirmed match is deliberately half-trusted (#752): it ranks the lead
    // warm right away (reversible, useful) but is held back from the drafting tone until Dan says it
    // is right (irreversible once an email goes out). So an unreviewed match ASKS in gold, the same
    // "needs your sign-off" idiom as bookingSuggestionFlag, and a confirmed one simply STATES in
    // forest, while still offering the reject action in case he changes his mind.
    @ViewBuilder private var performerMatchFlag: some View {
        if let note = item.performerMatchNote,
           item.relationshipCorrectedByPerformerMatch,
           !item.performerMatchDismissed {
            let confirmed = item.performerMatchReviewed
            Menu {
                if !confirmed { Button("Looks right") { onConfirmPerformerMatch() } }
                Button("Wrong match") { onDismissPerformerMatch() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: confirmed
                          ? "person.crop.circle.badge.checkmark"
                          : "person.crop.circle.badge.questionmark")
                    Text(note)
                }
                .ovPill(confirmed ? .confirmed : .pending)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(QueueModel.performerMatchHelp(confirmed: confirmed))
            .padding(.top, 2)
        }
    }

    // Shown only on an auto-detected booking Dan hasn't confirmed yet (#114/#201): it names the
    // source AND lets him confirm. Confirming flips it to a Dan-owned booking, which moves it out
    // of the reach-out queue. Hidden for bookings Dan set himself.
    @ViewBuilder private var autoBookedTag: some View {
        if item.isAutoBooked {
            Menu {
                Button("Confirm booking") { onConfirmBooking() }
                Button("Not a booking") { onRejectBooking() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal")
                    Text("Auto-detected booking, confirm?")
                }
                .ovPill(.confirmed)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("This booking was auto-detected from Downbeat. Confirm it (it then moves out of the reach-out list), or reject a wrong match to pull it back out.")
            .padding(.top, 2)
        }
    }

    // #1600 Phase 7.2 / #1534: the strip draws only when it has something in it. Both of the status
    // lines that used to sit in here beside the links are retired, so the 145 untriaged rows carrying
    // neither link would otherwise draw an empty padded row.
    @ViewBuilder private var links: some View {
        let refs = QueueModel.rowReferenceLinks(item)
        if QueueModel.rowHasReferenceLinks(item) {
            HStack(spacing: OVSpacing.md) {
                // #358: .tint(OVColor.forest) below does not recolor a Link's own text on macOS (tint
                // affects control accents, not text color), so the default bright system blue clashed
                // with the forest/gold palette and made these secondary reference links read as more
                // important than they are. Each link needs its own explicit override.
                if let listing = refs.listing {
                    // #1680: the label says whether this goes to the show or only to the venue's calendar.
                    Link(QueueModel.listingLinkLabel(item), destination: listing)
                        .foregroundStyle(OVColor.forest)
                }
                if let website = refs.website {
                    Link("Group website", destination: website)
                        .foregroundStyle(OVColor.forest)
                }
            }
            .font(.system(size: 12))
            .tint(OVColor.forest)
            .padding(.top, 2)
        }
    }

    // #901 (Dan's walk, 2026-07-14): the "Unavailable" badge sits UP HERE, by Keep/Dismiss, and it is
    // loud (a filled rust pill, not a faint tint), with the reason spelled out beneath it. It used to be
    // a quiet tinted capsule buried in the left-hand tag stack, which he walked straight past.
    private var actions: some View {
        VStack(alignment: .trailing, spacing: OVSpacing.xs) {
            if item.hasConflict, let note = item.conflictNote {
                // #1583: the "Partly booked" / "Unavailable" pill that used to sit here is gone, and with it
                // the "I can shoot this anyway" item hidden inside its menu. The pill was two things
                // pretending to be one control: a badge restating the sentence directly beneath it (both
                // came off the same ConflictScope decision, so it carried nothing the sentence did not),
                // and an override buried behind a chevron on something that read as a status. Dan read
                // "Partly booked" as a claim that he had already booked the show, and the live store showed
                // the override had never been used once. Keep is the acceptance now.
                //
                // #1583 decision 4: the SENTENCE never goes away. It renders on `hasConflict`, not on the
                // gate, so accepting the clash stops the blocking and not the telling. He is still busy
                // that night, and the date header still says so.
                //
                // The colour fallback is deliberately the LOUD case. An item carrying a conflict whose two
                // dates cannot be compared is not something to quietly downgrade to the softer colour.
                let scope = QueueModel.conflictScope(item) ?? ConflictScope.thisNight
                Text(note)
                    .font(OVType.tag)
                    // The sentence carries the clash's own colour, which is what the retired pill was
                    // filled with: rust for a night Dan cannot work, gold for a run blocked on a later
                    // night he can still book around.
                    .foregroundStyle(scope.noteTint)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 220, alignment: .trailing)
                // #1583 decision 5: the ONE surviving accept control, and only for a clash that landed
                // AFTER the keep. On an untriaged show there is nothing to put here, because Keep is
                // itself the acceptance; on this card the button reads "Kept", so no click is left that
                // could mean it. A plain visible button next to the sentence, never a pill and never a
                // menu: what it does is the whole of what it is.
                if item.hasUnclearedConflict && item.isKept {
                    Button("I can shoot this anyway") { onClearConflict() }
                        .buttonStyle(.link)
                        .font(OVType.tag)
                }
            }
            keepDismissControls
            // Dan's call after the first real check (2026-07-27): the reachability answer sits DIRECTLY
            // BENEATH Keep and Dismiss. It used to live in the classification pills on the left, among
            // "Self-produced" and "Likely uncovered", which describe what the show IS. This one is
            // different in kind: it is the fact he is deciding ON, so it belongs with the controls he
            // decides WITH. Here, in the trailing VStack that already holds the button row, it
            // right-justifies under those buttons instead of widening their row (which is what put it
            // beside Dismiss twice and left the cards uneven).
            reachabilityFlag
            recheckControl
            heldContactFlag
            reachabilityAddresses
        }
    }

    // #2261: directly under the answer it re-runs, because that answer is the reason to press it. Which
    // of the three states this row is in is Reachability.recheckState's call, so the view holds no rule.
    @ViewBuilder private var recheckControl: some View {
        switch Reachability.recheckState(probedAt: item.reachabilityProbedAt,
                                         hasInheritedAnswer: item.inheritedReachability != nil,
                                         recheckRequestedAt: item.reachabilityRecheckRequestedAt,
                                         now: Date(),
                                         checkIsRunning: probeRunning,
                                         // The SAME predicate the candidacy rule uses, so the control
                                         // and the run cannot disagree about which shows are still live.
                                         isStillOpen: OpenForDecision.isOpen(
                                            status: item.status, performanceDate: item.performanceDate,
                                            isBooked: item.isBooked, sentAt: item.sentAt, today: today)) {
        case .notOffered:
            EmptyView()
        case .offer:
            // #2267: greyed while ANY run holds the single detached slot, rather than failing after the
            // press with "something is already running" (#1323). A probe and a Prep share that slot.
            Button(ReachabilityCopy.checkAgain) { onRequestRecheck() }
                .buttonStyle(.plain).font(OVType.meta)
                .foregroundStyle(prepRunning ? OVColor.inkFaint : OVColor.forest)
                .disabled(prepRunning)
                .help(prepRunning ? ReachabilityCopy.checkAgainBusyHelp : ReachabilityCopy.checkAgainHelp)
                .padding(.top, 2)
        case .running:
            // #2267: counting from when the check actually began, not from this redraw, and carrying its
            // own timeout so a stalled run becomes an actionable state instead of a spinner that never
            // resolves (L74, and the global working/still-alive/failed rule).
            LiveRunLabel(base: ReachabilityCopy.recheckRunning,
                         since: item.reachabilityRecheckRequestedAt,
                         timeout: RunTimeouts.reachabilityProbe,
                         font: OVType.meta, color: OVColor.inkSoft,
                         onRetry: { onRequestRecheck() })
                .padding(.top, 2)
        case .requested:
            // Asked for, and nothing running: either not started yet, or a run ended without reaching it.
            // Both read the same from here, and both are answered by pressing again, so this offers that
            // rather than leaving a dead sentence on the card.
            HStack(spacing: OVSpacing.xs) {
                Text(ReachabilityCopy.recheckOutstanding)
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Button(ReachabilityCopy.checkAgainRetry) { onRequestRecheck() }
                    .buttonStyle(.plain).font(OVType.meta)
                    .foregroundStyle(prepRunning ? OVColor.inkFaint : OVColor.forest)
                    .disabled(prepRunning)
            }
            .padding(.top, 2)
        }
    }

    // #1797, Dan's call 2026-08-01: a contact a review guard is holding, said HERE, while he is deciding
    // keep or dismiss, on a show nothing has been sent to. It used to reach him as "1 show with a contact
    // held for a check" under Send issues, on a show he had never emailed anyone about.
    //
    // Beneath the reachability note rather than instead of it: the two say different things and the
    // common case has both ("Email found" plus the address, and this, saying that address is the one
    // already in play on a neighbouring show).
    //
    // The SAME tone and sentence the identical hold already gets at Review, not a new signal colour: it
    // is a fact about the address printed beside it, not an alarm about the show, and on a triage list
    // 480 rows long a second loud badge would be noise. Whether to show it at all is decided in the model
    // (item.heldContactAtTriage), so a test can reach it.
    @ViewBuilder private var heldContactFlag: some View {
        if let reason = item.heldContactAtTriage {
            reachabilityNote(icon: "person.crop.circle.badge.questionmark",
                             text: ReachabilityCopy.weakContactBadge(reason: reason),
                             tone: Reachability.tone(for: .weakContactOnly),
                             help: ReachabilityCopy.weakContactHelp(reason: reason))
        }
    }

    private var keepDismissControls: some View {
        HStack(spacing: OVSpacing.xs) {
            // #864: a show Overture retired because its date went by is NOT a cut Dan made, and it offers
            // no Restore. Restoring it would put it back as undecided, and the next launch would retire it
            // again for the same unchangeable reason: a button that quietly undoes itself. The date has
            // passed; there is nothing to put it back into.
            //
            // #1540: the help text used to say the performance HAPPENED, which is now false for the rows
            // this sweep takes most often: a run that opened days ago and plays for weeks yet. It says
            // "opened" instead, which is true of a one-night show that has been and gone as well.
            if item.showOutcome == .wentBy {
                Label("Went by", systemImage: "clock.arrow.circlepath")
                    .ovPill(.neutral)
                    .help("This show opened before you triaged it, so it is no longer waiting on you")
            } else if item.status == .dismissed, let onRestore {
                Label("Dismissed", systemImage: "archivebox")
                    .ovPill(.neutral)
                Button { onRestore() } label: {
                    Text("Restore").font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 6)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
                .help("Put this prospect back in the queue as undecided")
            } else {
                if item.isKept {
                    Label("Kept", systemImage: "checkmark.seal.fill")
                        .ovPill(.confirmed)
                    manualPrepControl
                } else {
                    // #1533: Keep no longer pulls up a classification editor. #348 opened one here on
                    // every unconfirmed guess, which was three quarters of the queue, for a question
                    // (self-produced or agency-presented) Dan does not research. Keeping a show is now
                    // one click again.
                    Button {
                        onKeep()
                    } label: {
                        Text("Keep").font(OVType.meta).foregroundStyle(OVColor.onForest)
                            .padding(.horizontal, OVSpacing.md).padding(.vertical, 6)
                            .background(Capsule().fill(OVColor.forest))
                    }
                    .buttonStyle(.plain)
                }
                // #499 regression check (caught in Task 1 review, 2026-07-07): the Dismiss menu must stay a
                // sibling of Kept/Keep, exactly as it was before this task, not nested only inside a branch
                // that excludes the Kept case. Nesting it inside "else if item.isKept { } else { Dismiss }"
                // silently removed Dismiss for every already-kept prospect in the live Queue.
                Menu {
                    // #864: `danCanChoose`, not `allCases`. "Went by" is Overture's own reason for a show
                    // whose date passed untriaged; Dan cannot decide that a date has passed.
                    ForEach(ShowOutcome.menu(wasPitched: item.wasPitched), id: \.self) { reason in
                        Button(reason.label) { onDismiss(reason) }
                    }
                    // #991: the geographic refusal, the missing half of the rule (#979). Unlike a dismiss,
                    // which only hides THIS show, this banishes the whole town: it drops out now and never
                    // returns. Offered only where it does something, an in-region, non-borough town
                    // (EventPlace.excludableTown), so it does not clutter every row.
                    if let town = item.excludableTown {
                        Divider()
                        Button(QueueModel.excludeTownLabel(town: town)) { onExcludeTown() }
                    }
                    // #1719: correcting who really presents this show. It lives in this menu for the same
                    // reason the town refusal does: it is not a dismiss, it is a correction to how Overture
                    // decides, and this menu is the row's one always-present home for those. It cannot hang
                    // off the presenter line, because a demotion stops that line being drawn and the undo
                    // would vanish with it. Offered only where there is an organisation to correct.
                    if let org = item.correctableOrganisation {
                        // A Section header rather than a disabled Button: it is a statement, not something
                        // to click, and a greyed-out button reads as an action Dan is not allowed to take.
                        Section(QueueModel.producerVerdictLine(item.producerStanding,
                                                               treatedAsVenue: item.treatedAsVenue)) {
                            Button(QueueModel.producerCorrectionLabel(item.producerStanding,
                                                                      organisation: org,
                                                                      treatedAsVenue: item.treatedAsVenue)) {
                                // One action, and it always CHANGES something: flip to whichever the row is
                                // not, or drop the correction and let the gate decide again.
                                if item.producerStanding != .none {
                                    onCorrectProducer(ProducerOverrideEditing.Standing.none)
                                } else {
                                    onCorrectProducer(item.treatedAsVenue ? .promoted : .demoted)
                                }
                            }
                        }
                    }
                } label: {
                    // #1460: the same secondary-action capsule OVCapsuleButton wears, via the shared
                    // modifier, so "you can do this" reads identically here (a Menu) and in the Sources sheet
                    // (Buttons). Only the neutral tint is this control's own.
                    Text("Dismiss").foregroundStyle(OVColor.inkSoft)
                        .ovCapsuleAction()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    // #2007: "Prep manually", beside Kept rather than instead of anything. Dan chooses it per show and
    // nothing is automatic: the ordinary Prep run still owns every cold show, and this is the shortcut
    // for the warm ones where an AI draft is money and time spent on a paragraph he rewrites anyway.
    //
    // Which of the three states to draw is QueueModel.manualPrepOffer's decision (#863), and the blocked
    // one stays VISIBLE with its reason: "I can shoot this anyway" sits on this same card to clear it.
    @ViewBuilder private var manualPrepControl: some View {
        switch QueueModel.manualPrepOffer(for: item) {
        case .shown:
            manualPrepButton
        case .blocked(let reason):
            manualPrepButton.disabled(true).help(reason)
        case .hidden:
            EmptyView()
        }
    }

    // Wearing the shared secondary-action capsule (#1460), the same chrome the Dismiss control beside it
    // wears. Not a plain tinted word: a control styled like static text ships as an invisible feature
    // (#1742), and this one sits next to a "Kept" PILL, which is a status and not a thing to click.
    private var manualPrepButton: some View {
        OVCapsuleButton(label: "Prep manually", tint: OVColor.inkSoft) { showingManualPrep = true }
            .help("Write this email yourself, with no Prep run and no AI draft")
    }

    // #1363/#348: one editor, both dimensions at once. Opened by tapping the badge or automatically
    // right after Keep on an unconfirmed prospect. Genre and production are independent (#349), so both
    // pickers show together, pre-filled with the scout's guess; a single Confirm resolves everything in
    // one pass. Confirming an unchanged guess accepts it (marks reviewed, no override); changing either
    // dimension corrects only what changed. The resolve decision lives in ClassificationResolution so it
    // stays testable outside the view (#863).
    private var genreEditorPopover: some View {
        GenreEditor(
            currentDiscipline: item.discipline,
            onCorrect: onCorrectClassification,
            onClose: { showGenreEditor = false }
        )
    }
}

// The genre editor (#1363, rescoped by #1533). One picker, pre-filled with the genre the scout read,
// and one Save. A separate view so each open starts its picker state fresh from the current value.
//
// It carried a production-type picker until #1533. That question is no longer asked: answering it
// honestly means reading the presenter's site to see who is putting the show on, which Dan does not do,
// and an unanswered production already scores a neutral 0.
private struct GenreEditor: View {
    let currentDiscipline: String
    let onCorrect: (Discipline) -> Void
    let onClose: () -> Void

    @State private var selectedDiscipline: Discipline

    init(currentDiscipline: String,
         onCorrect: @escaping (Discipline) -> Void,
         onClose: @escaping () -> Void) {
        self.currentDiscipline = currentDiscipline
        self.onCorrect = onCorrect
        self.onClose = onClose
        _selectedDiscipline = State(initialValue: Discipline(rawValue: currentDiscipline) ?? .other)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            Text("Genre").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            Picker("", selection: $selectedDiscipline) {
                ForEach(Discipline.allCases, id: \.self) { discipline in
                    Text(QueueModel.disciplineLabel(discipline.rawValue)).tag(discipline)
                }
            }
            .labelsHidden()
            HStack {
                Spacer()
                Button("Save") {
                    // The no-change arm writes NOTHING: an override flag set by a Save that changed
                    // nothing would tell every later scout to stop refreshing a genre Dan never corrected.
                    if case let .correct(discipline) = ClassificationResolution.resolve(
                        currentDiscipline: currentDiscipline, selectedDiscipline: selectedDiscipline) {
                        onCorrect(discipline)
                    }
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(OVSpacing.lg)
        .frame(width: 240)
    }
}

private enum TagTone { case good, warn, history, info }
private struct Tag { let text: String; let tone: TagTone }

private struct FlowTags: View {
    let tags: [Tag]
    var body: some View {
        WrapHStack(spacing: OVSpacing.xs, lineSpacing: OVSpacing.xs) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                Text(tag.text)
                    .font(OVType.tag)
                    .foregroundStyle(color(tag.tone))
                    .padding(.horizontal, OVSpacing.sm)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(fill(tag.tone))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(border(tag.tone), lineWidth: 1))
                    )
            }
        }
    }

    private func color(_ t: TagTone) -> Color {
        switch t {
        case .good: return OVColor.forest
        case .warn: return OVColor.inkSoft
        case .history: return OVColor.gold
        case .info: return OVColor.inkSoft
        }
    }
    private func fill(_ t: TagTone) -> Color {
        switch t {
        case .good: return OVColor.forest.opacity(0.08)
        case .warn: return OVColor.surfaceSunk
        case .history: return OVColor.gold.opacity(0.12)
        case .info: return OVColor.surfaceSunk
        }
    }
    private func border(_ t: TagTone) -> Color {
        switch t {
        case .good: return OVColor.forest.opacity(0.2)
        case .warn: return OVColor.lineStrong
        case .history: return OVColor.gold.opacity(0.4)
        case .info: return OVColor.lineStrong
        }
    }
}
