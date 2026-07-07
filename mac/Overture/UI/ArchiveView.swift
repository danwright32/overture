import SwiftUI
import SwiftData

// Every show Overture has ever tracked, for the cases the day to day Queue intentionally
// hides: past its bookable window, booked, closed either way, or dismissed at triage. Replaces
// DismissedView (Dismissed is now one of six independent status filters here, instead of its own
// separate screen). Reuses ProspectRowFactory exactly as the Queue does, so every row action
// (Mark menu, booking confirm, restore) behaves identically here.
struct ArchiveView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ActionFeedback.self) private var feedback

    @Query private var prospects: [Prospect]

    @State private var activeStatuses: Set<ArchiveStatus> = [.new, .active]
    @State private var query: String = ""
    @State private var highlightedKey: String?
    @State private var outboundSending: [String: Date] = [:]
    @State private var replySending: [String: Date] = [:]
    @State private var pendingConfirm: PendingSend?
    @State private var showReconnect = false

    var initialHighlightKey: String? = nil
    var onConnectGmail: () -> Void = {}

    private var today: String { QueueModel.easternToday() }
    private var items: [QueueItem] { prospects.map(QueueItem.init) }

    private var filtered: [QueueItem] {
        items
            .filter { activeStatuses.contains(ArchiveStatus.of($0)) }
            .filter { ShowSearch.matches($0, query: query) }
            .sorted { ($0.performanceDate ?? "") > ($1.performanceDate ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filterBar
            ShowSearchField(query: $query, allItems: items) { result in
                reveal(result.id)
            }
            .padding(.horizontal, OVSpacing.lg).padding(.vertical, OVSpacing.sm)
            Divider()
            content
        }
        .frame(minWidth: 640, idealWidth: 780, maxWidth: 960, minHeight: 520, idealHeight: 720, maxHeight: 900)
        .background(OVColor.canvas)
        .actionFeedbackBanner()
        .alert("Send this email now?", isPresented: sendConfirmBinding, presenting: pendingConfirm) { pending in
            Button("Send") { performSend(pending.id) }
            Button("Cancel", role: .cancel) { pendingConfirm = nil }
        } message: { pending in
            Text("To: \(pending.confirmation.recipient)\nSubject: \(pending.confirmation.subject)\n\nThis sends one email right now, to this recipient only. Nothing else goes out.")
        }
        .alert("Reconnect Gmail", isPresented: $showReconnect) {
            Button("Connect Gmail") { onConnectGmail() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Gmail access has expired or was revoked, so nothing was sent. Click Connect Gmail to reconnect, then try Send again.")
        }
        .onAppear {
            guard let key = initialHighlightKey else { return }
            reveal(key)
        }
    }

    // Widens the filter to include the target's status and marks it highlighted, so jumping to a
    // show (from the global search bar's onAppear, or from this screen's own search field) always
    // lands on a visible, scrolled to row instead of silently doing nothing when the target's
    // status is not among the currently active filter chips.
    private func reveal(_ key: String) {
        guard let target = items.first(where: { $0.id == key }) else { return }
        activeStatuses.insert(ArchiveStatus.of(target))
        highlightedKey = key
    }

    private var header: some View {
        HStack {
            Text("Archive").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            Text("\(filtered.count)").font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
            Spacer()
            Button("Done") { dismiss() }
        }
        .padding(OVSpacing.lg)
    }

    private var filterBar: some View {
        WrapHStack(spacing: OVSpacing.xs, lineSpacing: OVSpacing.xs) {
            ForEach(ArchiveStatus.allCases, id: \.self) { status in
                FilterChip(label: status.label, active: activeStatuses.contains(status)) {
                    if activeStatuses.contains(status) {
                        activeStatuses.remove(status)
                    } else {
                        activeStatuses.insert(status)
                    }
                }
            }
        }
        .padding(.horizontal, OVSpacing.lg).padding(.vertical, OVSpacing.sm)
    }

    @ViewBuilder private var content: some View {
        if filtered.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: OVSpacing.md) {
                        ForEach(filtered) { item in row(item) }
                    }
                    .padding(OVSpacing.lg)
                }
                // task(id:) restarts whenever highlightedKey changes, so this covers both the
                // initial appearance (a jump from the global search bar) and every later reveal
                // from this screen's own search field, not just the first one.
                .task(id: highlightedKey) {
                    guard let key = highlightedKey else { return }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    withAnimation { proxy.scrollTo(key, anchor: .center) }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if highlightedKey == key { highlightedKey = nil }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: OVSpacing.xs) {
            Text(items.isEmpty ? "Nothing scouted yet" : "Nothing matches this filter")
                .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            Text(items.isEmpty
                 ? "Shows land here once Overture has tracked at least one."
                 : "Try a different status filter, or clear the search.")
                .font(OVType.body).foregroundStyle(OVColor.inkSoft).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(OVSpacing.xl)
    }

    private func row(_ item: QueueItem) -> some View {
        ProspectRowFactory.row(item, today: today, prospects: prospects, context: context, feedback: feedback,
                              highlightedKey: highlightedKey, outboundSendSince: outboundSending[item.id],
                              replySendSince: { rid in replySending[rid] },
                              onSend: { requestSend(item) }, onSendReply: { rid in sendReply(item, rid) },
                              onRestore: item.status == .dismissed ? { restore(item) } : nil)
    }

    private func restore(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        DismissedProspects.restore(model)
        if context.saveOrWarn(org: item.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.restored(org: item.groupName))
        }
    }

    private var sendConfirmBinding: Binding<Bool> {
        Binding(get: { pendingConfirm != nil }, set: { if !$0 { pendingConfirm = nil } })
    }

    private func requestSend(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let confirmation = SendConfirmation(prospect: model) else { return }
        pendingConfirm = PendingSend(id: item.id, confirmation: confirmation)
    }

    private func performSend(_ naturalKey: String) {
        pendingConfirm = nil
        ProspectMutations.performSend(naturalKey, prospects: prospects, context: context, feedback: feedback,
                                      markSending: { outboundSending[$0] = Date() },
                                      clearSending: { outboundSending[$0] = nil },
                                      onNeedsReconnect: { showReconnect = true })
    }

    private func sendReply(_ item: QueueItem, _ recipientId: String) {
        ProspectMutations.sendReply(item, recipientId, prospects: prospects, context: context, feedback: feedback,
                                    markSending: { replySending[$0] = Date() },
                                    clearSending: { replySending[$0] = nil },
                                    onNeedsReconnect: { showReconnect = true })
    }
}
