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
    // #1414: the session undo stack, owned by the App and injected, so keep and dismiss record.
    // OPTIONAL deliberately: a non-optional Observable environment lookup FATAL ERRORS when the object
    // is absent, which would turn a missed injection into a crash of the whole app (and does crash any
    // test that builds this view directly). Nil simply means this surface records nothing.
    @Environment(QueueUndoStack.self) private var undoStack: QueueUndoStack?
    @Environment(\.dismiss) private var dismiss
    @Environment(ActionFeedback.self) private var feedback
    @Environment(DayOffOfferRequest.self) private var dayOffOffer   // #924

    @Query private var prospects: [Prospect]
    // #1598 Phase 5: the organisation answer ledger, so an archived row reads the same as it does in the
    // queue. Unlike QueueView this query is already the WHOLE store, so it doubles as the gate's corpus.
    @Query private var orgAnswers: [OrgReachabilityAnswer]

    @State private var activeStatuses: Set<ArchiveStatus> = ArchiveOpening.defaultStatuses
    @State private var query: String = ""
    @State private var highlightedKey: String?
    // #685: the specific contact (if any) the jump targeted, so a multi-recipient show highlights
    // that one row inside the full card instead of just the whole card.
    @State private var highlightedRecipientId: String?
    @State private var outboundSending: [String: Date] = [:]
    @State private var replySending: [String: Date] = [:]
    @State private var pendingConfirm: PendingSend?
    @State private var showReconnect = false
    // #976: the show at the top of the scroll, bound so the list holds its place while its rows rebuild.
    // `prospects` is a @Query, so any scout, Prep, send, or reply that touches one re-emits it and
    // rebuilds this list, and a plain ScrollView drops its offset to the top on every one of those (the
    // exact #974 shape SourcesView already carries). The identity is the show's own key, the SAME space
    // the reveal jump below scrolls by, so a search or deep-link jump and this restore agree rather than
    // fight: reveal sets this to its target before it scrolls, so the later rebuild holds the revealed
    // row instead of yanking back to a stale top.
    @State private var topKey: String?

    var initialHighlightKey: String? = nil
    var initialHighlightRecipientId: String? = nil
    // #1580: a search the queue's own bar could not answer, handed over rather than retyped. The shows
    // that bar can no longer find all sit outside the two status chips Archive normally opens on, so
    // ArchiveOpening widens them: otherwise the jump lands on an empty list right after saying there
    // were three matches.
    var initialQuery: String = ""
    var onConnectGmail: () -> Void = {}

    private var today: String { QueueModel.easternToday() }
    private var items: [QueueItem] { QueueModel.items(from: prospects, answers: orgAnswers) }

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
            query = initialQuery
            activeStatuses = ArchiveOpening.statuses(forQuery: initialQuery)
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
                    .scrollTargetLayout()
                    .padding(OVSpacing.lg)
                }
                // #976: hold the scroll where Dan left it across a @Query rebuild (see topKey).
                .scrollPosition(id: $topKey, anchor: .top)
                // task(id:) restarts whenever highlightedKey changes, so this covers both the
                // initial appearance (a jump from the global search bar) and every later reveal
                // from this screen's own search field, not just the first one.
                .task(id: highlightedKey) {
                    guard let key = highlightedKey else { return }
                    await ArchiveReveal.scrollAfterDelay(key: key) { key in
                        // #976: point the persisted position at the reveal's target FIRST, so the
                        // restore cooperates with the jump instead of racing it back to a stale row.
                        topKey = key
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
                              undoStack: undoStack,
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
              var confirmation = SendConfirmation(prospect: model) else { return }
        // #1244: the Archive send path warns on a same-date self double-booking too, using the SAME shared
        // helper as the main queue's requestSend, so the guard doesn't depend on which screen Dan sends from.
        confirmation.selfBookingWarning = QueueModel.sendSelfBookingWarning(for: item, among: items)
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
