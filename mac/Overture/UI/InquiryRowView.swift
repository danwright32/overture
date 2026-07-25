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
    var onMarkLost: (InquiryLostReason) -> Void

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

    private var stateText: String { InquiryCopy.rowState(sentAt: row.sentAt, replied: row.replied) }

    @ViewBuilder private var stateLine: some View {
        HStack(spacing: OVSpacing.xs) {
            if row.bookingSuggested { badge("Looks booked?", OVColor.gold) }
            if row.followUpNudgeDue { badge("Follow up", OVColor.rust) }
            if row.shouldSuggestClosing { badge("Consider closing", OVColor.inkFaint) }
            Text(stateText).font(OVType.meta).foregroundStyle(OVColor.inkFaint)
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
            if InquiryMutations.showsReplyAction(sentAt: row.sentAt) {
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
                    ForEach(InquiryLostReason.allCases, id: \.self) { reason in
                        Button(reason.label) { onMarkLost(reason) }
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
