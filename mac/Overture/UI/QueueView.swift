import SwiftUI
import SwiftData
import AppKit

// The window Dan lives in: ranked performances, grouped by date, kept or dismissed.
struct QueueView: View {
    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback   // #285: shared acknowledgment surface
    @Environment(DayOffOfferRequest.self) private var dayOffOffer   // #924: dismiss-to-day-off picker request

    // Dismissed prospects drop out of the queue; the rest sort date asc, fit desc. The
    // "hide untouched-gone" rule (#133) lives in QueueModel.queueOrder, not here, because a
    // compound predicate overruns the #Predicate type-checker.
    @Query(
        filter: #Predicate<Prospect> { $0.statusRaw != "dismissed" },
        sort: [SortDescriptor(\Prospect.performanceDate, order: .forward),
               SortDescriptor(\Prospect.fitScore, order: .reverse)]
    )
    private var prospects: [Prospect]

    // #991: Dan's stored town refusals. A @Query so ADDING one re-renders the queue and the gate
    // re-decides every row against the new union at once, which is the "no migration" property #990's
    // derived verdict makes possible.
    @Query private var excludedTownRows: [ExcludedTown]
    private var userExcludedTowns: Set<String> { Set(excludedTownRows.map(\.town)) }

    @State private var pendingConfirm: PendingSend?
    @State private var showReconnect = false
    // #436: in-flight sends, so a tapped Send shows a live "Sending…" state instead of a dead button.
    // Outbound keyed by prospect natural key; replies keyed by recipient id. Cleared when the await ends.
    @State private var outboundSending: [String: Date] = [:]
    @State private var replySending: [String: Date] = [:]
    // #361: shows that have just been fully sent and are playing their leaving delight (gold seal +
    // drawn line, then a glide-up exit). Keyed by natural key to the snapshot to render while it
    // departs, since the real row has already left `visible` once the send lands in the data.
    @State private var departing: [String: QueueItem] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // #236: a lead opened from an OmniFocus deep link. When it changes, the queue switches to the
    // pipeline holding it, clears filters that would hide it, scrolls to it, and briefly highlights it.
    @Binding var deepLinkedKey: String?
    @State private var highlightedKey: String?
    // #976: the date group at the top of the scroll, bound so the queue holds its place while the rows
    // underneath rebuild. `prospects` is a @Query and this is the window Dan reviews in (~119 shows),
    // rebuilt by every scout and Prep run; a plain ScrollView drops its offset to the top on each one
    // (the #974 shape), so mid review the queue snaps away before he can act on a row. Pinned to the top
    // visible date group, not the individual show, because the groups are the stable landmarks a run
    // reshuffles shows within. Only the to-send date list carries the scroll target layout, so this stays
    // nil (no restore, nothing to fight) while the reached-out list or a focused lead view is showing, and
    // the intentional jumps clear it so a rebuilt restore can never override proxy.scrollTo (see below).
    @State private var topGroup: String?

    // #308: the new leads from a tapped multi-lead away alert. When it changes, the queue enters a
    // focused mode showing exactly those leads (a flat list, ignoring the pipeline split and filters so
    // even a booked lead that falls out of both pipelines still appears), with a "Show all" exit.
    @Binding var deepLinkedKeys: [String]?
    @State private var focusedKeys: [String]?
    // #1140: which STAGE the focused view is showing, when it was entered by tapping a stage pill (nil
    // for the #308 away-alert leads path). Set, the focused list re-derives its membership and heading
    // live from this stage on every render, so a show that leaves the stage (a draft sent) drops out
    // instead of lingering on a key set frozen at tap time.
    // #1134: stage-only navigation is the only mode, so the queue opens on Scout by default (the
    // away-alert leads path and a deep link override this on their onChange). Never auto-jumps off an
    // empty Scout: an empty stage shows its own empty state instead.
    @State private var focusedStage: StageFocus? = StageNavigation.openingStage
    // #338: the heading focusedSection shows while focused. nil falls back to the #308
    // away-leads phrasing; a stage-pill tap sets an explicit one instead. #1140: in stage mode this is a
    // fallback only; the heading is recomputed live from `focusedStage` while it is set.
    @State private var focusedHeading: String?

