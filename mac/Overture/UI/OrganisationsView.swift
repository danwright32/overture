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

    // #1731: the whole derivation, built ONCE, in a value a test can count the builds of. It used to be
    // a computed property here, which SwiftUI re-reads on every access, so it rebuilt once per section and
    // again on every keystroke below. See OrganisationsSheetModel.
    private var model: OrganisationsSheetModel {
        OrganisationsSheetModel(
            shows: prospects.map {
                OrganisationListing.Show(presenter: $0.presenter, venue: $0.venue, title: $0.groupName)
            },
            overrides: ProducerOverrides(promotedRows: promoted, demotedRows: demoted))
    }

    // #1768: names one character apart, which every rule that reads a name treats as two organisations.
    // Presenters and venues together, because the split costs the same either way: a venue's typo divides
    // a room's history and the producer gate's venue count, a presenter's divides its paid contact answer.
    private var nearMisses: [NearMissNames.Pair] {
        let names = prospects.compactMap { $0.presenter } + prospects.compactMap { $0.venue }
        return NearMissNames.pairs(in: Array(Set(names)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(OVColor.line)
            ScrollView {
                VStack(alignment: .leading, spacing: OVSpacing.lg) {
                    worthALook(model)
                    sameNameTwice
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
                Text("Worth a look").font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
                // Says what the list is FOR, which the one-word title cannot: these verdicts decide whose
                Text("Organisations Overture may have read wrongly. Everything else it decided is on the show itself.")
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(OVSpacing.lg)
    }

    // MARK: - #1729: the ones most likely to be wrong

    private func worthALook(_ sheet: OrganisationsSheetModel) -> some View {
        let shortlist = sheet.shortlist
        return VStack(alignment: .leading, spacing: OVSpacing.xs) {
            sectionHeading("Kept as companies", systemImage: "questionmark.circle", count: shortlist.count)
            // Earns its place: it says what to DO, which the heading does not, and warns that these are
            // guesses rather than verdicts.
            Text("Their shows sit oddly for a company. Correct one from any of its shows if it looks wrong.")
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

    // MARK: - #1768: one name spelled two ways

    private var sameNameTwice: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            sectionHeading("Possibly one name twice", systemImage: "doc.on.doc", count: nearMisses.count)
            // Says the COST, which the heading does not, and admits the list is a guess. Overture cannot
            // merge these itself: the same closeness that catches a typo also catches two names that are
            // genuinely different, and merging those would put one company's contact on another's shows.
            Text("Each pair counts as two organisations, so nothing found for one is ever reused for the other. Some are real typos and some are simply different names.")
                .font(.system(size: 11)).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if nearMisses.isEmpty {
                Text("No names look duplicated right now.")
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
            } else {
                ForEach(nearMisses) { pair in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pair.a).font(.system(size: 12, weight: .medium)).foregroundStyle(OVColor.ink)
                        Text(pair.b).font(.system(size: 12, weight: .medium)).foregroundStyle(OVColor.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                }
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
