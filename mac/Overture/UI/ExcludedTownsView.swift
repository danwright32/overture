import SwiftUI
import SwiftData

// #1118: the towns Overture keeps out of Dan's queue, and the one place he can take one back off the list.
//
// #991 lets him refuse a town from a show ("never show me shows in this town"), but the only way back was
// the banner's Undo, gone the moment it cleared. After that the skip list only grew: a town refused by
// mistake, or one a presenter he now cares about has started programming in, could only be recovered by a
// code change. This is that surface, mirroring the watchlist's (SourcesView) and the days off sheet
// (DaysOffView).
//
// Two sections, held apart in WORDS, because he can only edit one of them. His OWN refusals are the stored
// rows, removable in place and reversible from the banner (#845). The SEED (the built-in far towns) is
// read-only: it lives in code so he never had to refuse the obvious ones, and taking one of those back is
// a different, larger change this sheet does not make.
//
// Removing one of his refusals re-decides every affected row at once with no migration, because the
// geography verdict is DERIVED, not stored (#990): QueueView reads the ExcludedTown rows through a @Query
// and re-resolves each show's place whenever they change. Deleting a row here is the whole of the change;
// the queue follows on its own.
struct ExcludedTownsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback
    // Bound, so a Remove redraws this sheet the instant the row is gone. The seed half is read the same
    // way through the tested listing, so the two can never disagree about what is skipped.
    @Query(sort: \ExcludedTown.town) private var userRows: [ExcludedTown]
    // #1221: bound so an Allow / Skip again redraws the seed sections the instant a row changes, the same
    // way userRows drives his own half. The tested listing reads the same rows, so the two cannot disagree.
    @Query(sort: \AllowedSeedTown.town) private var allowedRows: [AllowedSeedTown]

    private var listing: ExcludedTownEditing.Listing { ExcludedTownEditing.listing(in: context) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(OVColor.line)

            CappedScrollView(maxHeight: 460) {
                VStack(alignment: .leading, spacing: OVSpacing.lg) {
                    yourTowns
                    allowedBack
                    alwaysSkipped
                }
                .padding(OVSpacing.lg)
            }
        }
        .frame(width: 560)
        .background(OVColor.canvas)
        // #845: its own banner. A sheet is a separate window on macOS, so the Undo this sheet offers would
        // otherwise be drawn behind it.
        .actionFeedbackBanner()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Skipped towns").font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
                Text("Towns Overture keeps out of your queue.")
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(OVSpacing.lg)
    }

    // MARK: - Dan's half: his to take back

    private var yourTowns: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            sectionHeading("Towns you skipped", systemImage: "hand.raised", count: userRows.count)

            if userRows.isEmpty {
                Text("None yet. Refuse a town from a show and it lands here, where you can take it back.")
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(userRows) { row in
                    HStack(spacing: OVSpacing.sm) {
                        Text(ExcludedTownEditing.displayName(row.town))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(OVColor.ink)
                        Spacer()
                        Button("Remove") { remove(row.town) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OVColor.forest)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    // MARK: - The built-in half: skipped from the start, and now his to take back too (#1221)

    private var alwaysSkipped: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            sectionHeading("Always skipped", systemImage: "map", count: listing.seedSkipped.count)
            // Says something the heading does not: these are built in, so he never had to refuse them, and
            // (since #1221) Allow takes one back if a presenter he now follows starts programming there.
            Text("Far towns skipped from the start. Allow one back if you now want its shows.")
                .font(.system(size: 11)).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(listing.seedSkipped, id: \.self) { town in
                HStack(spacing: OVSpacing.sm) {
                    Text(ExcludedTownEditing.displayName(town))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(OVColor.ink)
                    Spacer()
                    Button("Allow") { allow(town) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OVColor.forest)
                }
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: - Built-in towns he has taken back (#1221)

    @ViewBuilder private var allowedBack: some View {
        if !listing.seedAllowed.isEmpty {
            VStack(alignment: .leading, spacing: OVSpacing.xs) {
                sectionHeading("Allowed back in", systemImage: "map.circle", count: listing.seedAllowed.count)
                Text("Built-in towns you took back onto the queue. Skip again to undo.")
                    .font(.system(size: 11)).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(listing.seedAllowed, id: \.self) { town in
                    HStack(spacing: OVSpacing.sm) {
                        Text(ExcludedTownEditing.displayName(town))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(OVColor.ink)
                        Spacer()
                        Button("Skip again") { reskip(town) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OVColor.forest)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    // #1417: all three live in ExcludedTownMutations now, so their wording, their Undos, and the rule
    // that none of them claims success before the change is saved are stated once and are testable (#863).
    private func allow(_ town: String) {
        ExcludedTownMutations.allow(town, context: context, feedback: feedback)
    }

    private func reskip(_ town: String) {
        ExcludedTownMutations.reskip(town, context: context, feedback: feedback)
    }

    private func remove(_ town: String) {
        ExcludedTownMutations.remove(town, context: context, feedback: feedback)
    }

    private func sectionHeading(_ title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: OVSpacing.xxs) {
            Image(systemName: systemImage).font(.system(size: 11))
            Text(title).font(.system(size: 12, weight: .semibold))
            Text("(\(count))").font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
        }
        .foregroundStyle(OVColor.ink)
    }
}
