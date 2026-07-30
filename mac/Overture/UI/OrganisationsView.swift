import SwiftUI
import SwiftData

// #1731: what Overture is treating as a building, said out loud.
//
// The producer gate silently decides, for every presenter in the store, whether it is a company or the
// building's own brand. That verdict decides whether one paid contact answer stands for many shows and
// whether the presenter is named on a card at all, and its only visible trace was a name quietly NOT
// appearing, which is indistinguishable from a bug.
//
// EVIDENCE ONLY, on Dan's call (2026-07-29). Corrections stay on the row, where he can see the card they
// apply to, so this sheet never mutates anything. That is also why it needs no action feedback banner,
// unlike ExcludedTownsView which it otherwise mirrors.
//
// The organisations most likely to be judged WRONG lead (#1729), because the rest of the list is
// Overture working correctly and a person reads the top of a list.
struct OrganisationsView: View {
    @Environment(\.dismiss) private var dismiss
    // Bound, so a correction made on a row while this is open redraws it rather than showing a stale
    // verdict: the gate reads these two sets, so the listing must be rebuilt when either changes.
    @Query private var prospects: [Prospect]
    @Query private var promoted: [PromotedProducer]
    @Query private var demoted: [DemotedHouse]

    @State private var search = ""

    // Built once per redraw, never per row. Deciding this walks every presenter in the store against every
    // venue spelling in it, which is a cost a row must not pay while it is being drawn (#1687, #1121).
    private var entries: [OrganisationListing.Entry] {
        OrganisationListing.build(
            shows: prospects.map {
                OrganisationListing.Show(presenter: $0.presenter, venue: $0.venue, title: $0.groupName)
            },
            overrides: ProducerOverrides(promotedRows: promoted, demotedRows: demoted))
    }

    private var shortlist: [OrganisationListing.Entry] {
        let minimum = OrganisationListing.shortlistMinimumRows
        let refused = entries.filter { $0.verdict == .paidForSeparately }
        let uncorrected = refused.filter { $0.standing == .none }
        return uncorrected.filter { $0.rowCount >= minimum }
    }

    private var matches: [OrganisationListing.Entry] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return entries.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(OVColor.line)
            ScrollView {
                VStack(alignment: .leading, spacing: OVSpacing.lg) {
                    worthALook
                    treatedAsTheVenue
                    shareOneAnswer
                    lookAnyOneUp
                }
                .padding(OVSpacing.lg)
            }
            .frame(maxHeight: 460)
        }
        .frame(width: 560)
        .background(OVColor.canvas)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Presenters").font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
                // Says what the list is FOR, which the one-word title cannot: these verdicts decide whose
                // name a card prints and what Dan pays to research.
                Text("Who Overture thinks puts each show on, and who it reads as the building.")
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(OVSpacing.lg)
    }

    // MARK: - #1729: the ones most likely to be wrong

    private var worthALook: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            sectionHeading("Worth a look", systemImage: "questionmark.circle", count: shortlist.count)
            // Earns its place: it says what to DO with the section, which the heading does not, and warns
            // that these are guesses rather than verdicts.
            Text("Overture kept these as companies, but their shows sit oddly. Correct one from any of its shows if it looks wrong.")
                .font(.system(size: 11)).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if shortlist.isEmpty {
                Text("Nothing looks odd right now.")
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
            } else {
                ForEach(shortlist) { row(for: $0, detail: OrganisationListing.evidenceLine($0)) }
            }
        }
    }

    // MARK: - #1731: the question this sheet was filed to answer

    private var treatedAsTheVenue: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            let buildings = entries.filter { $0.verdict == .theBuilding }
            sectionHeading("Read as the building", systemImage: "building.2", count: buildings.count)
            Text("Their name is never printed on a card and their address is never used as a contact.")
                .font(.system(size: 11)).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(buildings) { entry in
                row(for: entry, detail: entry.reason.map(OrganisationListing.reasonLine) ?? "")
            }
        }
    }

    // MARK: - where a wrong verdict costs money

    private var shareOneAnswer: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            let producers = entries.filter { $0.verdict == .sharesOneAnswer }
            sectionHeading("One answer covers all their shows", systemImage: "arrow.triangle.branch",
                           count: producers.count)
            // The money sentence. This is the only section where being wrong costs a contact answer being
            // spread across shows it does not belong to, which is what #1593 was built to prevent.
            Text("So a wrong one here spreads a contact across shows it has nothing to do with.")
                .font(.system(size: 11)).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(producers) { row(for: $0, detail: OrganisationListing.evidenceLine($0)) }
        }
    }

    // MARK: - everything else, on demand

    private var lookAnyOneUp: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            sectionHeading("Look one up", systemImage: "magnifyingglass", count: entries.count)
            // The sections above are the interesting ones; the rest of the store is Overture working
            // correctly, and listing all of it would bury them. Search is how nothing becomes unreachable.
            Text("Every organisation Overture knows about, including the ones it read correctly.")
                .font(.system(size: 11)).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            OVSearchField(query: $search, placeholder: "Find an organisation",
                          clearLabel: "Clear the organisation search")
            ForEach(matches) { entry in
                row(for: entry, detail: entry.reason.map(OrganisationListing.reasonLine)
                    ?? OrganisationListing.evidenceLine(entry))
            }
        }
    }

    private func row(for entry: OrganisationListing.Entry, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.name)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(OVColor.ink)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11)).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
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
