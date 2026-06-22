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

    private var timing: QueueModel.Timing {
        QueueModel.outreachTiming(performanceDate: item.performanceDate, today: today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            HStack(alignment: .top, spacing: OVSpacing.md) {
                fitSeal
                VStack(alignment: .leading, spacing: OVSpacing.xs) {
                    header
                    if !item.fitReason.isEmpty {
                        Text(item.fitReason)
                            .font(OVType.reason)
                            .foregroundStyle(OVColor.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    tags
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
                    onSetOutcome: onSetOutcome
                )
                .padding(.leading, 64 + OVSpacing.md)
            }
        }
        .padding(OVSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OVColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(item.isHighFit ? OVColor.gold.opacity(0.45) : OVColor.line, lineWidth: 1)
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
                .foregroundStyle(OVColor.ink)
            HStack(spacing: 6) {
                Text(item.venue ?? "Venue TBD")
                Text("·").foregroundStyle(OVColor.inkFaint)
                Text(timing.label)
                    .foregroundStyle(timing.urgency == .imminent ? OVColor.rust : OVColor.inkSoft)
            }
            .font(OVType.body)
            .foregroundStyle(OVColor.inkSoft)
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
