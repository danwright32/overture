import SwiftUI
import SwiftData

// #2989: what the empty contact answers in the store are claiming, beside the other two reports that
// say what Dan's own decisions add up to.
//
// A SECTION rather than a sheet, following `GenreCorrectionsSection`'s precedent and for its reason: a
// toolbar button is never free (SwiftUI's builder tops out at ten children and the row already overflows
// into the macOS ">>" menu), and this belongs beside its siblings anyway, because all three answer "what
// is the store telling me" rather than "what do I do next".
struct EmptyAnswerSection: View {
    @Query private var prospects: [Prospect]

    var body: some View {
        let report = EmptyAnswerReport.make(from: prospects)
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            Text(EmptyAnswerCopy.title).font(OVType.groupName).foregroundStyle(OVColor.ink)
            if report.total == 0 {
                // The empty branch says what WOULD appear, because a heading over nothing reads as a
                // section that is broken rather than one with nothing to report (#1547).
                Text(EmptyAnswerCopy.nothingEmpty)
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(EmptyAnswerCopy.summary(count: report.total))
                    .font(OVType.body).foregroundStyle(OVColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: OVSpacing.xs) {
                    ForEach(report.byReason, id: \.reason) { line in
                        HStack(alignment: .firstTextBaseline, spacing: OVSpacing.sm) {
                            Text("\(line.count)").font(OVType.body).foregroundStyle(OVColor.ink)
                                .frame(minWidth: 24, alignment: .trailing)
                            Text(EmptyAnswerReport.label(for: line.reason))
                                .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                // The cross-cut, which is the whole reason this section exists rather than the table
                // above it. Shown only when the claim is actually being made, because a line about
                // nothing is a line that teaches Dan to skip this section (L36).
                // #3356 Phase 0.5: what this report deliberately does NOT count, so a corrected number
                // cannot be mistaken for a shrinking one (L11, L98). Shown only when there is something
                // to exclude, so a clean store never grows a permanent line saying nothing.
                if report.contradictedByVerdict > 0 {
                    Text(EmptyAnswerCopy.contradictedByVerdict(report.contradictedByVerdict))
                        .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Its own line and its own sentence, because a reason contradicted by a verdict and a
                // reason nothing ever judged are different faults with different remedies.
                if report.reasonWithNoVerdict > 0 {
                    Text(EmptyAnswerCopy.reasonWithNoVerdict(report.reasonWithNoVerdict))
                        .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if report.nothingPublishedWithAPresenter > 0 {
                    Text(EmptyAnswerCopy.withAPresenter(report.nothingPublishedWithAPresenter))
                        .font(OVType.body).foregroundStyle(OVColor.gold)
                        .fixedSize(horizontal: false, vertical: true)
                    // What the number CANNOT separate, said every time rather than left to be inferred,
                    // the same rule the genre report's provenance line follows (L11).
                    Text(EmptyAnswerReport.presenterCaveat)
                        .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// The section's own words, beside it rather than inside the view body, so they reach
// `docs/copy-inventory.md` and get read cold.
enum EmptyAnswerCopy {
    static let title = "Checks that came home empty"
    static let nothingEmpty = "No check has come home without a contact. When one does, what it claimed appears here."

    static func summary(count: Int) -> String {
        count == 1
            ? "1 show has been checked and left with nobody to write to. What the check claimed:"
            : "\(count) shows have been checked and left with nobody to write to. What the checks claimed:"
    }

    // The claim itself is on the row directly above this line, so repeating it here would tell Dan
    // nothing the line next to it did not (#843). What this adds is the contradiction.
    static func withAPresenter(_ count: Int) -> String {
        count == 1
            ? "1 of those is a show that names its producing organisation."
            : "\(count) of those are shows that name their producing organisation."
    }
}
