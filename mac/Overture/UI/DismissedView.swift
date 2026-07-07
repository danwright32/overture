import SwiftUI
import SwiftData

// The dismissed pile (#28): everything Dan cut, newest first, each restorable in one
// click so a mistaken dismiss is never permanent. Opened as a sheet from the toolbar.
struct DismissedView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ActionFeedback.self) private var feedback   // #285

    @Query(filter: #Predicate<Prospect> { $0.statusRaw == "dismissed" },
           sort: [SortDescriptor(\Prospect.ingestedAt, order: .reverse)])
    private var dismissed: [Prospect]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Dismissed").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Text("\(dismissed.count)").font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(OVSpacing.lg)
            Divider()
            if dismissed.isEmpty {
                Text("Nothing dismissed. Cuts you make in the queue show up here, ready to restore.")
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(OVSpacing.xl)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: OVSpacing.xs) {
                        ForEach(dismissed) { p in
                            row(p)
                            Divider()
                        }
                    }
                    .padding(OVSpacing.lg)
                }
            }
        }
        .frame(width: 480, height: 540)
        .background(OVColor.canvas)
        .actionFeedbackBanner()
    }

    private func row(_ p: Prospect) -> some View {
        HStack(alignment: .top, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
                HStack(spacing: 6) {
                    Text(p.venue ?? "Venue TBD")
                    if let label = reasonLabel(p) {
                        Text("·").foregroundStyle(OVColor.inkFaint)
                        Text(label)
                    }
                }
                .font(OVType.body).foregroundStyle(OVColor.inkSoft)
            }
            Spacer(minLength: OVSpacing.sm)
            Button { restore(p) } label: {
                Text("Restore").font(OVType.meta).foregroundStyle(OVColor.onForest)
                    .padding(.horizontal, OVSpacing.md).padding(.vertical, 6)
                    .background(Capsule().fill(OVColor.forest))
            }
            .buttonStyle(.plain)
            .help("Put this prospect back in the queue as undecided")
        }
        .padding(.vertical, OVSpacing.xs)
    }

    private func reasonLabel(_ p: Prospect) -> String? {
        p.dismissReasonRaw.flatMap(DismissReason.init)?.label
    }

    private func restore(_ p: Prospect) {
        DismissedProspects.restore(p)
        if context.saveOrWarn(org: p.groupName, feedback: feedback) {
            // #285: the row leaves this sheet, but it lands back in the queue offscreen; confirm that.
            feedback.acknowledge(ActionAck.restored(org: p.groupName))
        }
    }
}