    // #488: lets the Reconnect Gmail alert start the same OAuth flow the onboarding screen uses,
    // instead of just telling Dan to go find the button himself.
    var onConnectGmail: () -> Void = {}
    // #338: the Follow-ups pill reuses the existing FollowUpsView sheet (owned by RootView)
    // instead of a second filtered-list implementation of the same thing.
    var onShowFollowUps: () -> Void = {}
    // #682: unlike the generic Follow-ups pill above, the reached-out row's own "Send a follow-up"
    // button knows exactly which contact Dan clicked from, so it opens the sheet with that
    // recipient highlighted instead of leaving him to find it again in what could be a longer list.
    var onShowFollowUpsFor: (_ recipientId: String) -> Void = { _ in }
    // #683: the lightweight reached-out row has no reply text, AI reply drafter, or Mark… menu
    // (deliberately not duplicated here, see #661); this jumps to the full card that still has
    // them, reusing RootView's existing archive-highlight mechanism (#236/#308) rather than a
    // second one. #685: also carries which contact Dan clicked from, so a multi-recipient show
    // highlights that one instead of just the whole card.
    var onOpenInArchive: (_ key: String, _ recipientId: String?) -> Void = { _, _ in }
    // #1129: a discoverable "Prep these N" button in the Prep stage view starts a Prep run through
    // RootView's existing #953 selection-sheet flow (mirrors the readOne closure SourcesView receives),
    // so a first-time user need not know the Cmd+P shortcut or the toolbar menu. Declared last so the
    // RootView call site can keep onOpenInArchive near the top for ReachedOutRowArchiveJumpGuardTests.
    var onStartPrep: () -> Void = {}

    private var items: [QueueItem] { QueueModel.items(from: prospects) }

    private var today: String { QueueModel.easternToday() }

    // #1129: a Prep run is in flight. The discoverable Prep button hides while one runs (RootView's
    // canStartPrep gates the start too); read from the same source AgentInputs.from uses.
    private var prepRunning: Bool { PrepQueueService.isRunning(now: Date()) }

    // #1121: every heavy derived collection, built ONCE per render and threaded down, instead of a
    // half-dozen computed properties each re-running QueueModel.items(from:) (a full map that faults
    // every prospect's `recipients` relationship on the main thread). A pill tap flips @State
    // (focusedKeys) and invalidates the body; before, that alone rebuilt `items` seven-plus times and
    // re-faulted the store on each one, which is what froze the machine for a beat on every switch.
    struct RenderData {
        let items: [QueueItem]
        let visible: [QueueItem]
        // Contacted RECIPIENTS Dan is still working, soonest-first. #652: one entry per recipient, so a
        // multi-contact show can appear more than once, each with its own contact and timing.
        let reachedOut: [(prospect: Prospect, recipient: Recipient, next: Date)]
        let reachedOutKeys: Set<String>
        let pendingBookings: Int
    }

    private func makeRenderData() -> RenderData {
        let items = self.items
        let now = Date()
        let reachedOut = ReachedOutQueue.activeWithDates(from: prospects, now: now)
        let reachedOutKeys = Set(reachedOut.map(\.prospect.naturalKey))
        // The masthead's at-a-glance summary reflects the actionable to-send queue (not reached-out,
        // windowed to the bookable date range with too-close events demoted). #1134 removed the filter
        // chips, so this is the whole to-send queue, unfiltered but for Dan's standing town refusals.
        let visible = QueueModel.toSendQueue(
            QueueModel.filter(items, discipline: nil, highOnly: false, pendingBookingsOnly: false,
                              tooFarOnly: false, userExcludedTowns: userExcludedTowns),
            reachedOutKeys: reachedOutKeys, today: today)
        return RenderData(items: items, visible: visible, reachedOut: reachedOut,
                          reachedOutKeys: reachedOutKeys,
                          pendingBookings: QueueModel.pendingBookingCount(items))
    }

