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
                ForEach(report.rows, id: \.naturalKey) { row in
                    HStack(alignment: .firstTextBaseline, spacing: OVSpacing.sm) {
                        Text(row.groupName).font(OVType.body).foregroundStyle(OVColor.ink)
                        Spacer(minLength: OVSpacing.sm)
                        Text(WrittenOffBacklogCopy.priorVerdict(row.priorResult))
                            .font(OVType.caption).foregroundStyle(OVColor.inkSoft)
                    }
                }
                if report.unattributed > 0 {
                    Text(WrittenOffBacklogCopy.unattributed(report.unattributed))
                        .font(OVType.caption).foregroundStyle(OVColor.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

enum WrittenOffBacklogCopy {
    static let title = "Shows written off that could be reached"
    static let nothingContradicted = "No check has claimed a show was unreachable while the show held a way in. If one has, the shows appear here."

    static func summary(count: Int) -> String {
        count == 1
            ? "1 show was recorded as having no way in while it held one. The check's own claim, beside it:"
            : "\(count) shows were recorded as having no way in while they held one. Each check's own claim, beside it:"
    }

    // The row already names the show, so repeating that would tell Dan nothing the line beside it did
    // not (#843). What this adds is WHICH claim the check made, since those are different findings.
    static func priorVerdict(_ result: Reachability.ProbeResult?) -> String {
        guard let result else { return "claim not readable" }
        switch result {
        case .noEmailFound: return "said no email found"
        case .socialOnly: return "said social only"
        case .contactFormOnly: return "said contact form only"
        case .weakContactOnly: return "said weak contact only"
        case .emailFound: return "said email found"
        }
    }

    static func unattributed(_ count: Int) -> String {
        count == 1
            ? "1 of those was recorded by a later version of Overture, so this build cannot say which claim it made."
            : "\(count) of those were recorded by a later version of Overture, so this build cannot say which claims they made."
    }
}
