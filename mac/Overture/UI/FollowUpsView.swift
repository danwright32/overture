import SwiftUI
import SwiftData

// Who's due for a gentle re-touch (#45): prospects sent a while ago with no response yet,
// under the 2-nudge cap. Each is sent only on Dan's explicit confirm — nothing autonomous,
// and the sequence stops itself the moment someone replies or books.
struct FollowUpsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var prospects: [Prospect]
    @State private var pending: PendingNudge?

    private struct PendingNudge: Identifiable {
        let id: String        // prospect naturalKey
        let recipient: String
        let preview: String
    }

    private var due: [Prospect] {
        FollowUp.due(from: prospects, now: Date())
            .sorted { ($0.sentAt ?? .distantPast) < ($1.sentAt ?? .distantPast) }
    }

    private var gmailConnected: Bool { GmailAuthManager.shared.isConnected }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Follow-ups due").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Text("\(due.count)").font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(OVSpacing.lg)
            Divider()
            if due.isEmpty {
                Text("Nothing to nudge. Prospects you've emailed show up here once it's time for a gentle follow-up, and drop off the moment they reply or book.")
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(OVSpacing.xl)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: OVSpacing.xs) {
                        ForEach(due) { p in row(p); Divider() }
                    }
                    .padding(OVSpacing.lg)
                }
            }
        }
        .frame(width: 500, height: 560)
        .background(OVColor.canvas)
        .alert("Send this follow-up now?",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { p in
            Button("Send") { performNudge(p.id) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { p in
            Text("To: \(p.recipient)\n\n\(p.preview)\n\nThis sends one follow-up right now, to this recipient only. Nothing else goes out.")
        }
    }

    private func row(_ p: Prospect) -> some View {
        HStack(alignment: .top, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
                Text("\(p.contactEmail ?? "no contact") · nudge \(p.followUpCount + 1) of \(FollowUpConfig().maxFollowUps)")
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft)
            }
            Spacer(minLength: OVSpacing.sm)
            Button { requestNudge(p) } label: {
                Text("Send nudge").font(OVType.meta).foregroundStyle(OVColor.onForest)
                    .padding(.horizontal, OVSpacing.md).padding(.vertical, 6)
                    .background(Capsule().fill(OVColor.forest))
            }
            .buttonStyle(.plain)
            .disabled(!gmailConnected || p.contactEmail == nil)
            .help(gmailConnected ? "Review and send a gentle follow-up" : "Connect Gmail first")
        }
        .padding(.vertical, OVSpacing.xs)
    }

    private func requestNudge(_ p: Prospect) {
        guard let email = p.contactEmail else { return }
        let preview = "Subject: \(FollowUp.nudgeSubject(groupName: p.groupName))\n\n"
            + FollowUp.nudgeBody(contactName: p.contactName, groupName: p.groupName, venue: p.venue)
        pending = PendingNudge(id: p.naturalKey, recipient: email, preview: preview)
    }

    private func performNudge(_ naturalKey: String) {
        pending = nil
        guard let p = prospects.first(where: { $0.naturalKey == naturalKey }) else { return }
        _ = SendService.sendFollowUp(p, now: Date(), sender: GmailSender(fromEmail: "dan@danwrightphotography.com"))
        try? context.save()
    }
}
