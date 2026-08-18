import SwiftUI

// #1436: a hire inquiry as it appears in the daily queue, alongside scouted shows. It carries no fit
// score, geo, or reachability (all Prospect-only); it shows where it came from and its own lifecycle
// state instead. Actions are closures so the view stays free of the store.
struct InquiryRowView: View {
    // #1513: how this row sits in the list it is in. `.card` is the standalone block used where
    // inquiries have a section of their own (Review). `.listRow` drops the box and adopts the
    // surrounding rows' typography, for Reached out, where inquiries and shows are one list and two
    // visual languages read as two unrelated things.
    enum Style { case card, listRow }

    let row: InquiryRow
    var style: Style = .card
    var onReply: () -> Void
    var onEdit: () -> Void
    var onMarkBooked: () -> Void
    var onMarkLost: (ShowOutcome) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: OVSpacing.sm) {
                sourceTag
                Text(row.inquirerName)
                    .font(style == .card ? OVType.body : OVType.groupName)
                    .foregroundStyle(OVColor.ink)
                Spacer()
                actions
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            stateLine
        }
        .padding(style == .card ? OVSpacing.md : 0)
        .background {
            if style == .card {
                RoundedRectangle(cornerRadius: 10).fill(OVColor.surfaceSunk)
            }
        }
    }

    private var sourceTag: some View {
        Text(row.source.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(OVColor.inkSoft)
            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 2)
            .overlay(Capsule().stroke(OVColor.line))
    }

    private var subtitle: String { InquiryCopy.rowSubtitle(event: row.eventName, venue: row.venue) }

    private var stateText: String {
        InquiryCopy.rowState(sentAt: row.sentAt, replied: row.replied,
                             answeredReplyLine: row.answeredReplyLine)
    }

    @ViewBuilder private var stateLine: some View {
        HStack(spacing: OVSpacing.xs) {
            if row.bookingSuggested { badge("Looks booked?", OVColor.gold) }
            if row.followUpNudgeDue { badge("Follow up", OVColor.rust) }
            if row.shouldSuggestClosing { badge("Consider closing", OVColor.inkFaint) }
            // #2712: where this conversation came from. Quiet ink rather than gold, because it is
            // something Overture did rather than something Dan has to act on.
            if let found = InquiryCopy.foundInGmailBadge(attachedAt: row.conversationAttachedAt) {
                badge(found, OVColor.inkFaint).help(InquiryCopy.foundInGmailHelp)
            }
            Text(stateText).font(OVType.meta).foregroundStyle(OVColor.inkFaint)
        }
        sendProblems
    }

    // #2675: an inquiry's send problems, which had writers and no reader anywhere in the app. Here rather
    // than folded into the shows "Send issues" pill: that pill is a navigation target whose tap resolves
    // prospect keys, so adding inquiries to its number would name a fault and give Dan nowhere to go
    // (L80), and it would say it in the word "shows", which an inquiry is not (L118). The row is where
    // the rest of an inquiry's state already lives, and it is somewhere he can act.
    //
    // On their own line beneath the state, not in the badge row above: those three badges are about where
    // the inquiry IS in its life, and these are about something having gone wrong with the last send.
    @ViewBuilder private var sendProblems: some View {
        if row.threadIdDegraded || row.threadingDegraded || SendFailureLine.text(for: row.sendError) != nil {
            HStack(spacing: OVSpacing.xs) {
                // Rust, the loudest: an answer to this will not be noticed at all.
                if row.threadIdDegraded {
                    badge(InquiryCopy.replyTrackingLostBadge, OVColor.rust)
                        .help(InquiryCopy.replyTrackingLostHelp)
                }
                // Gold: the reply is watched, only the filing of the next one suffers.
                if row.threadingDegraded {
                    badge(InquiryCopy.threadingDegradedBadge, OVColor.gold)
                        .help(InquiryCopy.threadingDegradedHelp)
                }
                // The full sentence rather than a badge, because it carries the reason the send gave, and
                // through the SAME helper the prospect rows use so the two cannot word it differently.
                if let line = SendFailureLine.text(for: row.sendError) {
                    Text(line).font(OVType.meta).foregroundStyle(OVColor.rust)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 2)
            .overlay(Capsule().stroke(color.opacity(0.5)))
    }

    private var actions: some View {
        HStack(spacing: OVSpacing.sm) {
            if InquiryMutations.showsReplyAction(sentAt: row.sentAt,
                                                 hasUnhandledReply: row.hasUnhandledReply,
                                                 bounced: row.bounced) {
                Button(action: onReply) {
                    Text("Reply").font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 4)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
            }
            Menu {
                // #1504: the fields here are hand-typed and often incomplete at intake (a date learned
                // later re-keys the inquiry), so correcting them has to be reachable from the row.
                Button("Edit details...") { onEdit() }
                Button("Mark booked") { onMarkBooked() }
                // #16 needs the reasons apart, and closing an inquiry is the only moment anyone knows
                // which it was. Kept under a heading rather than loose in the menu: on their own,
                // "Never heard back" beside "Mark booked" reads as setting a status rather than closing
                // the inquiry. The heading says what all three do, so each is still one click.
                Section("Mark lost") {
                    // #2400: the same four endings a pitched show offers, from the one vocabulary, so a
                    // season report reads one column across both halves of the funnel.
                    ForEach(InquiryEnding.danCanChoose, id: \.self) { ending in
                        Button(ending.label) { onMarkLost(ending) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(OVColor.inkSoft)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
