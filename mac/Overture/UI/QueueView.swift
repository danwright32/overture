import SwiftUI
import SwiftData
import AppKit

// The window Dan lives in: ranked performances, grouped by date, kept or dismissed.
struct QueueView: View {
    @Environment(\.modelContext) private var context
    // #1414: the session undo stack, owned by the App and injected, so keep and dismiss record.
    // OPTIONAL deliberately: a non-optional Observable environment lookup FATAL ERRORS when the object
    // is absent, which would turn a missed injection into a crash of the whole app (and does crash any
    // test that builds this view directly). Nil simply means this surface records nothing.
    @Environment(QueueUndoStack.self) private var undoStack: QueueUndoStack?
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

    // #1598 Phase 5: the organisation answer ledger, and EVERY prospect including the dismissed ones the
    // query above filters out. Both are @Query on the #990/#991 excluded-towns precedent, so a check
    // settling re-renders every sibling show in the same frame instead of waiting for the next rebuild,
    // and so the producer gate is judged against the whole store: built from the filtered list, a show
    // Dan dismisses could silently change which organisations qualify and evaporate an answer he paid
    // for, with nothing on screen to say so.
    @Query private var orgAnswers: [OrgReachabilityAnswer]
    @Query private var allProspects: [Prospect]

    // #1436: hire inquiries fold into the same queue. Un-replied ones show in the to-send stage,
    // replied ones in reached-out (StageNavigation.stage(for:)); closed ones leave.
    @Query private var inquiries: [Inquiry]
    // The inquiry Dan is composing a first reply to (nil = none).
    @State private var replyingTo: Inquiry?
    // #1504: the inquiry whose logged details Dan is correcting (nil = none).
    @State private var editingInquiry: Inquiry?

    // #991: Dan's stored town refusals. A @Query so ADDING one re-renders the queue and the gate
    // re-decides every row against the new union at once, which is the "no migration" property #990's
    // derived verdict makes possible.
    @Query private var excludedTownRows: [ExcludedTown]
    private var userExcludedTowns: Set<String> { Set(excludedTownRows.map(\.town)) }
    // #1221: seed towns Dan has un-skipped. Read the same way (a @Query) so an un-skip re-decides every
    // affected row the instant it changes, with no migration (the geo verdict is derived, #990).
    @Query private var allowedSeedTownRows: [AllowedSeedTown]
    private var allowedSeedTowns: Set<String> { Set(allowedSeedTownRows.map(\.town)) }

    // #1570: Dan's standing geography refusals as one value, handed to StageNavigation so the stage
    // lists, the pill counts and the masthead all apply them. They used to reach only the masthead.
    private var geo: GeoRefusals {
        GeoRefusals(userExcludedTowns: userExcludedTowns, allowedSeedTowns: allowedSeedTowns)
    }

    @State private var pendingConfirm: PendingSend?
    // #1500: a whole night waiting on its confirm (nil = none). Holds the keys the group was SHOWING when
    // Dan picked the reason, so what the confirm counts is what the action takes.
    @State private var pendingNightDismiss: NightDismiss?
    // #1219: a committing action (Approve or per-row Re-prep) waiting on the self-booking confirm (nil =
    // none pending). One guard for both, since they share the dialog and differ only in verb and action.
    @State private var pendingSelfBookingGuard: SelfBookingGuard?
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
    // nil (no restore, nothing to fight) while the reached-out list is showing.
    // #1573: this binding OWNS the scroll position, so the intentional jumps drive it to the group they
    // want rather than clearing it and asking proxy.scrollTo for a row id. Clearing and scrolling was the
    // bug: the two mechanisms fought over the same ScrollView and the row jump was silently dropped, so a
    // picked search result did nothing at all. Holds a namespaced group id (QueueModel.showGroupScrollID),
    // never a bare date; see that helper for why the bare date is ambiguous.
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
    var onProbeReachability: (Set<String>) -> Void = { _ in }   // #1308 Layer 2

    // #1597: the dates Dan has ticked for one multi-date reachability check, by date-group id. Session
    // state, deliberately not persisted: a selection is a thing he is assembling right now, and one
    // surviving a relaunch would be a spending decision made days ago and forgotten.
    @State private var selectedProbeDates: Set<String> = []
    // #1597: the refusal, when a selection is past the ceiling. Held so the bar can show it in place
    // rather than a sheet appearing after he has already committed to the click.
    @State private var probeCeilingMessage: String?

