import SwiftUI
import SwiftData

// #2408: the addresses Dan has struck, and the one place he can put one back.
//
// #2392 gave him the strike and nothing showed him what he had struck. A show-scoped strike is at least
// legible by its absence on that card; an ORGANISATION-scoped one removes the address from every show
// that organisation ever puts on, so weeks later such a show shows one address fewer than the check found
// with nothing on screen saying why.
//
// Mirrors `ExcludedTownsView`, which is the same shape for the same reason: a list of Dan's own refusals
// with a way back, in its own sheet with its own banner (a sheet is a separate window on macOS, so an
// acknowledgement raised behind it would be invisible).
//
// EVERY RULE IS OUTSIDE THE VIEW (#863): what the list holds is `StruckAddressListing`, putting one back
// is `StruckAddressMutations`, and the words are `StruckAddressCopy`. The view draws.
struct StruckAddressesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback
    // Bound, so putting one back redraws this sheet the instant the row is gone.
    @Query private var refusals: [RefusedContactAddress]
    // The shows are what NAMES a strike: the stored scope is a folded key, never a spelling Dan would
    // recognise.
    @Query private var prospects: [Prospect]

    private var rows: [StruckAddressListing.Row] {
        refusals.map { .init(handleKey: $0.handleKey, scopeRaw: $0.scopeRaw,
                             scopeId: $0.scopeId, refusedAt: $0.refusedAt) }
    }

    private var entries: [StruckAddressListing.Entry] {
        StruckAddressListing.build(
            rows: rows,
            shows: prospects.map { .init(naturalKey: $0.naturalKey, groupName: $0.groupName,
                                         presenter: $0.presenter) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(OVColor.line)
            CappedScrollView(maxHeight: 460) {
                VStack(alignment: .leading, spacing: OVSpacing.sm) {
                    if entries.isEmpty {
                        Text(StruckAddressCopy.emptyState)
                            .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(entries) { entry in row(entry) }
                    }
                }
                .padding(OVSpacing.lg)
            }
        }
        .frame(width: 560)
        .background(OVColor.canvas)
        .actionFeedbackBanner()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(StruckAddressCopy.heading)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
                Text(StruckAddressCopy.explanation)
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(OVSpacing.lg)
    }

    private func row(_ entry: StruckAddressListing.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OVSpacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.handle)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(OVColor.ink)
                    .textSelection(.enabled)
                // WHICH strike this is, and the two are very different: one show, or every show that
                // organisation puts on. The second is the half he cannot see anywhere else.
                Text(entry.appliesToEveryShowBy
                        ? "\(StruckAddressCopy.everyShowBy) \(entry.scopeName)"
                        : entry.scopeName)
                    .font(.system(size: 11)).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(StruckAddressCopy.restoreControl) {
                StruckAddressMutations.putBack(entry, rows: rows, context: context, feedback: feedback)
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OVColor.forestText)
        }
        .padding(.vertical, 3)
    }
}
