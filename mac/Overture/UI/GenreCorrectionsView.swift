import SwiftUI
import SwiftData

// #2688: the report a PERSON reads and turns into a change to `EventClassifier`'s word lists.
//
// Deliberately nothing automatic. An automatic vocabulary would be a second writer of the genre with no
// reviewer, and the whole reason the current classifier is trustworthy is that its rules can be read.
// This says which words would pay off, in order; the change itself goes through the ordinary test suite.
struct GenreCorrectionsSection: View {
    @Query private var corrections: [GenreCorrection]

    var body: some View {
        let report = GenreCorrectionReport.build(from: corrections.sorted { $0.correctedAt < $1.correctedAt })
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            Text(GenreCorrectionReportCopy.title)
                .font(OVType.groupName).foregroundStyle(OVColor.ink)
            Text(report.summary)
                .font(OVType.body).foregroundStyle(OVColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            // What it CANNOT know, said every time rather than only when the list is short, because a
            // partial history presented as a complete one is the thing this line exists to prevent (L11).
            Text(report.provenance)
                .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            if !report.suggestions.isEmpty {
                // #2159/L76: macOS hides scrollbars until a gesture starts, so a plain capped box at rest
                // is pixel-identical to one showing everything it has. This list is exactly the kind that
                // grows.
                CappedScrollView(maxHeight: 300) {
                    VStack(alignment: .leading, spacing: OVSpacing.sm) {
                        ForEach(report.suggestions, id: \.word) { s in
                            HStack(alignment: .firstTextBaseline, spacing: OVSpacing.sm) {
                                Text(s.word).font(OVType.body).foregroundStyle(OVColor.ink)
                                Text(GenreCorrectionReportCopy.suggestion(discipline: s.discipline,
                                                                          count: s.count))
                                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, OVSpacing.lg)
    }
}
