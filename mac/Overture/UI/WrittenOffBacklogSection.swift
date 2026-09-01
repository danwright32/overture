import SwiftUI
import SwiftData

// Milestone 61 Phase 0.3: the shows a paid check wrote off as unreachable that turned out to hold a
// route all along, beside the other reports saying what the store is telling Dan.
//
// A SECTION rather than a sheet, on `EmptyAnswerSection`'s precedent and for its reason: a toolbar
// button is never free (SwiftUI's builder tops out at ten children and the row already overflows into
// the macOS ">>" menu), and this belongs beside its siblings, because all of them answer "what is the
// store telling me" rather than "what do I do next".
struct WrittenOffBacklogSection: View {
    @Query private var prospects: [Prospect]

    var body: some View {
        let report = WrittenOffBacklog.make(from: prospects)
        VStack(alignment: .leading, spacing: OVSpacing.md) {
            Text(WrittenOffBacklogCopy.title).font(OVType.groupName).foregroundStyle(OVColor.ink)
            if report.total == 0 {
                // The empty branch says what WOULD appear, because a heading over nothing reads as a
                // section that is broken rather than one with nothing to report (#1547).
                Text(WrittenOffBacklogCopy.nothingContradicted)
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(WrittenOffBacklogCopy.summary(count: report.total))
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(report.rows) { row in
                    // The show and the room, and nothing else. Every row here carries the SAME prior
                    // claim ("No email found"), which the summary line above states once, so repeating
                    // it per row would say what the line next to it already said (#843).
                    HStack(alignment: .firstTextBaseline, spacing: OVSpacing.sm) {
                        Text(row.groupName).font(OVType.body).foregroundStyle(OVColor.ink)
                        if let venue = row.venue {
                            Spacer(minLength: OVSpacing.sm)
                            Text(venue).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                        }
                    }
                }
            }
        }
    }
}

enum WrittenOffBacklogCopy {
    static let title = "Shows written off that could be reached"
    // Says what is TRUE of this list rather than what could fill it. The marker is written once, by the
    // one-time repair, and by nothing else ever, so "if one has, they appear here" would promise a list
    // that can never grow (L11).
    static let nothingContradicted = "When Overture reviewed every stored answer, no show turned out to have been recorded as unreachable while it held a way in."

    static func summary(count: Int) -> String {
        count == 1
            ? "1 show was recorded as having no email to write to while it held a way in. Overture has since corrected it:"
            : "\(count) shows were recorded as having no email to write to while they held a way in. Overture has since corrected them:"
    }
}