    // The big scroll tree is lifted into a typed sub-view so the main body stays small and
    // the editor type-checks it quickly (#56); the real compiler was always fine.
    // Kept deliberately small: the toolbar, alerts, and their bindings are extracted so no
    // single expression sits near the SwiftUI type-checker's complexity threshold (#122).
    var body: some View {
        let data = makeRenderData()
        return mainContent(data)
            .sendConfirmAndReconnectAlerts(
                pendingConfirm: $pendingConfirm,
                showReconnect: $showReconnect,
                onSend: performSend,
                onConnectGmail: onConnectGmail
            )
    }

    private func mainContent(_ data: RenderData) -> some View {
        queueScroll(data)
            .background(OVColor.canvas)
    }

    private func queueScroll(_ data: RenderData) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: OVSpacing.xl) {
                    masthead(visible: data.visible, items: data.items)
                    // #1134: stage-only navigation is the only mode. The stage pills in the masthead choose
                    // what shows; this always renders the focused view for the current stage (Scout by
                    // default), or the exact away-alert leads (#308) when focusedStage is nil.
                    focusedSection(focusedKeys ?? [], data: data)
                }
                .padding(.horizontal, OVSpacing.xl)
                .padding(.vertical, OVSpacing.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            // #976: hold the scroll on the top visible date group across a @Query rebuild (see topGroup).
            .scrollPosition(id: $topGroup, anchor: .top)
            .onChange(of: deepLinkedKey) { _, key in
                if let key { navigateToLead(key, proxy: proxy) }
            }
            .onChange(of: deepLinkedKeys) { _, keys in
                if let keys, !keys.isEmpty { focusOnLeads(keys, proxy: proxy) }
            }
        }
    }

    // #1134: the one content view, driven by the current stage. Reached out renders its per-recipient
    // list (which owns its own heading and empty state); every other stage shows the standard focused
    // rows for that stage, or the #308 away-alert leads when focusedStage is nil.
    @ViewBuilder private func focusedSection(_ keys: [String], data: RenderData) -> some View {
        if focusedStage == .reachedOut {
            reachedOutList(data.reachedOut)
        } else {
            // #1140: in stage mode, re-derive membership LIVE from the current prospects (a sent draft
            // drops out); in leads mode, keep the frozen key set. The dispatch lives in
            // StageNavigation.focusedKeys so it is tested, not decided inline in this view.
            let wanted = Set(StageNavigation.focusedKeys(stage: focusedStage, leadKeys: keys,
                                                         in: prospects, today: today, now: Date()))
            // #361: fold any departing (just-sent) rows back in so each plays its leaving delight in place.
            let rows = QueueModel.withDeparting(data.items.filter { wanted.contains($0.id) },
                                                departing: departing)
            VStack(alignment: .leading, spacing: OVSpacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(focusedStageHeading(rows: rows))
                        .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                    Spacer()
                    // #1129: the discoverable Prep button, only on the Prep stage with kept shows and no
                    // run already in flight. Starts the run through RootView's existing selection sheet.
                    if PrepQueueButton.shouldShow(stage: focusedStage, keptToPrep: rows.count,
                                                  prepRunning: prepRunning) {
                        Button(PrepQueueButton.label(count: rows.count)) { onStartPrep() }
                            .buttonStyle(.borderedProminent)
                            .tint(OVColor.forest)
                    }
                }
                .padding(.bottom, OVSpacing.xxs)
                .overlay(alignment: .bottom) { Rectangle().fill(OVColor.line).frame(height: 1) }
                if rows.isEmpty {
                    if focusedStage == nil {
                        // #308: the away-alert leads path names specific leads; some may have since left.
                        Text("These leads are no longer in your queue.")
                            .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                    } else {
                        stageEmptyState(for: focusedStage ?? StageNavigation.openingStage, data: data)
                    }
                } else {
                    ForEach(rows) { item in prospectRow(item) }
                }
            }
        }
    }

    // #1134: an empty stage says what it is and, when there is work elsewhere, points Dan to the next
    // stage that has some (never auto-jumping there). The pointer logic is the pure StageEmptyState so it
    // is tested; this view just renders it in the same dashed-border card the queue used before.
    private func stageEmptyState(for stage: StageFocus, data: RenderData) -> some View {
        let counts = StageNavigation.counts(in: prospects, today: today, now: Date())
        let message = StageEmptyState.message(for: stage, counts: counts, reachedOut: data.reachedOut.count)
        return VStack(spacing: OVSpacing.xs) {
            Text(message.title).font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            Text(message.detail).font(OVType.body).foregroundStyle(OVColor.inkSoft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, OVSpacing.hero)
        .padding(.horizontal, OVSpacing.xl)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(OVColor.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }

    // #1140: the focused list's heading, recomputed live while focused on a stage so its count decrements
    // as shows leave the stage (Scout/Prep/Review map one-to-one to a live status; so does Send while its
    // most-urgent focus is still the one Dan tapped). Falls back to the heading captured at tap time (the
    // rare Send-focus-shifted case), then to the #308 away-leads phrasing.
    private func focusedStageHeading(rows: [QueueItem]) -> String {
        if let stage = focusedStage,
           let live = AgentRoster.statuses(agentInputs).first(where: { $0.focus == stage }) {
            return "\(live.name): \(live.detail)"
        }
        return focusedHeading ?? QueueModel.newLeadsHeading(count: rows.count)
    }

    // #308: enter the focused new-leads view and scroll its first (still-visible) lead into view.
    // Clears the request once handled, mirroring navigateToLead (#236). #674: a lead dismissed
    // between the notification firing and Dan tapping it is no longer in `items` at all, so this
    // scrolls to the first key that's actually there instead of blindly the first key named in the
    // (possibly stale) notification.
    private func focusOnLeads(_ keys: [String], proxy: ScrollViewProxy) {
        focusedKeys = keys
        focusedStage = nil   // #1140: a named leads set, not a stage; keep it frozen, don't re-derive.
        deepLinkedKeys = nil
        // #976: release any pinned date group so the persisted restore cannot fight this jump. The
        // focused view is a flat list without scroll targets anyway, so there is nothing to hold here.
        topGroup = nil
        let target = QueueModel.firstVisibleKey(keys, among: items)
        DispatchQueue.main.async {
            if let target { withAnimation { proxy.scrollTo(target, anchor: .top) } }
        }
    }

    // #338: tapping a stage pill (Prep/Review/Send) focuses the queue on exactly the prospects in
    // that stage, reusing the same #308 focused-list view instead of a second filtering mechanism.
    // #863: routed by the pill's FOCUS, not its name. Send reports whichever of five problems is most
    // urgent, each naming a different set of shows; by name, its tap could only ever resolve one of
    // them, so "3 sent, but replies can't be tracked" landed Dan in the approved queue, which contains
    // none of them.
    private func focusOnStage(_ status: AgentStatus) {
        // #1140: remember the STAGE, not just a snapshot of its keys, so the focused list re-derives its
        // membership live and a show that leaves the stage (a draft sent) drops out. The heading and keys
        // set here are the initial/fallback values; focusedSection recomputes both live while in stage mode.
        focusedStage = status.focus
        focusedHeading = "\(status.name): \(status.detail)"
        focusedKeys = StageNavigation.naturalKeys(for: status.focus, in: prospects, today: today, now: Date())
    }

    // #236/#1134: land on a deep-linked lead by focusing the STAGE that holds it (the pipeline picker is
    // gone), so the row is actually on screen, then scroll to it and briefly highlight it. Clears the
    // request once handled.
    private func navigateToLead(_ key: String, proxy: ScrollViewProxy) {
        // #1121: computed inline (this is a rare deep-link tap, not the render path) now that the queue's
        // reached-out keys live in the per-render RenderData snapshot rather than a standing computed prop.
        let reachedOutKeys = Set(ReachedOutQueue.activeWithDates(from: prospects, now: Date()).map(\.prospect.naturalKey))
        // #1134: focus the stage that contains this lead so its row renders; fall back to Scout if the
        // lead is in no stage (RootView routes truly unreachable leads to Archive, so this is a safety net).
        focusedStage = StageNavigation.stage(containing: key, in: prospects,
                                             reachedOutKeys: reachedOutKeys) ?? StageNavigation.openingStage
        focusedKeys = nil   // #1140: stage mode re-derives its own membership; no frozen key set
        focusedHeading = nil
        highlightedKey = key
        deepLinkedKey = nil
        // #976: release any pinned date group so a rebuild during this jump cannot restore the old top
        // over the row we are scrolling to. The scrollTo below (dispatched after the stage change lays
        // out) then owns the position, and normal scrolling re-populates topGroup afterward.
        topGroup = nil
        // Let the stage change lay out before scrolling to the row.
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(key, anchor: .center) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if highlightedKey == key { highlightedKey = nil }
        }
    }


    // #379: visible/items threaded explicitly (not read from self.visible/self.items internally)
    // so ProspectRowViewLayoutTests-style tests can call this directly with fake data instead of
    // needing a real populated store, the same prop-threading fix used repeatedly for
    // FollowUpsView/ArchiveView/QueueView's other retrofits this cycle.
    func masthead(visible: [QueueItem], items: [QueueItem]) -> some View {
        let summary = QueueModel.summary(visible)
        let pendingBookings = QueueModel.pendingBookingCount(items)
        return VStack(alignment: .leading, spacing: OVSpacing.sm) {
            HStack(spacing: OVSpacing.xs) {
                Text("Overture").font(OVType.wordmark).foregroundStyle(OVColor.forest)
                #if DEBUG
                // #377: a live app and a Debug build can be open side by side showing different
                // data, so the masthead must make it unmistakable which window this is.
                Text("Debug")
                    .font(OVType.tag)
                    .foregroundStyle(OVColor.gold)
                    .padding(.horizontal, OVSpacing.sm).padding(.vertical, 2)
                    .background(Capsule().fill(OVColor.gold.opacity(0.15)))
                #endif
            }
            Rectangle().fill(OVColor.gold.opacity(0.5)).frame(height: 1).frame(maxWidth: .infinity)
            HStack(spacing: OVSpacing.xs) {
                Text("\(summary.total)").fontWeight(.semibold).foregroundStyle(OVColor.ink)
                Text("in the queue").foregroundStyle(OVColor.inkFaint)
                Text("/").foregroundStyle(OVColor.lineStrong)
                Text("\(summary.high)").fontWeight(.semibold).foregroundStyle(OVColor.gold)
                Text("high-fit").foregroundStyle(OVColor.inkFaint)
                if pendingBookings > 0 {
                    Text("/").foregroundStyle(OVColor.lineStrong)
                    Text("\(pendingBookings)").fontWeight(.semibold).foregroundStyle(OVColor.forest)
                    Text("to confirm").foregroundStyle(OVColor.inkFaint)
                }
            }
            .font(.system(size: 12))
            // #1131: the "Of the N high-fit: ... relationship / ... merit" breakdown line was dropped from
            // the masthead (Dan does not read it). The relationship/merit split still exists as an internal
            // diagnostic on QueuePriorityBreakdown (#92); it is simply no longer surfaced here.
            // #1131: only the "Scouted X ago" half stays. The prep/review/approved counts and "last prep"
            // timing that prepStatus.summary added here are duplicated by the Prep/Review/Send pill row
            // (agentStrip) directly below, so they are dropped; "Scouted X ago" is not shown anywhere else.
            Text(ScoutStatus(lastScoutedAt: ScoutService.lastScoutedAt()).summary(now: Date()))
                .font(.system(size: 11))
                .foregroundStyle(OVColor.inkFaint)
            replyRunLine
            agentStrip
        }
    }

    // #1085: the reply-classify run's single run-level "N of M", shown once here instead of repeated on
    // every recipient row the run is drafting (DraftReviewView dropped it from its per-recipient label,
    // since the count is one run-wide fact). Wrapped in a TimelineView so it re-reads the run marker and
    // the progress file each second (#1003): the count advances as the run works and the whole line
    // vanishes the moment the run ends, rather than a value captured at this view's last render sitting
    // stale beside a run that has already finished. What the line SAYS is the pure, tested
    // ReplyClassifyProgressDecoder.runningLabel, not a sentence assembled here in the view.
    @ViewBuilder private var replyRunLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let line = ReplyClassifyProgressDecoder.runningLabel(
                running: ReplyClassifyService.isRunning(now: context.date),
                progress: ReplyClassifyProgressDecoder.loadCurrent()) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(line).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
                }
            }
        }
    }

    // Per-stage "where am I needed" indicators (#15): each stage shows a coloured dot plus
    // a label (never colour alone), with a roll-up so needs-attention is unmissable.
    // #863: lifted wholesale into AgentInputs.from, which builds every count by calling the same
    // StageNavigation predicate the pill's tap resolves. It used to be spelled out here, inside a
    // SwiftUI view, where no test could reach it, which is exactly why the invariant drifted twice
    // (#792, #861) with the rule stating itself in StageNavigation's header the whole time.
    // Counted across EVERY prospect, not just the ones still in the queue: a held contact's show has
    // usually already left the queue reading "Sent", which is how the person waiting became invisible.
    private var agentInputs: AgentInputs {
        let now = Date()
        return AgentInputs.from(
            prospects: prospects, now: now, today: today,
            gmailConnected: GmailAuthManager.shared.isConnected,
            prepRunning: PrepQueueService.isRunning(now: now),
            replyRunAlive: ReplyClassifyService.isRunning(now: now)
        )
    }

    private var agentStrip: some View {
        let statuses = AgentRoster.statuses(agentInputs)
        let needs = AgentRoster.needsYouCount(statuses)
        return VStack(alignment: .leading, spacing: OVSpacing.xs) {
            if let needsYou = AgentRoster.needsYouLabel(needs) {
                Text(needsYou)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(OVColor.rust)
            }
            WrapHStack(spacing: OVSpacing.xs, lineSpacing: OVSpacing.xs) {
                ForEach(statuses) { agentChip($0) }
            }
        }
        .padding(.top, OVSpacing.xxs)
    }

    // #338: real navigation, not just a status indicator. Follow-ups reuses the existing
    // FollowUpsView sheet; Prep/Review/Send focus the queue on that stage's prospects.
    private func agentChip(_ s: AgentStatus) -> some View {
        Button {
            switch AgentRoster.chipAction(for: s) {
            // #565: the "connect Gmail to send" detail read as an instruction with nothing behind
            // it to click; route straight to the same Gmail-connect flow #488 wires up elsewhere,
            // instead of just filtering the queue to prospects Dan still can't send to.
            case .connectGmail: onConnectGmail()
            case .showFollowUps: onShowFollowUps()
            case .focusOnStage: focusOnStage(s)
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(agentColor(s.state)).frame(width: 6, height: 6)
                Text(s.name).font(OVType.tag)
                    .foregroundStyle(s.state == .idle ? OVColor.inkFaint : OVColor.ink)
                // #1134: Reached out is idle by design (never "needs you") but is a navigation stop that
                // should still show its count, so its detail shows even while idle. Other idle pills keep
                // hiding their "Nothing new" detail as before.
                if !s.detail.isEmpty, s.state != .idle || s.focus == .reachedOut {
                    Text(s.detail).font(OVType.tag).foregroundStyle(OVColor.inkSoft)
                }
            }
            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 5)
            .background(Capsule().fill(s.state == .idle ? Color.clear : agentColor(s.state).opacity(0.12)))
            .overlay(Capsule().strokeBorder(OVColor.line, lineWidth: s.state == .idle ? 1 : 0))
        }
        .buttonStyle(.plain)
        // #332: the concept sentence (what this pill IS) alongside the live detail (what's in it
        // right now), so hovering answers "what is this" the first time, not just "how many".
        .help(AgentRoster.chipHelp(name: s.name, detail: s.detail))
    }

    private func agentColor(_ state: AgentState) -> Color {
        switch state {
        case .idle: return OVColor.inkFaint
        case .working: return OVColor.forest
        case .needsAttention: return OVColor.gold
        case .error: return OVColor.rust
        }
    }

    // #217/#652: contacts Dan has already pitched, ordered by when to next reach out to each one
    // (soonest first). A flat list rather than date groups, since the next-reach-out order is what
    // matters here. One row per RECIPIENT: a multi-contact show with two contacts due at different
    // times appears twice, each labeled with that contact's own timing. #661: a lightweight row
    // (group name, this one contact, timing, and the state control), not the entire show card, so
    // two contacts due on the same show don't render as two large, nearly-identical cards.
    @ViewBuilder private func reachedOutList(_ dated: [(prospect: Prospect, recipient: Recipient, next: Date)]) -> some View {
        if dated.isEmpty {
            VStack(spacing: OVSpacing.xs) {
                Text("No one to follow up with").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                Text("Once you have sent a pitch, the people you are waiting to hear back from show up here, soonest follow-up first. They drop off when you book them, mark them lost, or the follow-ups run out.")
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, OVSpacing.hero)
            .padding(.horizontal, OVSpacing.xl)
        } else {
            let now = Date()
            VStack(alignment: .leading, spacing: OVSpacing.sm) {
                ForEach(dated, id: \.recipient.id) { pair in
                    reachedOutRow(pair, now: now)
                    Divider()
                }
            }
        }
    }

    // #661: group name, this one contact, timing, and the conversation-state control (the shared
    // ConversationStateControl, #652/#661), plus a link to Follow-ups once it's actually due, since
    // that screen already owns the real nudge/reply-sending flow rather than a second copy of it here.
    private func reachedOutRow(_ pair: (prospect: Prospect, recipient: Recipient, next: Date), now: Date) -> some View {
        let p = pair.prospect, r = pair.recipient
        return HStack(alignment: .top, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
                Text(r.email ?? r.name ?? "no contact").font(OVType.body).foregroundStyle(OVColor.inkSoft)
                // #675: this pipeline never carries a bounced recipient (isInPlay excludes them), so
                // the only signal worth restoring here is the soft-delay hint (#656) the embedded
                // DraftReviewView used to show before the lightweight row (#661) replaced it.
                if RecipientSnapshot(r).hasRecentDeliveryDelay(now: now) {
                    Text("Delivery delayed").font(.system(size: 10)).foregroundStyle(OVColor.gold)
                }
                if let line = SendFailureLine.text(for: r.sendError) {
                    Text(line).font(.system(size: 10)).foregroundStyle(OVColor.rust).lineLimit(2)
                }
            }
            Spacer(minLength: OVSpacing.sm)
            VStack(alignment: .trailing, spacing: 6) {
                // #661 follow-up: the old full card highlighted an overdue reach-out in rust rather
                // than the plain "in N days" color, so that urgency cue survives the lightweight row.
                let dueNow = ReachedOutQueue.isDueNow(next: pair.next, now: now)
                Text(ReachedOutQueue.timingLabel(next: pair.next, now: now))
                    .font(OVType.meta).foregroundStyle(dueNow ? OVColor.rust : OVColor.inkSoft)
                if r.replied {
                    ConversationStateControl(
                        currentState: r.conversationState, stateSource: r.conversationStateSource,
                        onSet: { state in
                            ProspectMutations.setRecipientConversationState(QueueItem(p), r.id, state,
                                                                            prospects: prospects, context: context, feedback: feedback)
                        },
                        onConfirm: {
                            ProspectMutations.confirmRecipientConversationState(QueueItem(p), r.id,
                                                                                prospects: prospects, context: context, feedback: feedback)
                        })
                }
                if dueNow {
                    Button("Send a follow-up") { onShowFollowUpsFor(r.id) }
                        .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forest)
                }
                // #683: the reply text, AI reply drafter, and Mark… menu only live on the full
                // card in Archive; always offered, not just once due, so Dan can read a reply or
                // record an outcome any time.
                Button("View in Archive") { onOpenInArchive(p.naturalKey, r.id) }
                    .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
            }
        }
        .padding(.vertical, OVSpacing.xs)
    }

    @ViewBuilder private func prospectRow(_ item: QueueItem) -> some View {
        if departing[item.id] != nil {
            // #361: the leaving delight. Appears instantly in place of the just-sent row (insertion
            // .identity), then the glide-up removal plays when `departing` clears. Reduced Motion drops
            // the glide to a plain fade; the drawn line is already dropped by the timing plan.
            SendDelightRow(item: item, timing: SendDelightTiming.plan(reduceMotion: reduceMotion))
                .transition(.asymmetric(
                    insertion: .identity,
                    removal: reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)))
        } else {
            ProspectRowFactory.row(item, today: today, prospects: prospects, context: context, feedback: feedback,
                                  dayOffOffer: dayOffOffer,
                                  highlightedKey: highlightedKey, outboundSendSince: outboundSending[item.id],
                                  replySendSince: { rid in replySending[rid] },
                                  onSend: { requestSend(item) }, onSendReply: { rid in sendReply(item, rid) },
                                  showingTooFar: false,
                                  userExcludedTowns: userExcludedTowns)
        }
    }

    // Step 1 of an explicit send: show Dan exactly what will go out and wait for his confirm (#49).
    private func requestSend(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let confirmation = SendConfirmation(prospect: model) else { return }
        pendingConfirm = PendingSend(id: item.id, confirmation: confirmation)
    }

    private func performSend(_ naturalKey: String) {
        pendingConfirm = nil
        // #361: snapshot the row now, while it's still present, so its leaving delight can render after
        // the send removes it from `visible`. Only a send that EMPTIES the show (onSent fullySent) plays
        // it; a partial send on a multi-recipient show keeps the row, so no exit yet.
        let snapshot = items.first(where: { $0.id == naturalKey })
        ProspectMutations.performSend(naturalKey, prospects: prospects, context: context, feedback: feedback,
                                      markSending: { outboundSending[$0] = Date() },
                                      clearSending: { outboundSending[$0] = nil },
                                      onNeedsReconnect: { showReconnect = true },
                                      onSent: { id, fullySent in
                                          guard fullySent, let snap = snapshot else { return }
                                          departing[id] = snap
                                          let t = SendDelightTiming.plan(reduceMotion: reduceMotion)
                                          DispatchQueue.main.asyncAfter(deadline: .now() + t.holdBeforeExit) {
                                              withAnimation(.easeOut(duration: t.exit)) { departing[id] = nil }
                                          }
                                      })
    }

    private func sendReply(_ item: QueueItem, _ recipientId: String) {
        ProspectMutations.sendReply(item, recipientId, prospects: prospects, context: context, feedback: feedback,
                                    markSending: { replySending[$0] = Date() },
                                    clearSending: { replySending[$0] = nil },
                                    onNeedsReconnect: { showReconnect = true })
    }
}
