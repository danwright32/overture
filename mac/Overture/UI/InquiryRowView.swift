import SwiftUI

// #1436: a hire inquiry as it appears in the daily queue, alongside scouted shows. It carries no fit
// score, geo, or reachability (all Prospect-only); it shows where it came from and its own lifecycle
// state instead. Actions are closures so the view stays free of the store.
struct InquiryRowView: View {
    let row: InquiryRow
    var onReply: () -> Void
    var onMarkBooked: () -> Void
    var onMarkLost: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: OVSpacing.sm) {
                sourceTag
                Text(row.inquirerName).font(OVType.body).foregroundStyle(OVColor.ink)
                Spacer()
                actions
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            stateLine
        }
        .padding(OVSpacing.md)
        .background(RoundedRectangle(cornerRadius: 10).fill(OVColor.surfaceSunk))
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
            if row.sentAt == nil {
                Button(action: onReply) {
                    Text("Reply").font(OVType.meta).foregroundStyle(OVColor.onForest)
                        .padding(.horizontal, OVSpacing.md).padding(.vertical, 4)
                        .background(Capsule().fill(OVColor.forest))
                }
                .buttonStyle(.plain)
            }
            Menu {
                Button("Mark booked") { onMarkBooked() }
                Button("Mark lost") { onMarkLost() }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(OVColor.inkSoft)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
