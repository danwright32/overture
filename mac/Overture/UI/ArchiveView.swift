import SwiftUI
import SwiftData

// The reveal task's cancellation-safe timing, extracted from ArchiveView's `.task(id:)` so a
// superseded reveal (an older search pick's task, cancelled the moment a newer one starts) can be
// proven to never scroll. Without the explicit isCancelled check, `try? await sleep(...)`
// swallows the CancellationError that caused the cancellation, so a stale task would otherwise
// carry on and scroll to its captured (now wrong) key (#633). `sleep` is injectable so a test can
// exercise this without waiting out the real delay.
enum ArchiveReveal {
    @MainActor
    static func scrollAfterDelay(
        key: String,
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        scrollTo: (String) -> Void
    ) async {
        try? await sleep(50_000_000)
        guard !Task.isCancelled else { return }
        scrollTo(key)
    }
}

// Every show Overture has ever tracked, for the cases the day to day Queue intentionally
// hides: past its bookable window, booked, closed either way, or dismissed at triage. Replaces
// DismissedView (Dismissed is now one of six independent status filters here, instead of its own
// separate screen). Reuses ProspectRowFactory exactly as the Queue does, so every row action
// (Mark menu, booking confirm, restore) behaves identically here.
struct ArchiveView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(ActionFeedback.self) private var feedback
    @Environment(DayOffOfferRequest.self) private var dayOffOffer   // #924

    @Query private var prospects: [Prospect]

    @State private var activeStatuses: Set<ArchiveStatus> = [.new, .active]
    @State private var query: String = ""
    @State private var highlightedKey: String?
    // #685: the specific contact (if any) the jump targeted, so a multi-recipient show highlights
    // that one row inside the full card instead of just the whole card.
    @State private var highlightedRecipientId: String?
    @State private var outboundSending: [String: Date] = [:]
    @State private var replySending: [String: Date] = [:]
    @State private var pendingConfirm: PendingSend?
    @State private var showReconnect = false

    var initialHighlightKey: String? = nil
    var initialHighlightRecipientId: String? = nil
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
        .sendConfirmAndReconnectAlerts(
            pendingConfirm: $pendingConfirm,
            showReconnect: $showReconnect,
            onSend: performSend,
            onConnectGmail: onConnectGmail
        )
        .onAppear {
            guard let key = initialHighlightKey else { return }
            reveal(key, recipientId: initialHighlightRecipientId)
        }
    }

    // Widens the filter to include the target's status and marks it highlighted, so jumping to a
    // show (from the global search bar's onAppear, or from this screen's own search field) always
    // lands on a visible, scrolled to row instead of silently doing nothing when the target's
    // status is not among the currently active filter chips. #685: an optional recipient narrows
    // the highlight to one contact within the card instead of the whole card.
    private func reveal(_ key: String, recipientId: String? = nil) {
        guard let target = items.first(where: { $0.id == key }) else { return }
        activeStatuses.insert(ArchiveStatus.of(target))
        highlightedKey = key
        highlightedRecipientId = recipientId
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
                        ForEach(filtered) { item in
                            row(item, context: context, feedback: feedback,
                                dayOffOffer: dayOffOffer, outboundSendSince: outboundSending[item.id])
                        }
                    }
                    .padding(OVSpacing.lg)
                }
                // task(id:) restarts whenever highlightedKey changes, so this covers both the
                // initial appearance (a jump from the global search bar) and every later reveal
                // from this screen's own search field, not just the first one.
                .task(id: highlightedKey) {
                    guard let key = highlightedKey else { return }
                    await ArchiveReveal.scrollAfterDelay(key: key) { key in
                        withAnimation { proxy.scrollTo(key, anchor: .center) }
                    }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if highlightedKey == key {
                        highlightedKey = nil
                        highlightedRecipientId = nil
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: OVSpacing.xs) {
            let empty = EmptyState.archive(hasAnyItems: !items.isEmpty)   // #885
            Text(empty.title)
                .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            Text(empty.detail)
                .font(OVType.body).foregroundStyle(OVColor.inkSoft).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(OVSpacing.xl)
    }

    // #710: internal (not private), and context/feedback/outboundSendSince threaded explicitly
    // (not read from self.context/self.feedback/self.outboundSending internally) so
    // ArchiveViewSendStateTests can call this directly without needing a real SwiftUI environment
    // hosted around a bare ArchiveView instance (self.feedback is an
    // @Environment(ActionFeedback.self) read, which traps with no ancestor view providing one) or
    // fighting an owned @State from outside a view instance. Same prop-threading fix as
    // FollowUpsView's `since` parameter.
    func row(_ item: QueueItem, context: ModelContext, feedback: ActionFeedback,
             dayOffOffer: DayOffOfferRequest = DayOffOfferRequest(), outboundSendSince: Date? = nil) -> some View {
        ProspectRowFactory.row(item, today: today, prospects: prospects, context: context, feedback: feedback,
                              dayOffOffer: dayOffOffer,
                              highlightedKey: highlightedKey, highlightedRecipientId: highlightedRecipientId,
                              outboundSendSince: outboundSendSince,
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