    // #1308 Layer 2: the pending "Check reachability" confirm, holding the date's candidate keys.
    @State private var pendingProbe: ProbeConfirm?
    private struct ProbeConfirm: Identifiable {
        let id = UUID()
        let keys: [String]
        let dateLabel: String
        // #1597: set only for a multi-date selection, whose sentences come from ProbeSelectionCopy.
        // Absent means the single-date wording, unchanged.
        var title: String? = nil
        var message: String? = nil
    }

    private var items: [QueueItem] {
        QueueModel.items(from: prospects, answers: orgAnswers, corpus: allProspects)
    }

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
        // The masthead's at-a-glance summary is every show a stage will render, minus the ones already
        // pitched. #1134 removed the filter chips, so this is the whole to-send queue, unfiltered but
        // for Dan's standing town refusals.
        //
        // LIVE-STORE-CLAIM verified=2026-07-26 measure="the masthead total against the stage pills beneath it, over untriaged shows"
        // #1567: counted through StageNavigation, the same predicate as the pills directly beneath it,
        // so the line can no longer state a smaller backlog than the pills it sits above. It used to run
        // through queueOrder's own 90-day window and untouched-and-gone rule, neither of which any stage
        // list applies, which read 452 against the pills' 589 on the live store.
        //
        // #1570: the town refusals ride INSIDE that predicate now. This used to run the result through
        // QueueModel.filter a second time to apply them, which is precisely how the masthead and the
        // stage list came to answer one question two ways; the stage list called no such filter.
        let inAStage = StageNavigation.queueKeys(in: prospects, reachedOutKeys: reachedOutKeys,
                                                 today: today, now: now, geo: geo)
        let visible = items.filter { inAStage.contains($0.id) }
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
            // #1436: compose and send Dan's first reply to a hire inquiry.
            .sheet(item: $replyingTo) { InquiryReplySheet(inquiry: $0) }
            // #1504: the same sheet that logs one, opened on an existing record.
            .sheet(item: $editingInquiry) { InquiryIntakeSheet(editing: $0) }
    }

    // #1219: a committing action (Approve or Re-prep) waiting on the self-booking confirm, so the naming
    // and the action to run stay out of the button wiring and the confirm reads from one place.
    private struct SelfBookingGuard: Identifiable {
        let key: String
        let title: String
        let proceedLabel: String
        let message: String
        let proceed: () -> Void
        var id: String { key }
    }

    // #1500: the night Dan right-clicked, the reason he picked, and the rows that were on screen when he
    // picked it. The keys are captured at that moment rather than re-derived on confirm, so a scout landing
    // between the menu and the button cannot widen what he agreed to.
    private struct NightDismiss: Identifiable {
        let dateLabel: String
        let reason: DismissReason
        let keys: [String]
        let runs: [String]
        // The narrower set: the shows that play only on this night. Empty when there is no choice to make.
        let keysOnlyThisNight: [String]
        var offersChoice: Bool { !runs.isEmpty && !keysOnlyThisNight.isEmpty }
        var id: String { "\(dateLabel)|\(reason.rawValue)" }
    }

    // #1597: everything the selection bar and its confirm need, computed ONCE from the ticked dates.
    // Both read this, so the total Dan watches while choosing is the total he approves.
    // The rows the Scout stage is currently showing, derived the same way focusedSection derives them,
    // so a ticked date means exactly the shows under that heading and nothing else.
    private func scoutRows(_ data: RenderData) -> [QueueItem] {
        let wanted = Set(StageNavigation.focusedKeys(stage: .scout, leadKeys: [],
                                                     in: prospects, today: today, now: Date(), geo: geo))
        return data.items.filter { wanted.contains($0.id) }
    }

    private func probeSummary(_ data: RenderData) -> (ProbeSelection.Summary, [String])? {
        QueueModel.probeSelection(dates: selectedProbeDates, in: scoutRows(data),
                                  among: items, today: today, stage: focusedStage,
                                  geo: geo)
    }

    @ViewBuilder private func probeSelectionBar(_ data: RenderData) -> some View {
        if let (summary, keys) = probeSummary(data), !summary.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: OVSpacing.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ProbeSelectionCopy.selectionSummary(summary))
                            .font(OVType.meta.weight(.semibold))
                            .foregroundStyle(OVColor.ink)
                        Text(ProbeSelectionCopy.costLine(summary))
                            .font(OVType.meta)
                            .foregroundStyle(OVColor.inkSoft)
                    }
                    Spacer(minLength: OVSpacing.sm)
                    Button(ProbeSelectionCopy.clearSelection) {
                        selectedProbeDates = []
                        probeCeilingMessage = nil
                    }
                    .buttonStyle(.plain)
                    .font(OVType.meta)
                    .foregroundStyle(OVColor.inkSoft)
                    Button {
                        guard !prepRunning else { return }
                        // The brake. Refused here, in place, rather than in a confirm that looks exactly
                        // like the one he has clicked through a dozen times.
                        if summary.overCeiling {
                            probeCeilingMessage = ProbeSelectionCopy.overCeilingMessage(summary)
                            return
                        }
                        probeCeilingMessage = nil
                        pendingProbe = ProbeConfirm(
                            keys: keys, dateLabel: "",
                            title: ProbeSelectionCopy.multiDateTitle(summary),
                            message: ProbeSelectionCopy.multiDateMessage(summary))
                    } label: {
                        Text(ReachabilityProbeCopy.controlLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(prepRunning ? OVColor.onForest.opacity(0.5) : OVColor.onForest)
                            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 3)
                            .background(Capsule().fill(OVColor.forest.opacity(prepRunning ? 0.4 : 1)))
                    }
                    .buttonStyle(.plain)
                    .help(prepRunning ? ReachabilityProbeCopy.controlBusyHelp : "")
                }
                if let refusal = probeCeilingMessage {
                    Text(refusal)
                        .font(OVType.meta)
                        .foregroundStyle(OVColor.rust)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, OVSpacing.xl)
            .padding(.vertical, OVSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Opaque, because it now floats OVER the rows rather than sitting above them: anything
            // translucent here would show the content sliding underneath and read as a rendering fault.
            .background(OVColor.canvas)
            .overlay(alignment: .bottom) { Rectangle().fill(OVColor.line).frame(height: 1) }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func mainContent(_ data: RenderData) -> some View {
        queueScroll(data)
            // #1597: pinned at the TOP, under the toolbar, per Dan's call. Not at the bottom: it would
            // sit under ActionFeedbackBanner's Undo pill, and a running total he cannot see while
            // scrolling a long date list is not a running total.
            //
            // An OVERLAY, not a sibling above the scroll. As a sibling it took its height out of the
            // scroll view, so the first tick shrank the scroll area and the whole page jumped under his
            // cursor mid-click (his walk of the Debug build, 2026-07-27). An overlay floats over the
            // content and leaves the scroll geometry untouched, which is exactly why the acknowledgment
            // banner is attached the same way.
            .overlay(alignment: .top) { probeSelectionBar(data) }
            .background(OVColor.canvas)
            // #1219/#1249: confirm an Approve or a per-row Re-prep that lands on a date already holding a
            // pitch. First-party branded sheet (SelfBookingConfirmSheet), not a stock system dialog.
            .sheet(item: $pendingSelfBookingGuard) { pending in
                SelfBookingConfirmSheet(
                    title: pending.title, message: pending.message, proceedLabel: pending.proceedLabel,
                    onProceed: { pending.proceed(); pendingSelfBookingGuard = nil },
                    onCancel: { pendingSelfBookingGuard = nil })
            }
            // #1308 Layer 2: confirm an opt-in reachability probe before it spends. Reuses the same
            // first-party branded sheet; the copy states the honest cost (free for shows Dan keeps).
            .sheet(item: $pendingProbe) { pending in
                SelfBookingConfirmSheet(
                    title: pending.title ?? ReachabilityProbeCopy.confirmTitle(count: pending.keys.count),
                    message: pending.message
                        ?? ReachabilityProbeCopy.confirmMessage(dateLabel: pending.dateLabel,
                                                                count: pending.keys.count),
                    proceedLabel: ReachabilityProbeCopy.confirmProceed,
                    onProceed: {
                        onProbeReachability(Set(pending.keys))
                        selectedProbeDates = []
                        pendingProbe = nil
                    },
                    onCancel: { pendingProbe = nil })
            }
            // #1500: confirm a whole night before it goes. The count is the point: Dan has to know exactly
            // how much he is about to bury, and which run loses its later dates with it.
            .sheet(item: $pendingNightDismiss) { pending in
                SelfBookingConfirmSheet(
                    title: BulkDismiss.confirmTitle(count: pending.keys.count, dateLabel: pending.dateLabel),
                    message: BulkDismiss.confirmMessage(count: pending.keys.count, reason: pending.reason,
                                                        runs: pending.runs, dateLabel: pending.dateLabel,
                                                        offeringChoice: pending.offersChoice),
                    proceedLabel: BulkDismiss.confirmProceed(count: pending.keys.count,
                                                             offeringChoice: pending.offersChoice),
                    symbol: "archivebox",
                    // #1500 follow-up (Dan, 2026-07-26): leave the runs where they are and clear only what
                    // plays tonight. Offered only when a night actually holds both kinds.
                    alternativeLabel: pending.offersChoice
                        ? BulkDismiss.confirmProceedOnlyThisNight(count: pending.keysOnlyThisNight.count)
                        : nil,
                    onAlternative: pending.offersChoice
                        ? { dismissNight(pending, keys: pending.keysOnlyThisNight); pendingNightDismiss = nil }
                        : nil,
                    onProceed: { dismissNight(pending, keys: pending.keys); pendingNightDismiss = nil },
                    onCancel: { pendingNightDismiss = nil })
            }
    }

    private func dismissNight(_ pending: NightDismiss, keys: [String]) {
        ProspectMutations.dismissAll(keys, reason: pending.reason, dateLabel: pending.dateLabel,
                                     prospects: prospects, context: context, feedback: feedback,
                                     undo: undoStack)
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
            // #1513: inquiries and shows are ONE list here, ordered by when each next needs Dan, so the
            // "Grouped by when to reach out next" caption governs every date heading in the stage. They
            // used to be two blocks whose headings looked identical and meant different things (event
            // date above, reach-out date below).
            reachedOutList(data.reachedOut)
        } else {
            // #1140: in stage mode, re-derive membership LIVE from the current prospects (a sent draft
            // drops out); in leads mode, keep the frozen key set. The dispatch lives in
            // StageNavigation.focusedKeys so it is tested, not decided inline in this view.
            let wanted = Set(StageNavigation.focusedKeys(stage: focusedStage, leadKeys: keys,
                                                         in: prospects, today: today, now: Date(),
                                                         geo: geo))
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
                let inquiryRows = stageInquiryRows(focusedStage)
                if rows.isEmpty && inquiryRows.isEmpty {
                    if focusedStage == nil {
                        // #308: the away-alert leads path names specific leads; some may have since left.
                        Text("These leads are no longer in your queue.")
                            .font(OVType.body).foregroundStyle(OVColor.inkSoft)
                    } else {
                        stageEmptyState(for: focusedStage ?? StageNavigation.openingStage, data: data)
                    }
                } else {
                    // #1220: group the stage's rows by date under "FRI Jul 17 2026" headers, the same on
                    // every stage. #976: the date groups are the scroll targets, so scrollTargetLayout lets
                    // scrollPosition($topGroup) pin the top visible one across a @Query rebuild.
                    LazyVStack(alignment: .leading, spacing: OVSpacing.xl) {
                        // #1436: un-replied inquiries (the to-send stage) surface with the shows.
                        inquirySection(inquiryRows)
                        // #1573: the scroll-target identity is namespaced, not the bare date. The
                        // inquiry groups above share this layout and were keyed on the same raw dates,
                        // so a day holding both gave one id to two targets and a jump could land on the
                        // wrong one.
                        ForEach(QueueModel.groupByDate(rows)) { group in
                            dateSection(group).id(QueueModel.showGroupScrollID(group.id))
                        }
                    }
                    .scrollTargetLayout()
                }
            }
        }
    }

    // #1436: the inquiries belonging to a stage, as display rows (StageNavigation.stage decides which).
    private func stageInquiryRows(_ stage: StageFocus?) -> [InquiryRow] {
        guard let stage else { return [] }
        let forStage = inquiries.filter { StageNavigation.stage(for: $0) == stage }
        return QueueModel.inquiryRows(forStage, now: Date())
    }

    // #1436: inquiries for a stage, as their own date-grouped block. Kept separate from the prospect
    // rows so the prospect rendering is untouched; whether they interleave between shows by date is a
    // walk-time refinement. The source tag and lifecycle state stand in for a prospect's fit/geo, which
    // an inquiry has no equivalent for.
    @ViewBuilder private func inquirySection(_ rows: [InquiryRow]) -> some View {
        if !rows.isEmpty {
            let byId = Dictionary(inquiries.map { (String(describing: $0.persistentModelID), $0) },
                                  uniquingKeysWith: { first, _ in first })
            ForEach(QueueModel.groupRowsByDate(rows.map { QueueRow.inquiry($0) })) { group in
                VStack(alignment: .leading, spacing: OVSpacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: OVSpacing.sm) {
                        if !group.weekday.isEmpty {
                            Text(group.weekday.uppercased()).font(.system(size: 11, weight: .semibold))
                                .tracking(1.4).foregroundStyle(OVColor.inkFaint)
                        }
                        Text(group.monthDay).font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                        if !group.year.isEmpty {
                            Text(group.year).font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
                        }
                    }
                    ForEach(group.rows) { queueRow in
                        if case .inquiry(let inquiryRow) = queueRow, let inquiry = byId[inquiryRow.id] {
                            InquiryRowView(
                                row: inquiryRow,
                                onReply: { replyingTo = inquiry },
                                onEdit: { editingInquiry = inquiry },
                                onMarkBooked: { markInquiry(inquiry, .booked) },
                                onMarkLost: { markInquiry(inquiry, .lost($0)) })
                        }
                    }
                }
                // #1573: distinct from the show group on the same date, which shares this layout.
                .id(QueueModel.inquiryGroupScrollID(group.id))
            }
        }
    }

    // #1436: the outcome and its write both live in InquiryMutations, so a failed save warns Dan
    // instead of the row quietly leaving the queue over a change that never reached disk.
    private func markInquiry(_ inquiry: Inquiry, _ action: InquiryMutations.MarkAction) {
        InquiryMutations.mark(inquiry, as: action, context: context, feedback: feedback)
    }

    // #1220: every stage view groups its rows by date, reusing the pre-#1134 date-group header (weekday,
    // month/day, year) and the #1193/#901 "Unavailable" marker up by the date. The grouping
    // (QueueModel.groupByDate) and the unavailability rule (QueueModel.groupIsUnavailable) are tested
    // model helpers; this only renders them.
    private func dateSection(_ group: QueueModel.DateGroup) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: OVSpacing.sm) {
                if !group.weekday.isEmpty {
                    Text(group.weekday.uppercased()).font(.system(size: 11, weight: .semibold))
                        .tracking(1.4).foregroundStyle(OVColor.inkFaint)
                }
                Text(group.monthDay).font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                if !group.year.isEmpty {
                    Text(group.year).font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
                }
                // #901 (Dan's walk, 2026-07-14): "up by the date". When any show on this date is a day he
                // can't work, the header itself says so, so a blocked day reads at a glance.
                if QueueModel.groupIsUnavailable(group.items) {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar.badge.exclamationmark")
                        Text("Unavailable")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OVColor.onRust)
                    .padding(.horizontal, OVSpacing.sm).padding(.vertical, 3)
                    .background(Capsule().fill(OVColor.rust))
                }
                // #1219/#1246: a self double-booking note, up by the date so Dan sees it while scanning.
                // Computed queue-wide (against all items, not just this stage's rows) so it stays visible
                // even after the other show moves to another stage. Single tier: any real commitment on the
                // date shows it. The per-row marker names the specific clashing show; this is the date flag.
                // Not shown in Scout (untriaged candidates are not commitments Dan is protecting yet).
                if focusedStage != .scout, let note = QueueModel.selfBookingNote(group.items, among: items) {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar.badge.exclamationmark")
                        Text(note)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OVColor.gold)
                    .padding(.horizontal, OVSpacing.sm).padding(.vertical, 3)
                    .background(Capsule().fill(OVColor.surfaceSunk))
                }
                // #1308 Layer 2: an opt-in reachability check for a date holding several still-open
                // candidates, so Dan can see which are emailable before he keeps one and dismisses the rest.
                // A standalone view (testable, #863) that reports the candidate keys up so the confirm sheet
                // opens at the QueueView level.
                // #1597: tick the date to add it to a multi-date check. Scout only, and only where there
                // is something still to check, so it never appears on a date whose Check button is absent.
                if focusedStage == .scout, !QueueModel.reachabilityProbeCandidateKeys(group.items, geo: geo).isEmpty {
                    Button {
                        if selectedProbeDates.contains(group.id) {
                            selectedProbeDates.remove(group.id)
                        } else {
                            selectedProbeDates.insert(group.id)
                        }
                        // The refusal is about a selection that no longer exists the moment it changes.
                        probeCeilingMessage = nil
                    } label: {
                        Image(systemName: selectedProbeDates.contains(group.id)
                              ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12))
                            .foregroundStyle(selectedProbeDates.contains(group.id)
                                             ? OVColor.forest : OVColor.inkSoft)
                    }
                    .buttonStyle(.plain)
                    .help("Include this date in one reachability check")
                }
                ReachabilityProbeControl(
                    items: group.items, dateLabel: group.monthDay,
                    geo: geo,
                    isRunning: prepRunning,
                    onTap: { keys, label in pendingProbe = ProbeConfirm(keys: keys, dateLabel: label) })
            }
            .padding(.bottom, OVSpacing.xxs)
            .overlay(alignment: .bottom) { Rectangle().fill(OVColor.line).frame(height: 1) }
            // #1500: right-click the date to dismiss everything under it for one reason (Dan's call,
            // 2026-07-26: no new visible control on a header that already carries the Unavailable pill and
            // the reachability check). Scout only, by his call in the same conversation: a night of shows he
            // has already kept or drafted is not something to lose to one right-click.
            .contextMenu { if focusedStage == .scout { nightDismissMenu(group) } }

            ForEach(group.items) { item in prospectRow(item) }
        }
    }

    // The reasons, under a heading that says what they are about to do and to how many shows. Without the
    // heading a right-click would show a bare list of dismiss reasons that names neither the action nor the
    // night. `danCanChoose` (#864), the same list a card's own Dismiss menu offers, so the reason written
    // here is one Dan could have written by hand: "Went by" and "Too far" are Overture's own.
    @ViewBuilder private func nightDismissMenu(_ group: QueueModel.DateGroup) -> some View {
        let plan = BulkDismiss.plan(for: group.items.map(BulkDismiss.Show.init), on: group.id)
        if !plan.isEmpty {
            Section(BulkDismiss.menuTitle(count: plan.count, dateLabel: group.monthDay)) {
                ForEach(DismissReason.danCanChoose, id: \.self) { reason in
                    Button(reason.label) {
                        pendingNightDismiss = NightDismiss(dateLabel: group.monthDay, reason: reason,
                                                           keys: plan.keys, runs: plan.runsPastTheNight,
                                                           keysOnlyThisNight: plan.keysOnlyThisNight)
                    }
                }
            }
        }
    }

    // #1134: an empty stage says what it is and, when there is work elsewhere, points Dan to the next
    // stage that has some (never auto-jumping there). The pointer logic is the pure StageEmptyState so it
    // is tested; this view just renders it in the same dashed-border card the queue used before.
    private func stageEmptyState(for stage: StageFocus, data: RenderData) -> some View {
        let counts = StageNavigation.counts(in: prospects, today: today, now: Date(), geo: geo)
        // #1194: the reached-out pointer counts SHOWS (StageEmptyState labels it "N shows you've pitched"),
        // so it matches the pill; data.reachedOut is per-recipient, so collapse to distinct shows here.
        let reachedOutShows = Set(data.reachedOut.map(\.prospect.naturalKey)).count
        let message = StageEmptyState.message(for: stage, counts: counts, reachedOut: reachedOutShows)
        return VStack(spacing: OVSpacing.xs) {
            Text(message.title).font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            // #1195: a send-issues stage has no resting detail, so show the title alone rather than a
            // generic second line that just restates it.
            if !message.detail.isEmpty {
                Text(message.detail).font(OVType.body).foregroundStyle(OVColor.inkSoft)
                    .multilineTextAlignment(.center)
            }
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
        let target = QueueModel.firstVisibleKey(keys, among: items)
        // #1573: drive the scroll position to the group holding the lead instead of clearing it and
        // asking for the row. The old comment here claimed this view was "a flat list without scroll
        // targets", which stopped being true at #1220 when every stage started grouping by date: it is
        // the same layout, with the same binding, and the same dropped jump as navigateToLead had.
        topGroup = target.flatMap { QueueModel.scrollGroupID(containing: $0, among: items) }
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
        focusedKeys = StageNavigation.naturalKeys(for: status.focus, in: prospects, today: today,
                                                  now: Date(), geo: geo)
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
                                             reachedOutKeys: reachedOutKeys,
                                             geo: geo) ?? StageNavigation.openingStage
        focusedKeys = nil   // #1140: stage mode re-derives its own membership; no frozen key set
        focusedHeading = nil
        highlightedKey = key
        deepLinkedKey = nil
        // #1573: land the jump in two stages, because the row alone cannot carry it. Stage one drives
        // the scrollPosition binding, which owns this ScrollView and is the only thing that can resolve
        // a target the lazy layout has not realized yet, to the group holding the row. Clearing it and
        // asking proxy.scrollTo for the row (what this did before) fought that binding and was silently
        // dropped, so the click read as dead. Computed over `items` rather than the stage's own rows: a
        // group's id is its date either way, and the stage was just set to the one containing this key.
        topGroup = QueueModel.scrollGroupID(containing: key, among: items)
        // Stage two: once that group is on screen its rows are realized, so nudge the row itself into
        // the middle. If this runs before the layout settles it simply no-ops, leaving Dan on the right
        // date, which is the old behavior's best case rather than its actual one.
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
            prospects: prospects, inquiries: inquiries, now: now, today: today,
            gmailConnected: GmailAuthManager.shared.isConnected,
            prepRunning: PrepQueueService.isRunning(now: now),
            replyRunAlive: ReplyClassifyService.isRunning(now: now),
            geo: geo
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
        let entries = QueueModel.reachedOutEntries(prospects: dated,
                                                   inquiries: inquiries.filter {
                                                       StageNavigation.stage(for: $0) == .reachedOut
                                                   },
                                                   now: Date())
        if entries.isEmpty {
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
            let groups = QueueModel.reachOutDateGroups(entries, reachDate: { $0.next })
            // #1513: counted from the rendered entries, so the note can never describe fewer rows than
            // the list shows.
            let counts = QueueModel.reachedOutNoteCounts(entries)
            let note = ReachedOutQueue.contactsAcrossShowsNote(contactCount: counts.contacts,
                                                              showCount: counts.shows)
            VStack(alignment: .leading, spacing: OVSpacing.md) {
                // #1233/#1232: the date headers below are REACH-OUT dates (Dan's call), so say so once here
                // rather than let them read like the performance-date headers on every other stage.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grouped by when to reach out next")
                        .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                    if let note {
                        Text(note).font(OVType.meta).foregroundStyle(OVColor.inkFaint)
                    }
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: OVSpacing.sm) {
                        reachOutDateHeader(group)
                        ForEach(group.rows) { entry in
                            switch entry {
                            case .prospect(let prospect, let recipient, let next):
                                reachedOutRow((prospect: prospect, recipient: recipient, next: next),
                                              now: now)
                            case .inquiry(let inquiry, let row, _):
                                // #1513: the same row shape as a show, so the two read as one list. The
                                // source capsule and lifecycle line stay, because they say what an
                                // inquiry is; the card box and its own typography are gone.
                                InquiryRowView(
                                    row: row, style: .listRow,
                                    onReply: { replyingTo = inquiry },
                                    onEdit: { editingInquiry = inquiry },
                                    onMarkBooked: { markInquiry(inquiry, .booked) },
                                    onMarkLost: { markInquiry(inquiry, .lost($0)) })
                            }
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // #1233: the reach-out-date header for a Reached-out group. Same weekday/month-day/year styling as the
    // performance-date headers on the other stages; the caption above disambiguates that this date is WHEN
    // to reach out, not the show date.
    private func reachOutDateHeader<Row>(_ group: QueueModel.ReachOutDateGroup<Row>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OVSpacing.sm) {
            if !group.weekday.isEmpty {
                Text(group.weekday.uppercased()).font(.system(size: 11, weight: .semibold))
                    .tracking(1.4).foregroundStyle(OVColor.inkFaint)
            }
            Text(group.monthDay).font(OVType.dateHeading).foregroundStyle(OVColor.ink)
            if !group.year.isEmpty {
                Text(group.year).font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
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
            // #1219/#1246: the persistent self double-booking marker, on the row itself so it travels with
            // the show and never vanishes when the OTHER show changes stage. Names the clashing show(s).
            // Not in Scout (untriaged candidates are not commitments Dan is protecting yet).
            let selfBookingMarker = focusedStage != .scout
                ? SelfBookingCopy.rowMarker(QueueModel.selfBookingConflictNames(for: item, among: items))
                : nil
            VStack(alignment: .leading, spacing: 4) {
                if let marker = selfBookingMarker {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar.badge.exclamationmark")
                        Text(marker)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OVColor.gold)
                }
                ProspectRowFactory.row(item, today: today, prospects: prospects, context: context, feedback: feedback,
                                      dayOffOffer: dayOffOffer,
                                      undoStack: undoStack,
                                      highlightedKey: highlightedKey, outboundSendSince: outboundSending[item.id],
                                      replySendSince: { rid in replySending[rid] },
                                      onSend: { requestSend(item) }, onSendReply: { rid in sendReply(item, rid) },
                                      onReprep: { mode in requestReprep(item, mode) },
                                      onApprove: { requestApprove(item) },
                                      showingTooFar: false,
                                      userExcludedTowns: userExcludedTowns,
                                      allowedSeedTowns: allowedSeedTowns)
            }
        }
    }

    // #1219: Approve and per-row Re-prep are committing moments Dan gated. Both launch straight from the
    // row (Re-prep starts a Prep run, Approve advances toward send), so each is routed through this check:
    // if the show sits on a date that already holds a committed pitch, confirm past it deliberately;
    // otherwise act straight away. One guard, differing only in verb and the action it runs on confirm.
    private func requestReprep(_ item: QueueItem, _ mode: ReprepMode) {
        guardSelfBooking(item, title: SelfBookingCopy.prepConfirmTitle,
                         proceedLabel: SelfBookingCopy.prepConfirmProceed) {
            ProspectMutations.reprep(item, mode: mode, prospects: prospects, context: context, feedback: feedback)
        }
    }

    private func requestApprove(_ item: QueueItem) {
        guardSelfBooking(item, title: SelfBookingCopy.approveConfirmTitle,
                         proceedLabel: SelfBookingCopy.approveConfirmProceed) {
            ProspectMutations.setStatus(item, .approved, nil, prospects: prospects, context: context, feedback: feedback)
        }
    }

    private func guardSelfBooking(_ item: QueueItem, title: String, proceedLabel: String,
                                  proceed: @escaping () -> Void) {
        if let clash = QueueModel.selfBookingClash(for: item, among: items),
           let message = SelfBookingCopy.prepConfirmMessage([clash]) {
            pendingSelfBookingGuard = SelfBookingGuard(key: item.id, title: title,
                                                       proceedLabel: proceedLabel, message: message, proceed: proceed)
        } else {
            proceed()
        }
    }

    // Step 1 of an explicit send: show Dan exactly what will go out and wait for his confirm (#49).
    private func requestSend(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              var confirmation = SendConfirmation(prospect: model) else { return }
        // #1219: warn at the committing moment when a DIFFERENT committed show shares this date, naming it
        // so Dan remembers which one. Fires on any commitment (booked / emailed / live draft), not just an
        // already-emailed one, and compares against the whole queue so a show in any stage still counts.
        confirmation.selfBookingWarning = QueueModel.sendSelfBookingWarning(for: item, among: items)
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

// #1308 Layer 2: the "Check reachability" control on a date. A standalone view so its visibility rule and
// tap payload are testable directly (the enclosing QueueView reads @Query/@State a unit test can't inject).
//
// #1595 removed the two rules that had kept it off every surface Dan uses: it was blocked on the Scout
// stage outright and demanded two or more shows on a date. Between them it had never appeared once.
//
// Then Dan walked it (2026-07-27) and cut it back to the button alone: no green box, no envelope icon, no
// headline sentence, no dismiss X. It sits on all 169 of his dates, above the shows, on the list he scrolls
// most, so anything beyond the action itself is noise on 169 rows to save a sentence on one. The stale
// case loses nothing: the ROW carries its own "Reachability may be out of date" badge, so the callout had
// been saying it twice (#843). A tap reports the candidate keys up so QueueView opens the confirm sheet;
// it never runs on its own.
struct ReachabilityProbeControl: View {
    let items: [QueueItem]
    let dateLabel: String
    // #1609: Dan's geography refusals, so the control never offers a PAID check on a show somewhere he
    // has refused to travel. Defaulted to none so a preview or a test that does not care is unchanged.
    var geo: GeoRefusals = .none
    // #1323: a probe and a normal Prep share the single detached-run slot, so the Check action greys out
    // while any run is already in flight rather than failing after the tap with alreadyRunning.
    let isRunning: Bool
    let onTap: (_ keys: [String], _ dateLabel: String) -> Void

    var body: some View {
        let keys = QueueModel.reachabilityProbeCandidateKeys(items, geo: geo)
        if !keys.isEmpty {
            HStack(spacing: 0) {
                Spacer(minLength: OVSpacing.sm)
                Button {
                    guard !isRunning else { return }
                    onTap(keys, dateLabel)
                } label: {
                    Text(ReachabilityProbeCopy.controlLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isRunning ? OVColor.onForest.opacity(0.5) : OVColor.onForest)
                        .padding(.horizontal, OVSpacing.sm).padding(.vertical, 3)
                        .background(Capsule().fill(OVColor.forest.opacity(isRunning ? 0.4 : 1)))
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
                .help(isRunning ? ReachabilityProbeCopy.controlBusyHelp : "")
            }
        } else if QueueModel.dateReachabilityIsFullyChecked(items, geo: geo) {
            // #1617: the finished date, in the slot the button held a moment ago. Quiet on purpose (no
            // capsule, no icon, faint): it is a resting state Dan walks past, not a thing to act on, and
            // the #1595 cutback of this control was about exactly that. It appears only on a date whose
            // shows were really answered, so it stays rare rather than joining the 169.
            HStack(spacing: 0) {
                Spacer(minLength: OVSpacing.sm)
                Text(ReachabilityProbeCopy.dateCheckedMarker)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OVColor.inkFaint)
            }
        }
    }
}
