import SwiftUI

// One editorial "call sheet" entry. High-fit prospects carry a gold edge; the fit
// score reads like a grade. Keep and Dismiss act on the local store directly.
struct ProspectRowView: View {
    // #348: pulled forward right after Keep on a still-unconfirmed prospect, instead of leaving
    // an unresolved guess to carry silently forward.
    @State private var showConfirmClassification = false

    let item: QueueItem
    let today: String
    let onKeep: () -> Void
    let onDismiss: (DismissReason) -> Void
    var onApprove: () -> Void = {}
    var onUnapprove: () -> Void = {}
    var onSkipDraft: () -> Void = {}
    var onSaveDraft: (_ subject: String, _ body: String) -> Void = { _, _ in }
    var onSetLostReason: (String) -> Void = { _ in }
    var onSend: () -> Void = {}
    var onOverrideSalutationReview: () -> Void = {}
    var onDismissReply: () -> Void = {}
    var onMarkContact: (_ recipientId: String, _ resolution: RecipientResolution?, _ bounced: Bool) -> Void = { _, _, _ in }
    var onSetRecipientConversationState: (_ recipientId: String, _ state: ConversationState) -> Void = { _, _ in }
    var onConfirmRecipientConversationState: (_ recipientId: String) -> Void = { _ in }
    var onAddRecipient: (_ email: String, _ name: String?) -> Void = { _, _ in }
    var onRemoveRecipient: (_ recipientId: String) -> Void = { _ in }
    var onDismissContactReply: (_ recipientId: String) -> Void = { _ in }
    var onDismissContactBounce: (_ recipientId: String) -> Void = { _ in }
    var onDraftReply: (_ recipientId: String) -> Void = { _ in }
    var onSendReply: (_ recipientId: String) -> Void = { _ in }
    var onCopyReply: (_ recipientId: String) -> Void = { _ in }
    var onEditReplyDraft: (_ recipientId: String, _ body: String) -> Void = { _, _ in }
    var onMarkConfidenceReviewed: () -> Void = {}
    var onCorrectClassification: (Discipline?, Production?) -> Void = { _, _ in }
    var onConfirmBooking: () -> Void = {}
    var onDismissBookingSuggestion: () -> Void = {}
    var onRejectBooking: () -> Void = {}
    // #611: dismisses the "already has its own photographer" fit-risk flag as a false positive.
    var onDismissAlreadyCoveredFlag: () -> Void = {}
    // Only ever passed non nil by Archive (the Queue never shows a dismissed prospect), so
    // this has zero effect on any existing Queue row.
    var onRestore: (() -> Void)? = nil
    var gmailConnected: Bool = false
    // #436: in-flight send timestamps so the row shows a live "Sending…" state (see DraftReviewView).
    var outboundSendSince: Date? = nil
    var replySendSince: (_ recipientId: String) -> Date? = { _ in nil }
    // #685: which contact, if any, to highlight inside this card's Contacts section.
    var highlightedRecipientId: String? = nil

