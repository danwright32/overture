import SwiftUI

// One editorial "call sheet" entry. High-fit prospects carry a gold edge; the fit
// score reads like a grade. Keep and Dismiss act on the local store directly.
struct ProspectRowView: View {
    let item: QueueItem
    let today: String
    let onKeep: () -> Void
    let onDismiss: (DismissReason) -> Void
    var onApprove: () -> Void = {}
    var onUnapprove: () -> Void = {}
    var onSkipDraft: () -> Void = {}
    var onSaveDraft: (_ subject: String, _ body: String) -> Void = { _, _ in }
    var onSetOutcome: (Outcome) -> Void = { _ in }
    var onSetLostReason: (String) -> Void = { _ in }
    var onSend: () -> Void = {}
    var onMarkConfidenceReviewed: () -> Void = {}
    var onCorrectClassification: (Discipline?, Production?) -> Void = { _, _ in }
    var onConfirmBooking: () -> Void = {}
    var onDismissBookingSuggestion: () -> Void = {}
    var gmailConnected: Bool = false

    private var timing: QueueModel.Timing {
        QueueModel.outreachTiming(performanceDate: item.performanceDate, today: today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            HStack(alignment: .top, spacing: OVSpacing.md) {
                fitSeal
                VStack(alignment: .leading, spacing: OVSpacing.xs) {
                    header
                    feedStatusFlag
                    if !item.fitReason.isEmpty && !item.classificationOverriddenByDan {
                        Text(item.fitReason)
                            .font(OVType.reason)
                            .foregroundStyle(OVColor.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    tags
                    relatedRunNote
                    confidenceFlag
                    bookingSuggestionFlag
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
                    onSetOutcome: onSetOutcome,
                    onSetLostReason: onSetLostReason,
                    onSend: onSend,
                    gmailConnected: gmailConnected
                )
                .padding(.leading, 64 + OVSpacing.md)
            }
        }
        .padding(OVSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(item.bookingSuggested ? OVColor.forest.opacity(0.12) : OVColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    item.bookingSuggested ? OVColor.forest.opacity(0.9)
                        : item.isHighFit ? OVColor.gold.opacity(0.45)
                        : OVColor.line,
                    lineWidth: item.bookingSuggested ? 2 : 1)
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
            HStack(spacing: 6) {
                Text(item.venue ?? "Venue TBD")
                Text("·").foregroundStyle(OVColor.inkFaint)
                Text(timing.label)
                    .foregroundStyle(timing.urgency == .imminent ? OVColor.rust : OVColor.inkSoft)
                Text("·").foregroundStyle(OVColor.inkFaint)
                Text(QueueModel.runDateLabel(start: item.performanceDate, end: item.runEndDate))
            }
            .font(OVType.body)
            .foregroundStyle(OVColor.inkSoft)
        }
    }

    // Shown only on a prospect Dan was pursuing that has since vanished from the feed (#133):
    // a struck-through title plus this note, so a cancelled/pulled show he kept isn't mistaken
    // for still happening. Untouched ones are filtered out of the queue entirely.
    @ViewBuilder private var feedStatusFlag: some View {
        if item.disappearedFromFeed {
            HStack(spacing: 5) {
                Image(systemName: "calendar.badge.exclamationmark")
                Text("No longer in the feed — may be cancelled")
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
                ForEach(Discipline.allCases, id: \.self) { discipline in
                    Button(QueueModel.disciplineLabel(discipline.rawValue)) {
                        onCorrectClassification(discipline, nil)
                    }
                }
                Divider()
                Button("Self-produced") { onCorrectClassification(nil, .selfProduced) }
                Button("Agency/presented") { onCorrectClassification(nil, .agency) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.diamond.fill")
                    Text("Unsure call — tap to confirm or fix")
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
    // Gold tone — positive, not a warning — mirroring the confidenceFlag capsule idiom.
    @ViewBuilder private var bookingSuggestionFlag: some View {
        if item.bookingSuggested {
            Menu {
                Button("Confirm booking") { onConfirmBooking() }
                Button("Not a booking") { onDismissBookingSuggestion() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Possible booking — confirm?")
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

    // A small neutral tag shown only when the booking was auto-detected, so Dan knows
    // it wasn't manually marked (#114). Hidden for bookings Dan set himself.
    @ViewBuilder private var autoBookedTag: some View {
        if item.isAutoBooked {
            FlowTags(tags: [Tag(text: "auto-detected", tone: .warn)])
                .padding(.top, 2)
        }
    }

    @ViewBuilder private var links: some View {
        HStack(spacing: OVSpacing.md) {
            if let s = item.sourceListingURL, let url = URL(string: s) {
                Link("Source listing", destination: url)
            }
            if let w = item.websiteURL, let url = URL(string: w) {
                Link("Group website", destination: url)
            }
            if !item.hasDraft {
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
            if item.isKept {
                Label("Kept", systemImage: "checkmark.seal.fill")
                    .font(OVType.meta)
                    .foregroundStyle(OVColor.forest)
                    .padding(.horizontal, OVSpacing.sm)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(OVColor.forest.opacity(0.10)))
            } else {
                Button(action: onKeep) {
                    Text("Keep").font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 6)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
            }
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

private enum TagTone { case good, warn, history }
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
        switch t { case .good: return OVColor.forest; case .warn: return OVColor.inkSoft; case .history: return OVColor.gold }
    }
    private func fill(_ t: TagTone) -> Color {
        switch t { case .good: return OVColor.forest.opacity(0.08); case .warn: return OVColor.surfaceSunk; case .history: return OVColor.gold.opacity(0.12) }
    }
    private func border(_ t: TagTone) -> Color {
        switch t { case .good: return OVColor.forest.opacity(0.2); case .warn: return OVColor.lineStrong; case .history: return OVColor.gold.opacity(0.4) }
    }
}