    private var timing: QueueModel.Timing {
        QueueModel.displayTiming(performanceDate: item.performanceDate, today: today, isBooked: item.isBooked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            HStack(alignment: .top, spacing: OVSpacing.md) {
                if item.isBooked { bookedSeal } else { fitSeal }
                VStack(alignment: .leading, spacing: OVSpacing.xs) {
                    header
                    feedStatusFlag
                    if !item.fitReason.isEmpty && !item.classificationOverriddenByDan {
                        Text(item.fitReason)
                            .font(OVType.reason)
                            .foregroundStyle(OVColor.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)   // #340: let the caveat breathe instead of crowding the metadata
                    }
                    tags
                    relatedRunNote
                    confidenceFlag
                    bookingSuggestionFlag
                    alreadyCoveredFlag
                    autoBookedTag
                    links
                }
                Spacer(minLength: OVSpacing.sm)
                actions
            }
            if item.hasDraft {
                DraftReviewView(
                    item: item,
                    onApprove: onApprove,
                    onUnapprove: onUnapprove,
                    onSkip: onSkipDraft,
                    onSaveDraft: onSaveDraft,
                    onSetLostReason: onSetLostReason,
                    onSend: onSend,
                    onOverrideSalutationReview: onOverrideSalutationReview,
                    onDismissReply: onDismissReply,
                    onMarkContact: onMarkContact,
                    onSetRecipientConversationState: onSetRecipientConversationState,
                    onConfirmRecipientConversationState: onConfirmRecipientConversationState,
                    onDismissContactReply: onDismissContactReply,
                    onDismissContactBounce: onDismissContactBounce,
                    onAddRecipient: onAddRecipient,
                    onRemoveRecipient: onRemoveRecipient,
                    onDraftReply: onDraftReply,
                    onSendReply: onSendReply,
                    onCopyReply: onCopyReply,
                    onEditReplyDraft: onEditReplyDraft,
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(item.bookingSuggested || item.isBooked ? OVColor.forest.opacity(0.12) : OVColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    item.bookingSuggested || item.isBooked ? OVColor.forest.opacity(0.9)
                        : item.isHighFit ? OVColor.gold.opacity(0.45)
                        : OVColor.line,
                    lineWidth: item.bookingSuggested || item.isBooked ? 2 : 1)
        )
    }

    private var fitSeal: some View {
        VStack(spacing: 2) {
            Text("\(item.fitScore)")
                .font(OVType.fitNumber)
                .foregroundStyle(item.isHighFit ? OVColor.gold : OVColor.inkFaint)
            Text(item.isHighFit ? "HIGH FIT" : "LONG SHOT")
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
            Text(QueueModel.disciplineLabel(item.discipline).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(OVColor.gold)
            Text(item.groupName)
                .font(OVType.groupName)
                .foregroundStyle(item.disappearedFromFeed ? OVColor.inkFaint : OVColor.ink)
                .strikethrough(item.disappearedFromFeed, color: OVColor.rust)
            // #340: give the metadata a calmer hierarchy instead of cramming venue, timing and date
            // onto one dot-separated line. Venue is the "where" on its own line; the "when" (date plus
            // the relative timing cue) sits beneath it, smaller and de-emphasized, with the timing
            // keeping its urgency colour.
            // #342: when the venue is a known hall, show its parent building inline ("…, Carnegie Hall")
            // and the city/state as a fainter line beneath, so any venue is locatable at a glance.
            let venueInfo = VenueDisplay.resolve(item.venue)
            Text(venueInfo.nameLine)
                .font(OVType.body)
                .foregroundStyle(OVColor.inkSoft)
            if let location = venueInfo.location {
                Text(location)
                    .font(OVType.meta.weight(.regular))
                    .foregroundStyle(OVColor.inkFaint)
            }
            HStack(spacing: 6) {
                Text(QueueModel.runDateLabel(start: item.performanceDate, end: item.runEndDate))
                    .foregroundStyle(OVColor.inkFaint)
                Text("·").foregroundStyle(OVColor.lineStrong)
                Text(timing.label)
                    .foregroundStyle(timing.urgency == .imminent ? OVColor.rust
                                     : timing.urgency == .booked ? OVColor.forest : OVColor.inkFaint)
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
            .font(OVType.tag)
            .foregroundStyle(OVColor.rust)
            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 5)
            .background(Capsule().fill(OVColor.rust.opacity(0.12)))
            .padding(.top, 2)
            .help("This show was in an earlier scout but has dropped out of the venue feed across the last two scouts, so it was likely cancelled or pulled. Your keep/dismiss history is preserved.")
        }
    }

    @ViewBuilder private var relatedRunNote: some View {
        if let note = QueueModel.relatedRunNote(item) {
            Text(note)
                .font(OVType.tag)
                .foregroundStyle(OVColor.inkSoft)
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
        ].compactMap { $0 })
        .padding(.top, 2)
    }

    // A rules-guessed classification Dan hasn't reviewed: a menu so he can confirm it
    // looks right or correct the discipline/production (#60). Clears automatically once
    // he picks an action (confidenceReviewedByDan or classificationOverriddenByDan).
    @ViewBuilder private var confidenceFlag: some View {
        if item.isClassificationUncertain {
            Menu {
                Button("This looks right") { onMarkConfidenceReviewed() }
                Divider()
                // #349: genre and production type are independent classifications (a show has
                // both; they're never alternatives), so each gets its own labeled submenu
                // instead of sitting in one flat single-select list.
                Menu("Genre") {
                    ForEach(Discipline.allCases, id: \.self) { discipline in
                        Button(QueueModel.disciplineLabel(discipline.rawValue)) {
                            onCorrectClassification(discipline, nil)
                        }
                    }
                }
                Menu("Production type") {
                    Button("Self-produced") { onCorrectClassification(nil, .selfProduced) }
                    Button("Agency/presented") { onCorrectClassification(nil, .agency) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 13, weight: .semibold))
                    Text("Unsure call, tap to confirm or fix")
                }
                .font(OVType.tag)
                .foregroundStyle(OVColor.rust)
                .padding(.horizontal, OVSpacing.sm).padding(.vertical, 5)
                .background(Capsule().fill(OVColor.rust.opacity(0.12)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("The scout's rules weren't sure how to classify this one. Confirm it looks right or pick the correct discipline or production type.")
            .padding(.top, 2)
        }
    }

    // A possible booking that needs Dan's explicit sign-off before it locks (#114).
    // Gold tone (positive, not a warning), mirroring the confidenceFlag capsule idiom.
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
                .font(OVType.tag)
                .foregroundStyle(OVColor.gold)
                .padding(.horizontal, OVSpacing.sm).padding(.vertical, 5)
                .background(Capsule().fill(OVColor.gold.opacity(0.12)))
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
                .font(OVType.tag)
                .foregroundStyle(OVColor.rust)
                .padding(.horizontal, OVSpacing.sm).padding(.vertical, 5)
                .background(Capsule().fill(OVColor.rust.opacity(0.12)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Prep's research found this show may already have its own photographer. Tap if that's wrong.")
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
                .font(OVType.tag)
                .foregroundStyle(OVColor.forest)
                .padding(.horizontal, OVSpacing.sm).padding(.vertical, 5)
                .background(Capsule().fill(OVColor.forest.opacity(0.14)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("This booking was auto-detected from Downbeat. Confirm it (it then moves out of the reach-out list), or reject a wrong match to pull it back out.")
            .padding(.top, 2)
        }
    }

    @ViewBuilder private var links: some View {
        HStack(spacing: OVSpacing.md) {
            // #358: .tint(OVColor.forest) below does not recolor a Link's own text on macOS (tint
            // affects control accents, not text color), so the default bright system blue clashed
            // with the forest/gold palette and made these secondary reference links read as more
            // important than they are. Each link needs its own explicit override.
            if let s = item.sourceListingURL, let url = URL(string: s) {
                Link("Source listing", destination: url)
                    .foregroundStyle(OVColor.forest)
            }
            if let w = item.websiteURL, let url = URL(string: w) {
                Link("Group website", destination: url)
                    .foregroundStyle(OVColor.forest)
            }
            if !item.hasDraft && !item.isBooked {
                Text(item.isKept ? "Contact: pending Prep run" : "Contact: keep to prep")
                    .foregroundStyle(OVColor.inkFaint)
            }
        }
        .font(.system(size: 12))
        .tint(OVColor.forest)
        .padding(.top, 2)
    }

    private var actions: some View {
        HStack(spacing: OVSpacing.xs) {
            if item.status == .dismissed, let onRestore {
                Label("Dismissed", systemImage: "archivebox")
                    .font(OVType.meta)
                    .foregroundStyle(OVColor.inkFaint)
                    .padding(.horizontal, OVSpacing.sm)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(OVColor.inkFaint.opacity(0.10)))
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
                        .font(OVType.meta)
                        .foregroundStyle(OVColor.forest)
                        .padding(.horizontal, OVSpacing.sm)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(OVColor.forest.opacity(0.10)))
                } else {
                    Button {
                        let wasUncertain = item.isClassificationUncertain
                        onKeep()
                        if wasUncertain { showConfirmClassification = true }
                    } label: {
                        Text("Keep").font(OVType.meta).foregroundStyle(OVColor.onForest)
                            .padding(.horizontal, OVSpacing.md).padding(.vertical, 6)
                            .background(Capsule().fill(OVColor.forest))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showConfirmClassification) { confirmClassificationPopover }
                }
                // #499 regression check (caught in Task 1 review, 2026-07-07): the Dismiss menu must stay a
                // sibling of Kept/Keep, exactly as it was before this task, not nested only inside a branch
                // that excludes the Kept case. Nesting it inside "else if item.isKept { } else { Dismiss }"
                // silently removed Dismiss for every already-kept prospect in the live Queue.
                Menu {
                    ForEach(DismissReason.allCases, id: \.self) { reason in
                        Button(reason.label) { onDismiss(reason) }
                    }
                } label: {
                    Text("Dismiss").font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 6)
                        .background(Capsule().strokeBorder(OVColor.lineStrong, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    // #348: the same three resolutions the manual "Unsure call" menu offers (This looks right,
    // pick a genre, pick a production type), reusing the same closures, surfaced automatically
    // right after Keep instead of requiring Dan to notice and click the badge himself.
    private var confirmClassificationPopover: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            Text("Confirm classification").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            Button("This looks right") {
                onMarkConfidenceReviewed()
                showConfirmClassification = false
            }
            Divider()
            Text("Genre").font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            ForEach(Discipline.allCases, id: \.self) { discipline in
                Button(QueueModel.disciplineLabel(discipline.rawValue)) {
                    onCorrectClassification(discipline, nil)
                    showConfirmClassification = false
                }
            }
            Divider()
            Text("Production type").font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            Button("Self-produced") {
                onCorrectClassification(nil, .selfProduced)
                showConfirmClassification = false
            }
            Button("Agency/presented") {
                onCorrectClassification(nil, .agency)
                showConfirmClassification = false
            }
        }
        .padding(OVSpacing.lg)
        .frame(width: 260)
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
