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
    // #2365: which watched calendars are a past client's, so Scout offers a returning client's season a
    // year ahead. Optional for the same reason undoStack is, and `.none` when absent, which holds every
    // show to the ordinary window rather than crashing.
    @Environment(ClientRoster.self) private var clientRoster: ClientRoster?
    @Environment(ActionFeedback.self) private var feedback   // #285: shared acknowledgment surface
    @Environment(DayOffOfferRequest.self) private var dayOffOffer   // #924: dismiss-to-day-off picker request

    // Dismissed prospects drop out of the queue; the rest sort date asc, fit desc. Membership beyond
    // that is StageNavigation's, never a second predicate here (#1567). A show that vanished from its
    // feed and was never acted on (#133) is drawn struck-through by ProspectRowView rather than hidden:
    // the hiding copy of that rule lived in QueueModel.queueOrder, unreachable from the app since #1567
    // and deleted in #2348.
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
    // #1719: Dan's own producer/house corrections. @Query rather than a context read, so applying one
    // re-derives the queue immediately instead of at the next relaunch.
    @Query private var promotedProducers: [PromotedProducer]
    @Query private var demotedHouses: [DemotedHouse]
    // #1825: the watchlist, so a card can tell a link to THIS show from a fallback to the source's own
    // calendar. @Query rather than a context read, on the same precedent as the corrections above: adding
    // or removing a source re-labels the affected cards immediately.
    @Query private var watchedSources: [WatchedSource]
    // #2392: the addresses Dan has struck. @Query on the same precedent as the corrections above: a
    // strike must take the address off the card in the same frame, not at the next rebuild.
    @Query private var refusedAddresses: [RefusedContactAddress]

    // #1436: hire inquiries fold into the same queue. Un-replied ones show in the to-send stage,
    // replied ones in reached-out (StageNavigation.stage(for:)); closed ones leave.
    @Query private var inquiries: [Inquiry]
    // The inquiry Dan is composing a first reply to (nil = none).
    @State private var replyingTo: Inquiry?
    // #2128: the prospect half of the same thing. A panel over the queue, so the compose box's text lives
    // one level down and typing cannot re-derive the store (the #1774 / #1922 / #1923 class).
    @State private var answeringReply: ReplyTarget?
    // #2130: the nudge or closing note the row's control is about to send, held so Dan approves the exact
    // email first. Its own state rather than pendingConfirm, whose onSend is wired to the pitch send.
    @State private var pendingRowNudge: PendingRowNudge?
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
    // #2365: the client verdict for every watched source, decided once per read of this property rather
    // than per show (#1429 measured the per-row shape freezing a sheet).
    private var clientWindow: ClientWindow {
        clientRoster?.window(for: watchedSources) ?? .none
    }

    @State private var pendingConfirm: PendingSend?
    // #1500: a whole night waiting on its confirm (nil = none). Holds the keys the group was SHOWING when
    // Dan picked the reason, so what the confirm counts is what the action takes.
    @State private var pendingNightDismiss: NightDismiss?
    // #1219: a committing action (Approve or per-row Re-prep) waiting on the self-booking confirm (nil =
    // none pending). One guard for both, since they share the dialog and differ only in verb and action.
    @State private var pendingSelfBookingGuard: SelfBookingGuard?
    @State private var showReconnect = false
    // #2718: which contact's proposed conversation is being linked right now. A confirm makes two Gmail
    // calls, so the control has to say it is working rather than sitting there looking unpressed.
    @State private var linkingConversationFor: String?
    // #2718: which pitch's manual "Link their reply" picker is open.
    @State private var manualLinkTarget: ManualLinkTarget?
    // #436: in-flight sends, so a tapped Send shows a live "Sending…" state instead of a dead button.
    // Outbound keyed by prospect natural key; replies keyed by recipient id. Cleared when the await ends.
    // #1922: they live on SendProgressState now, an object, so a send animates its own card instead of
    // re-deriving all 724 prospects four times over. QueueView never reads it; see that type, and
    // QueueInvalidationGuardTests for the assertion that this stays true.
    @State private var sendState = SendProgressState()
    // #361: shows that have just been fully sent and are playing their leaving delight (gold seal +
    // drawn line, then a glide-up exit). Keyed by natural key to the snapshot to render while it
    // departs, since the real row has already left `visible` once the send lands in the data.
    // #1922: on SendProgressState with the rest of them. Unlike the other three this one changes WHICH
    // rows exist, so the splice moved to QueueDateGroups, over groups already built, rather than into
    // the derivation that builds them.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // #236: a lead opened from an OmniFocus deep link. When it changes, the queue switches to the
    // pipeline holding it, clears filters that would hide it, scrolls to it, and briefly highlights it.
    @Binding var deepLinkedKey: String?
    // #976: the date group at the top of the scroll, bound so the queue holds its place while the rows
    // underneath rebuild. `prospects` is a @Query and this is the window Dan reviews in (~119 shows),
    // rebuilt by every scout and Prep run; a plain ScrollView drops its offset to the top on each one
    // (the #974 shape), so mid review the queue snaps away before he can act on a row. Pinned to the top
    // visible date group, not the individual show, because the groups are the stable landmarks a run
    // reshuffles shows within. Only the to-send date list carries the scroll target layout, so this stays
    // nil (no restore, nothing to fight) while the reached-out list is showing.
    // #1573: the scroll position OWNS the jump, so the intentional jumps drive it to the group they want
    // rather than clearing it and asking proxy.scrollTo for a row id. Clearing and scrolling was the bug:
    // the two mechanisms fought over the same ScrollView and the row jump was silently dropped, so a
    // picked search result did nothing at all. Holds a namespaced group id (QueueModel.showGroupScrollID),
    // never a bare date; see that helper for why the bare date is ambiguous.
    //
    // #1774: the position itself lives on QueueScrollHolder now, because SwiftUI WRITES it on every scroll
    // and as @State here each of those writes re-derived the whole store. This is the one channel by which
    // a deliberate jump reaches it, and it is @State, so setting it always invalidates and always arrives.
    // Declared rather than inferred on purpose: resting on "every jump also happens to write some other
    // piece of state" would be an unenforced rule of the kind that broke the stage-pill invariant twice.
    @State private var jumpTarget: QueueJumpRequest?

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
    // #2204: what the app has to say for itself right now (an OmniFocus failure, the last run's warning
    // or receipt). Owned by RootView, which is where every writer of it lives, and drawn here because
    // this is the screen Dan actually looks at.
    var notices: [AppNotice] = []
    // #2250: performs whatever a notice offers. RootView owns the sync and every other remedy, so this
    // view only reports the press upward, the same shape as onProbeReachability.
    var onNoticeAction: (AppNoticeAction) -> Void = { _ in }
    // #338: the Follow-ups pill reuses the existing FollowUpsView sheet (owned by RootView)
    // instead of a second filtered-list implementation of the same thing.
    var onShowFollowUps: () -> Void = {}
    // #682: unlike the generic Follow-ups pill above, the reached-out row's own "Send a follow-up"
    // button knows exactly which contact Dan clicked from, so it opens the sheet with that
    // recipient highlighted instead of leaving him to find it again in what could be a longer list.
    // #2154: the reached-out row's jump to the Archive card is gone, and with it the last thing on this
    // view that called an open-in-Archive closure. Dan: "I'm basically never going to want to view it in
    // the archive so we can remove that." Kept as a parameter it would be a prop written by RootView and
    // read by nothing, which reads as wired from either end (L46).
    // #1129: a discoverable "Prep these N" button in the Prep stage view starts a Prep run through
    // RootView's existing #953 selection-sheet flow (mirrors the readOne closure SourcesView receives),
    // so a first-time user need not know the Cmd+P shortcut or the toolbar menu.
    var onStartPrep: () -> Void = {}
    // #1880: how a per-row Re-prep LAUNCHES its run. Supplied by RootView, which owns the takeover, so the
    // Re-prep gets the same "Reading show pages" phase the batch launch has instead of falling through to
    // "Prepping" for the whole time the app renders the show's listing page.
    //
    // The default is the unwired behaviour, kept so this view stays constructible in previews and tests
    // without a takeover. It is NOT the shipping path: `ReprepListingPhaseWiringTests` asserts RootView
    // passes a real one, because a default that silently stands in for the wiring is how the phase went
    // missing on one of three entry points in the first place (L46).
    var onLaunchPrep: (@MainActor (ModelContext, Date, Set<String>) async throws -> Void)? = nil
    var onProbeReachability: (Set<String>) -> Void = { _ in }   // #1308 Layer 2

    // #1597/#1774: the dates Dan has ticked for one multi-date reachability check. An object, not @State,
    // so a tick invalidates only the checkbox and the selection bar that read it. See ProbeSelectionState
    // for why, and QueueInvalidationGuardTests for the assertion that this view never reads it.
    @State private var probeSelection = ProbeSelectionState()

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
        QueueModel.items(from: prospects, answers: orgAnswers, corpus: allProspects,
                         overrides: ProducerOverrides(promotedRows: promotedProducers,
                                                      demotedRows: demotedHouses),
                         sources: watchedSources,
                         refusals: ContactRefusal.ledger(from: refusedAddresses),
                         // #3014: shows a live prep is drafting take no inherited org answer while a
                         // check is running, so a check on a sibling show cannot change the contact
                         // under a draft. Cached (LiveRunHoldings), never read from disk here: this
                         // body re-derives on every render.
                         heldKeys: LiveRunHoldings.current)
    }

    private var today: String { QueueModel.easternToday() }

    // #1129: a Prep run is in flight. The discoverable Prep button hides while one runs (RootView's
    // canStartPrep gates the start too); read from the same source AgentInputs.from uses.
    // #2760: EITHER slot, because the exclusion between a prep and a check is still in force. Reading only
    // the prep slot would offer the Prep button while a check holds the machine and every press would be
    // refused. #2765 is what makes the two independent; #2761 is where the wording follows.
    // #3015: TWO questions, because the two runs no longer exclude each other. `anyRunIsRunning` was the
    // right answer while either run blocked the other; asking it now hides the Prep button whenever a
    // check is going, and greys the Check control whenever a prep is, which is the whole feature not
    // happening. Each control asks about the slot it would actually start.
    private var prepRunning: Bool {
        PrepQueueService.isRunning(slot: .prep, markerURL: RunSlot.prep.markerURL(in: StoreLocation.handoffDirectory), now: Date())
    }
    private var checkRunning: Bool {
        PrepQueueService.isRunning(slot: .check, markerURL: RunSlot.check.markerURL(in: StoreLocation.handoffDirectory), now: Date())
    }

    // #1121: every heavy derived collection, built ONCE per render and threaded down, instead of a
    // half-dozen computed properties each re-running QueueModel.items(from:) (a full map that faults
    // every prospect's `recipients` relationship on the main thread). A pill tap flips @State
    // (focusedKeys) and invalidates the body; before, that alone rebuilt `items` seven-plus times and
    // re-faulted the store on each one, which is what froze the machine for a beat on every switch.
    struct RenderData {
        let items: [QueueItem]
        let visible: [QueueItem]
        // #1771: built ONCE here rather than by each of its two readers (the pill strip and the focused
        // stage heading). One build is roughly four full traversals of every prospect and its recipients,
        // so building it twice cost eight per render pass.
        let agentInputs: AgentInputs
        // #1770: the one answer for this render pass, read from the cache rather than from the token file,
        // and threaded to every card instead of each card sourcing its own.
        let gmailConnected: Bool
        // #2267: the two run facts every card's re-check control needs, read ONCE for the pass for the
        // same reason as the line above. Both read a marker file, and a per-card read would be a disk
        // read per row per scroll frame, which is the #1770 defect exactly.
        let probeRunning: Bool
        // #3186: the check's start and size, for the row's own re-check label. Read only when a check is
        // actually in flight, so an idle queue pays nothing for a control it is merely offering.
        let checkRunSince: Date?
        let checkLookups: Int?
        // Contacted RECIPIENTS Dan is still working, soonest-first. #652: one entry per recipient, so a
        // multi-contact show can appear more than once, each with its own contact and timing.
        let reachedOut: [(prospect: Prospect, recipient: Recipient, next: Date)]
        let reachedOutKeys: Set<String>
        let pendingBookings: Int
        // #1774: everything below used to be derived INSIDE the scroll content, so a scroll frame paid for
        // it. The fan-out line is the one that hid: it sweeps every prospect and was written as an
        // argument to the masthead, and an argument evaluates at its call site, so it ran on every pass
        // while reading as though it belonged to the masthead (#1916's lesson, one level up).
        let fanOutLine: String?
        // The stage's rows, already filtered to the focused stage and with the just-sent rows folded back
        // in, and already grouped by date. Grouping ~500 Scout rows per scroll frame was pure waste.
        let focusedRows: [QueueItem]
        let dateGroups: [QueueModel.DateGroup]
        let inquiryRows: [InquiryRow]
        // #1962: the pass's own resolved geography, so a surface built from this snapshot answers
        // from the same table instead of sweeping the store again through the unresolved value.
        let geo: GeoRefusals
    }

    // #1913: the derivation itself lives in QueueRenderPass, over plain values, so what one pass costs
    // can be measured in a test. A SwiftUI body cannot be evaluated in one, so anything left in here is
    // unmeasurable by construction. What stays is gathering: reading this view's own state and the three
    // file-backed answers, and handing them over.
    private func makeRenderData() -> RenderData {
        let now = Date()
        // Asked ONCE: three of the inputs below are decided from it, and it reads marker files.
        let inFlight = PrepQueueService.runInFlight(now: now)
        return QueueRenderPass.make(QueueRenderPass.Inputs(
            prospects: QueueRenderPass.Corpus(prospects),
            allProspects: QueueRenderPass.Corpus(allProspects),
            inquiries: inquiries,
            orgAnswers: orgAnswers,
            sources: watchedSources,
            refusals: ContactRefusal.ledger(from: refusedAddresses),
            overrides: ProducerOverrides(promotedRows: promotedProducers, demotedRows: demotedHouses),
            context: StageContext(now: now, geo: geo, clients: clientWindow),
            focusedStage: focusedStage,
            focusedKeys: focusedKeys,
            // #1770: read once for the whole pass, from the cache rather than from the token file.
            gmailConnected: GmailConnection.shared.isConnected,
            runInFlight: inFlight,
            // #3186: asked ONLY while a check is really running. Both read a marker from disk, and this
            // runs once per render pass, so an idle queue must not pay for them (#1770).
            checkRunSince: inFlight == .reachabilityCheck
                ? PrepQueueService.lastRunStartedAt(slot: .check) : nil,
            checkLookups: inFlight == .reachabilityCheck ? PrepQueueService.liveCheckLookups() : nil,
            replyRunAlive: ReplyClassifyService.isRunning(now: now),
            trace: renderTrace))
    }

    #if DEBUG
    // #1930: a fingerprint of what this view derives FROM, so an idle re-derivation can name its own
    // cause. Counts and small state values only: nothing here may cost a fetch or a filesystem stat, or
    // the diagnostic becomes part of the problem it measures. The two run markers are absent for exactly
    // that reason, and #1922's four transient send values because reading one would put back the
    // dependency that issue removed.
    private var renderTrace: [String: String] {
        [
            "prospects": "\(prospects.count)",
            "allProspects": "\(allProspects.count)",
            "orgAnswers": "\(orgAnswers.count)",
            "inquiries": "\(inquiries.count)",
            "excludedTowns": "\(excludedTownRows.count)",
            "allowedSeedTowns": "\(allowedSeedTownRows.count)",
            "promotedProducers": "\(promotedProducers.count)",
            "demotedHouses": "\(demotedHouses.count)",
            "gmail": "\(GmailConnection.shared.isConnected)",
            "stage": String(describing: focusedStage),
            "focusedKeys": "\(focusedKeys?.count ?? -1)",
            "deepLinkedKey": deepLinkedKey ?? "none",
            "deepLinkedKeys": "\(deepLinkedKeys?.count ?? -1)",
            "today": today,
        ]
    }
    #else
    private var renderTrace: [String: String] { [:] }
    #endif

    var body: some View {
        let data = makeRenderData()
        return mainContent(data)
            .sendConfirmAndReconnectAlerts(
                pendingConfirm: $pendingConfirm,
                showReconnect: $showReconnect,
                onSend: { performSend($0) },
                onConnectGmail: onConnectGmail
            )
            // #1436: compose and send Dan's reply to a hire inquiry, through the SAME screen a scouted
            // show is answered on since #2145. One list should not behave two ways.
            .sheet(item: $replyingTo) { inquiry in
                ReplySheet(composition: .answering(inquiry, context: context, feedback: feedback),
                           gmailConnected: data.gmailConnected)
            }
            .sheet(item: $pendingRowNudge) { pending in
                SendConfirmSheet(confirmation: pending.confirmation,
                                 onSend: { performRowNudge(pending, body: nil) },
                                 onCancel: { pendingRowNudge = nil },
                                 // #2575: both kinds this sheet raises are composed end to end by
                                 // Overture, so both get the box.
                                 onSendEdited: { performRowNudge(pending, body: $0) })
            }
            .sheet(item: $answeringReply) { target in
                // #2145: the one reply screen, told what it is answering. An inquiry builds its own
                // composition and reaches the same screen.
                ReplySheet(composition: .answering(target.recipient, of: target.prospect,
                                                   context: context, feedback: feedback),
                           gmailConnected: data.gmailConnected)
            }
            // #1504: the same sheet that logs one, opened on an existing record.
            .sheet(item: $editingInquiry) { InquiryIntakeSheet(editing: $0) }
            // #2718: Dan's manual route, for when the search found their reply and did not back it.
            .sheet(item: $manualLinkTarget) { target in
                LinkReplyPicker(prospect: target.prospect, recipient: target.recipient) {
                    manualLinkTarget = nil
                }
            }
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
        let reason: ShowOutcome
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
                                                     in: prospects, context: StageContext(geo: geo, clients: clientWindow)))
        return data.items.filter { wanted.contains($0.id) }
    }

    // #1805: the shows the last check was given and never reached. Read from the same rule the report's
    // offer is gated on, so the control and the run can never disagree about the set.
    private var missedByACheckKeys: [String] {
        QueueModel.keysMissedByACheck(items, today: today, geo: geo)
    }

    // #1805: finish exactly those, through the SAME confirm sheet as every other check, so a run started
    // from a report costs what the sheet says it costs. No re-selection by hand, which is the whole point:
    // the app was holding the list while Dan reconstructed it.
    private func finishShowsACheckMissed() {
        let keys = missedByACheckKeys
        guard !keys.isEmpty else { return }
        // #1616: the same learned pace the selection bar quotes, so two ways into one run cannot name two
        // different waits.
        let summary = ProbeSelection.summarizeShowsACheckMissed(
            count: keys.count, secondsPerRound: ProbeSelection.liveSecondsPerRound())
        pendingProbe = ProbeConfirm(keys: keys, dateLabel: "",
                                    title: ProbeSelectionCopy.multiDateTitle(summary),
                                    message: ProbeSelectionCopy.finishMissedShowsMessage(summary))
    }

    // #2268 built a "Check again" link on a finished date, which marked every answered show on it and
    // then ticked the date. #2371 replaced it with the tick box itself (Dan, 2026-08-09): one control on
    // the heading rather than two meaning the same thing (#1595), and a tick that writes nothing, so
    // changing his mind by unticking cannot leave a date carrying requests he never ran (#2375).

    // #2267: Dan pressed "Check again" on one card. It raises the SAME confirm sheet the date selection
    // raises, carrying the same cost sentence, and the same approval starts the same kind of run. The
    // only thing that differs is that the work-list holds one key.
    //
    // The show has already been marked by the time this runs (ProspectRowFactory), which is deliberate:
    // if he cancels the sheet the mark stands, and the card says the question is outstanding with a way
    // to try again, rather than silently forgetting he asked.
    private func requestRecheckNow(_ item: QueueItem) {
        let summary = ProbeSelection.summarizeOneShowRecheck(
            previouslyMissed: item.reachabilityUnansweredAt != nil,
            // #2621: an answer this show can actually show, its own or its organisation's. False is the
            // missed show, which since that issue raises this same sheet with nothing behind it.
            hasAnswer: item.reachabilityProbedAt != nil || item.inheritedReachability != nil,
            secondsPerRound: ProbeSelection.liveSecondsPerRound())
        pendingProbe = ProbeConfirm(keys: [item.id], dateLabel: "",
                                    title: ProbeSelectionCopy.multiDateTitle(summary),
                                    message: ProbeSelectionCopy.oneShowRecheckMessage(summary))
    }

    // #1774: the bar itself is ProbeSelectionBar, in its own file. What stays here is only the handoff of
    // finished inputs; this view reads no ticked date, which is the property that makes a tick cheap.
    private func probeSelectionBar(_ data: RenderData) -> some View {
        ProbeSelectionBar(
            selection: probeSelection,
            // #1916: a closure, so the scoutRows sweep is never paid on a queue with nothing ticked.
            rows: { scoutRows(data) },
            // #1771: `data.items`, not `self.items`. Reading the computed property here rebuilt the entire
            // queue a second time on every render, one word away from the snapshot the caller already holds.
            allItems: data.items,
            today: today, stage: focusedStage,
            overrides: ProducerOverrides(promotedRows: promotedProducers, demotedRows: demotedHouses),
            geo: geo,
            checkRunning: checkRunning,
            onRun: { keys, title, message in
                pendingProbe = ProbeConfirm(keys: keys, dateLabel: "", title: title, message: message)
            })
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
                        probeSelection.clear()
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
            // #1774: the content is a CLOSURE, and QueueScrollHolder runs it. That is the whole point: the
            // holder owns the scroll position, so a scroll writes ITS state and re-runs only this closure,
            // never QueueView.body and so never makeRenderData(). Built as a view here instead, it would
            // be assembled in QueueView.body on every scroll frame exactly as before.
            QueueScrollHolder(jumpTarget: jumpTarget) {
                VStack(alignment: .leading, spacing: OVSpacing.xl) {
                    masthead(visible: data.visible, items: data.items, fanOutLine: data.fanOutLine,
                             notices: notices, agentInputs: data.agentInputs)
                    // #1134: stage-only navigation is the only mode. The stage pills in the masthead choose
                    // what shows; this always renders the focused view for the current stage (Scout by
                    // default), or the exact away-alert leads (#308) when focusedStage is nil.
                    focusedSection(data: data)
                }
                .padding(.horizontal, OVSpacing.xl)
                .padding(.vertical, OVSpacing.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
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
    @ViewBuilder private func focusedSection(data: RenderData) -> some View {
        if focusedStage == .reachedOut {
            // #1513: inquiries and shows are ONE list here, ordered by when each next needs Dan, so the
            // "Grouped by when to reach out next" caption governs every date heading in the stage. They
            // used to be two blocks whose headings looked identical and meant different things (event
            // date above, reach-out date below).
            reachedOutList(data.reachedOut)
        } else {
            // #1774: already resolved in makeRenderData, above the scroll boundary. Re-derived here it
            // cost a StageNavigation.focusedKeys sweep of every prospect on every scroll frame.
            let rows = data.focusedRows
            VStack(alignment: .leading, spacing: OVSpacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(focusedStageHeading(rows: rows, agentInputs: data.agentInputs))
                        .font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                    Spacer()
                    // #1129: the discoverable Prep button, only on the Prep stage with kept shows and no
                    // run already in flight. Starts the run through RootView's existing selection sheet.
                    if PrepQueueButton.shouldShow(stage: focusedStage, keptToPrep: rows.count,
                                                  prepRunning: prepRunning) {
                        Button(PrepQueueButton.label(count: rows.count)) { onStartPrep() }
                            .buttonStyle(.borderedProminent)
                            .tint(OVColor.forestText)
                    }
                }
                .padding(.bottom, OVSpacing.xxs)
                .overlay(alignment: .bottom) { Rectangle().fill(OVColor.line).frame(height: 1) }
                let inquiryRows = data.inquiryRows
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
                    // QueueScrollHolder's scroll position pin the top visible one across a @Query rebuild.
                    // #1573: the scroll-target identity is namespaced, not the bare date. The inquiry
                    // groups share this layout and were keyed on the same raw dates, so a day holding both
                    // gave one id to two targets and a jump could land on the wrong one.
                    // #1774: grouped in makeRenderData, above the scroll boundary. Grouping the whole
                    // stage on every scroll frame was pure waste.
                    // #1922: QueueDateGroups owns the LazyVStack, and splices the just-sent cards in, so a
                    // send re-renders this list instead of re-deriving the store behind it. It owns the
                    // stack rather than sitting inside it deliberately: a custom view between a lazy stack
                    // and its ForEach is one child to that stack, which would realize every card in the
                    // queue at once and trade this issue's cost for a worse one.
                    QueueDateGroups(groups: data.dateGroups, sendState: sendState) {
                        // #1436: un-replied inquiries (the to-send stage) surface with the shows.
                        inquirySection(inquiryRows)
                    } content: { group, departing in
                        dateSection(group, data: data, departing: departing)
                            .id(QueueModel.showGroupScrollID(group.id))
                    }
                }
            }
        }
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
                                onMarkLost: { markInquiry(inquiry, .lost($0)) },
                                onDetachConversation: {
                                    InquiryMutations.detachConversation(inquiry, context: context,
                                                                        feedback: feedback)
                                })
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
    private func dateSection(_ group: QueueModel.DateGroup, data: RenderData,
                             departing: [String: DepartureReason]) -> some View {
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
                // #1772: `data.items`, not `self.items`. This runs for every date heading the list
                // draws, and reading the computed property rebuilt the whole queue from the store each time.
                if focusedStage != .scout, let note = QueueModel.selfBookingNote(group.items, among: data.items) {
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
                // #1597: tick the date to add it to a multi-date check. Scout only, and only where the
                // tick would actually contribute shows to a run, so it never appears on a heading that is
                // bare for some reason nobody checked.
                // #2371: that now includes a date already fully checked (Dan, 2026-08-09), where the tick
                // means "check this one again" and carries that date's answered shows. Asked through the
                // SAME function the selection prices, so the box can never appear on a date it would then
                // add nothing for.
                if focusedStage == .scout, !QueueModel.probeKeysForTickedDate(group.items, geo: geo).isEmpty {
                    ProbeDateCheckbox(groupID: group.id, selection: probeSelection)
                }
                ReachabilityProbeControl(
                    items: group.items, dateLabel: group.monthDay,
                    geo: geo,
                    isRunning: checkRunning,
                    onTap: { keys, label in pendingProbe = ProbeConfirm(keys: keys, dateLabel: label) })
            }
            .padding(.bottom, OVSpacing.xxs)
            .overlay(alignment: .bottom) { Rectangle().fill(OVColor.line).frame(height: 1) }
            // #1500: right-click the date to dismiss everything under it for one reason (Dan's call,
            // 2026-07-26: no new visible control on a header that already carries the Unavailable pill and
            // the reachability check). Scout only, by his call in the same conversation: a night of shows he
            // has already kept or drafted is not something to lose to one right-click.
            .contextMenu { if focusedStage == .scout { nightDismissMenu(group) } }

            // #1922: `departing` arrives as a plain dictionary from QueueDateGroups, which is the view
            // that read it. Reading it here would be the same dependency one level down.
            ForEach(group.items) { item in
                prospectRow(item, data: data, departure: departing[item.id])
            }
        }
    }

    // The reasons, under a heading that says what they are about to do and to how many shows. Without the
    // heading a right-click would show a bare list of dismiss reasons that names neither the action nor the
    // night. The reasons come from `ShowOutcome.menu(wasPitched:)` (#2395), the same one place a card's
    // own Dismiss menu reads, so the reason written here is one Dan could have written by hand:
    // "Went by" and "Too far" are Overture's own and are in neither half of it. (#2685: this used to say
    // `danCanChoose`, which is what the menus read before #2395 and has since been deleted; a comment
    // naming code that is not there is a bug, L32.)
    @ViewBuilder private func nightDismissMenu(_ group: QueueModel.DateGroup) -> some View {
        let plan = BulkDismiss.plan(for: group.items.map(BulkDismiss.Show.init), on: group.id)
        // #2687: one confirm covering many shows, so the refusal has to say HOW MANY of them are blocked
        // rather than speak in the singular about a list. Asked of the shows this action would actually
        // take, not of everything drawn under the heading, so the count names the same rows the reasons
        // below would have dismissed (L16).
        let genreRefusal = GenreGate.nightRefusal(
            disciplines: group.items.filter { plan.keys.contains($0.id) }.map(\.discipline),
            dateLabel: group.monthDay)
        if !plan.isEmpty {
            Section(BulkDismiss.menuTitle(count: plan.count, dateLabel: group.monthDay)) {
                if let genreRefusal {
                    Section(genreRefusal) { }
                } else {
                    ForEach(ShowOutcome.neverPitched, id: \.self) { reason in
                        Button(reason.label) {
                            pendingNightDismiss = NightDismiss(dateLabel: group.monthDay, reason: reason,
                                                               keys: plan.keys, runs: plan.runsPastTheNight,
                                                               keysOnlyThisNight: plan.keysOnlyThisNight)
                        }
                    }
                }
            }
        }
    }

    // #1134: an empty stage says what it is and, when there is work elsewhere, points Dan to the next
    // stage that has some (never auto-jumping there). The pointer logic is the pure StageEmptyState so it
    // is tested; this view just renders it in the same dashed-border card the queue used before.
    private func stageEmptyState(for stage: StageFocus, data: RenderData) -> some View {
        // #1962: the pass's resolved geography, not a fresh unresolved one, so an empty stage does
        // not re-resolve every show's place to count the others.
        let counts = StageNavigation.counts(in: prospects, context: StageContext(geo: data.geo, clients: clientWindow))
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
    private func focusedStageHeading(rows: [QueueItem], agentInputs: AgentInputs) -> String {
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
        jumpTarget = target.flatMap { QueueModel.scrollGroupID(containing: $0, among: items) }
            .map(QueueJumpRequest.init(group:))
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
        focusedKeys = StageNavigation.naturalKeys(for: status.focus, in: prospects,
                                                  context: StageContext(geo: geo, clients: clientWindow))
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
                                             context: StageContext(geo: geo, clients: clientWindow)) ?? StageNavigation.openingStage
        focusedKeys = nil   // #1140: stage mode re-derives its own membership; no frozen key set
        focusedHeading = nil
        sendState.highlight(key)
        deepLinkedKey = nil
        // #1573: land the jump in two stages, because the row alone cannot carry it. Stage one drives
        // the scrollPosition binding, which owns this ScrollView and is the only thing that can resolve
        // a target the lazy layout has not realized yet, to the group holding the row. Clearing it and
        // asking proxy.scrollTo for the row (what this did before) fought that binding and was silently
        // dropped, so the click read as dead. Computed over `items` rather than the stage's own rows: a
        // group's id is its date either way, and the stage was just set to the one containing this key.
        jumpTarget = QueueModel.scrollGroupID(containing: key, among: items)
            .map(QueueJumpRequest.init(group:))
        // Stage two: once that group is on screen its rows are realized, so nudge the row itself to the
        // top. If this runs before the layout settles it simply no-ops, leaving Dan on the right date,
        // which is the old behavior's best case rather than its actual one.
        //
        // #1928: the top, not the middle. Searching for a show and landing it halfway down the screen
        // reads as having jumped to the card above it, because the thing you went looking for has
        // unrelated cards sitting over it. The away-alert jump below already lands at the top, and the
        // two are one behaviour as far as anyone using this can tell.
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(key, anchor: .top) }
        }
        // #1922: clears only if this jump's mark is still the one showing, so a second jump landing inside
        // these 2.5 seconds does not have its mark wiped by the first jump's timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            sendState.clearHighlight(ifStill: key)
        }
    }


    // #379: visible/items threaded explicitly (not read from self.visible/self.items internally)
    // so ProspectRowViewLayoutTests-style tests can call this directly with fake data instead of
    // needing a real populated store, the same prop-threading fix used repeatedly for
    // FollowUpsView/ArchiveView/QueueView's other retrofits this cycle.
    // #1694: the possible-match fan-out warning, when there is one. Passed IN rather than read from the
    // store here, so the line the masthead draws can be pinned by a test; there is no default, so a call
    // site has to decide what it shows rather than inherit silence.
    // #1771: agentInputs is threaded in for the same reason visible/items are: the pill strip this draws
    // and the focused stage heading are two readers of one build, so the build belongs to the caller.
    // #2204: `notices` is what the app has to say for itself, threaded in for the same reason
    // `fanOutLine` is: the caller decides what is shown rather than this view inheriting silence. It has
    // no default, so a new call site has to answer the question.
    func masthead(visible: [QueueItem], items: [QueueItem], fanOutLine: String?,
                  notices: [AppNotice],
                  agentInputs: AgentInputs) -> some View {
        let summary = QueueModel.summary(visible)
        let pendingBookings = QueueModel.pendingBookingCount(items)
        return VStack(alignment: .leading, spacing: OVSpacing.sm) {
            HStack(spacing: OVSpacing.xs) {
                Text("Overture").font(OVType.wordmark).foregroundStyle(OVColor.forestText)
                #if DEBUG
                // #377: a live app and a Debug build can be open side by side showing different
                // data, so the masthead must make it unmistakable which window this is.
                Text("Debug")
                    .font(OVType.tag)
                    .foregroundStyle(OVColor.gold)
                    .padding(.horizontal, OVSpacing.sm).padding(.vertical, 2)
                    .background(Capsule().fill(OVColor.gold.opacity(0.15)))
                // #1774: the whole-store derivation count. Scrolling the queue must not move it; if it
                // climbs while scrolling, the scroll is reaching the derivation again and this issue has
                // regressed. Kept next to the Debug badge because that is where a walk is already looking.
                // #1930: and what moved to cause the last one, so an idle re-derivation names its own
                // trigger on screen. Every one is logged to queue-derivations.log in this build's data
                // directory, which is what an unattended observation reads afterwards.
                Text("derived \(QueueRenderCounter.derivations) · \(QueueRenderCounter.lastReason)")
                    .font(OVType.tag)
                    .foregroundStyle(OVColor.inkFaint)
                    .help("Whole-store derivations this launch (#1774), and which inputs moved before the last one (#1930). Scrolling must not increase the count.")
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
                    Text("\(pendingBookings)").fontWeight(.semibold).foregroundStyle(OVColor.forestText)
                    Text("to confirm").foregroundStyle(OVColor.inkFaint)
                }
            }
            .font(.system(size: 12))
            // #1131: the "Of the N high-fit: ... relationship / ... merit" breakdown line was dropped from
            // the masthead (Dan does not read it). #2638 then deleted the split itself, since nothing had
            // read it since, and a diagnostic nobody sees is not a diagnostic (L29). If the question it
            // answered ("is high fit over-filled with warm orgs?") comes back, it is four lines over the
            // shared Candidate builder and is cheaper to rewrite against the current axes than it would
            // have been to keep alive unused: this version predated the contact tier weights (#2622) and
            // would have reported them wrong.
            // #1131: only the "Scouted X ago" half stays. The prep/review/approved counts and "last prep"
            // timing that prepStatus.summary added here are duplicated by the Prep/Review/Send pill row
            // (agentStrip) directly below, so they are dropped; "Scouted X ago" is not shown anywhere else.
            Text(ScoutStatus(lastScoutedAt: ScoutService.lastScoutedAt()).summary(now: Date()))
                .font(.system(size: 11))
                .foregroundStyle(OVColor.inkFaint)
            // #1694: one record flagged as a possible match on a crowd of shows. Rust rather than the
            // faint ink around it because this is not a status, it is Overture saying a question it is
            // asking on those cards is probably wrong, and the whole point of surfacing it is that Dan
            // stops answering it. It renders only when the rule found something, so it is never the
            // line that is always there.
            if let fanOutLine {
                Text(fanOutLine)
                    .font(.system(size: 11))
                    .foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // #2091: "Overture stopped watching for replies and bookings". Sits directly under the
            // scouted/fan-out lines because those say how fresh this queue's CONTENTS are, and this says
            // whether the app is still updating them at all: a quiet queue and a dead watcher look
            // identical without it. Its own view for the same reason as ReplyRunLine below.
            WatchGapLine()
            // #2204: what the app has to say for itself. Here rather than in the toolbar's status slot,
            // which macOS moves into the overflow chevron at Dan's ordinary window width, where he has
            // never clicked and so has never read any of it. Sits with the other lines that report on
            // Overture's own health rather than on the queue's contents.
            // #2250: a notice that names a fault carries the control for it, performed by the caller
            // that owns the app's run state rather than by these lines.
            // #1805/#2250: an offer this view cannot serve is stripped before it draws, and the one it
            // CAN serve is served here, where the rows are. Everything else goes up to RootView.
            AppNoticeLines(
                notices: AppNotices.servable(notices,
                                             canFinishMissedShows: !missedByACheckKeys.isEmpty),
                perform: { action in
                    if action == .finishShowsACheckMissed { finishShowsACheckMissed() }
                    else { onNoticeAction(action) }
                })
            // #1923: its own view, so an idle queue runs no timer for it and a run starting repaints one
            // line instead of re-deriving the store. See ReplyRunLine.
            ReplyRunLine(activity: .replyClassify)
            agentStrip(agentInputs)
        }
    }

    // Per-stage "where am I needed" indicators (#15): each stage shows a coloured dot plus a label, and
    // never colour alone. A non-idle pill states what is wrong in words beside its count ("3 failed to
    // send", "3 shows with a contact held for a check"), which is what carries that rule now: #2051 removed
    // the roll-up line that used to sit above the strip, because it counted lit PILLS while every other
    // number on this screen counts shows, and it restated in vaguer terms what the pill beneath it said.
    // #863: lifted wholesale into AgentInputs.from, which builds every count by calling the same
    // StageNavigation predicate the pill's tap resolves. It used to be spelled out here, inside a
    // SwiftUI view, where no test could reach it, which is exactly why the invariant drifted twice
    // (#792, #861) with the rule stating itself in StageNavigation's header the whole time.
    // Counted across EVERY prospect, not just the ones still in the queue: a held contact's show has
    // usually already left the queue reading "Sent", which is how the person waiting became invisible.
    // #1771: this used to be a computed property here, which meant each of its two readers rebuilt it.
    // It is built once in makeRenderData and threaded down, the same rule #1121 set for `items`.
    private func agentStrip(_ inputs: AgentInputs) -> some View {
        WrapHStack(spacing: OVSpacing.xs, lineSpacing: OVSpacing.xs) {
            ForEach(AgentRoster.statuses(inputs)) { agentChip($0) }
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
        .help(AgentRoster.chipHelp(focus: s.focus, detail: s.detail))
    }

    private func agentColor(_ state: AgentState) -> Color {
        switch state {
        case .idle: return OVColor.inkFaint
        case .working: return OVColor.forestText
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
                // #2396: SHOWS, not people. This said "the people you are waiting to hear back from" while
                // the list drew a row per contact, and both halves changed together: a show is one row now
                // however many people were emailed about it. "Mark them lost" also went with the old
                // vocabulary, and the endings are named things now ("Booked", "They said no").
                Text("Once you have sent a pitch, the shows you are waiting to hear back about show up here, soonest follow-up first. A show drops off when you close it out, or when its follow-ups run out.")
                    .font(OVType.body).foregroundStyle(OVColor.inkSoft).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, OVSpacing.hero)
            .padding(.horizontal, OVSpacing.xl)
        } else {
            let now = Date()
            // #2816: built ONCE for the whole list, on the #1121 rule, rather than walking the watchlist
            // per row on every scroll frame.
            let sourceCalendars = QueueModel.sourceCalendarIndex(watchedSources)
            let groups = QueueModel.reachOutDateGroups(entries, reachDate: { $0.next })
            VStack(alignment: .leading, spacing: OVSpacing.md) {
                // #1233/#1232: the date headers below are REACH-OUT dates (Dan's call), so say so once here
                // rather than let them read like the performance-date headers on every other stage.
                // #2396: no reconciling note beneath this any more. It existed because the pill counted
                // shows while the list counted contacts (#1232), and the list counts shows now, so the two
                // numbers are the same quantity and there is nothing left to explain away.
                Text("Grouped by when to reach out next")
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: OVSpacing.sm) {
                        reachOutDateHeader(group)
                        ForEach(group.rows) { entry in
                            switch entry {
                            case .prospect(let prospect, let recipient, let next):
                                // #2644: the row is wrapped so it can SEE a send of its own in flight.
                                // Without this it took (pair, now) only, so pressing "Send a closing
                                // note" left the same button on screen for the whole second the Gmail
                                // send took, and the row then simply vanished. Dan: "at first I thought
                                // it didn't work."
                                // #2417: the same wrapper hands the departure, so the row Dan just closed
                                // out draws its quiet exit on the PRESS, while the write and the queue
                                // rebuild behind it take their quarter of a second.
                                // Read INSIDE the wrapper rather than here, on #1922's rule: read at this
                                // call site every row would re-derive on every tick of the sending row's
                                // clock.
                                ReachedOutSendAwareRow(sendState: sendState,
                                                       key: prospect.naturalKey) { sendingSince, departure in
                                    if let departure, !departure.reason.showsSendDelight {
                                        ClosedOutDepartureRow(item: departure.item)
                                    } else {
                                        reachedOutRow((prospect: prospect, recipient: recipient, next: next),
                                                      now: now, since: sendingSince,
                                                      sourceCalendars: sourceCalendars)
                                    }
                                }
                            case .inquiry(let inquiry, let row, _):
                                // #1513: the same row shape as a show, so the two read as one list. The
                                // source capsule and lifecycle line stay, because they say what an
                                // inquiry is; the card box and its own typography are gone.
                                InquiryRowView(
                                    row: row, style: .listRow,
                                    onReply: { replyingTo = inquiry },
                                    onEdit: { editingInquiry = inquiry },
                                    onMarkBooked: { markInquiry(inquiry, .booked) },
                                    onMarkLost: { markInquiry(inquiry, .lost($0)) },
                                    onDetachConversation: {
                                        InquiryMutations.detachConversation(inquiry, context: context,
                                                                            feedback: feedback)
                                    })
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
    // #2644: `since` is when a send on THIS show started, or nil. An explicit parameter rather than an
    // internal read, the same way `FollowUpsView.row(_:since:)` takes it, so what the row draws is
    // decided by its caller and a test can drive both states.
    // Internal rather than private so the on-screen test can render it in both states, the same
    // refactor #710 made to `FollowUpsView.row` for the same reason: a row whose in-flight state is read
    // from private @State cannot be driven from outside the view, and an unprovable working state is how
    // this one stayed missing.
    // #2816: `sourceCalendars` is the watchlist's sourceId-to-calendar table, built once for the whole
    // list by `reachedOutList` and handed down, on the same #1121 rule the render pass follows: resolving
    // it here would walk the watchlist once per row on every scroll frame. No default value, deliberately:
    // an empty table answers "Source listing" for every row including the ones whose link is only the
    // venue's calendar, so a caller that forgets it would get a confidently wrong label rather than a
    // compile error (L168).
    func reachedOutRow(_ pair: (prospect: Prospect, recipient: Recipient, next: Date),
                       now: Date, since: Date?, sourceCalendars: [String: String]) -> some View {
        let p = pair.prospect, r = pair.recipient
        return HStack(alignment: .top, spacing: OVSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.groupName).font(OVType.groupName).foregroundStyle(OVColor.ink)
                // #2551: the night the show is on. The date headings on this stage are REACH-OUT dates
                // (#1233's caption says so), so without this the show's own date was nowhere on screen,
                // and what to do with an open pitch depends heavily on how far out it is.
                Text(ReachedOutRowChrome.showDateLine(performanceDate: p.performanceDate,
                                                      runEndDate: p.runEndDate))
                    .font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                // #2816: the way back to the show's own page. Dan: "I'll need to add a source link to
                // this page so I can see the source on demand." What to do about an open pitch turns on
                // the show (how long it runs, who else is on the bill, whether the listing has changed
                // since the pitch went out), and once it sent, the show was a title with nowhere to go.
                //
                // With the show's own facts, above everything about the conversation, because that is
                // what it is about: the audience, the channel line and the proposed-conversation block
                // below are all about the conversation. `RowSourceLink` owns what it draws, including the
                // empty branch and #1680's label, so the three surfaces that carry it cannot differ.
                RowSourceLink(listingURL: p.sourceListingURL, sourceIds: p.sourceIds,
                              calendars: sourceCalendars)
                // #2121: everyone this row's next email reaches, so Dan can see whether he is answering
                // one person or five before he opens it, with the writer of the reply marked out.
                //
                // Marked by WEIGHT as well as colour, and carrying its own accessibility label, because a
                // highlight a screen reader cannot perceive is not a highlight (the row is read aloud as a
                // flat list of addresses otherwise).
                let audience = ReplyIdentity.rowAudience(for: r, in: p)
                ForEach(audience.lines, id: \.self) { line in
                    let wroteBack = line == audience.responder
                    Text(line)
                        .font(OVType.body)
                        .fontWeight(wroteBack ? .semibold : .regular)
                        .foregroundStyle(wroteBack ? OVColor.ink : OVColor.inkSoft)
                        .accessibilityLabel(audience.spokenLabel(for: line))
                }
                // #2919: a conversation happened here and was dealt with, which this row used to say
                // nothing about at all. Once #2170's stamp retires the Answer control, the row fell back
                // to exactly what it draws for a pitch nobody replied to, so a live negotiation and total
                // silence rendered identically (L152).
                //
                // Directly under the audience, because it is about the people just listed: the writer's
                // own address is one of those lines and is already marked as the one who wrote, which is
                // why this line names nobody. Nothing is wrong here, so inkSoft rather than rust, and not
                // gold, which is reserved for what Dan can act on.
                if let answered = AnsweredReplyNote.line(for: r, in: p, now: now) {
                    Text(answered).font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
                }
                // #1630: a form pitch has no address and no thread, so the row has to account for the
                // silence itself. Said in inkSoft, not rust: nothing is wrong here.
                // #2716: and once a conversation is attached, the half of that sentence claiming a reply
                // cannot be seen is false, so the line says what is true now instead of contradicting the
                // address the attach put on the row above it.
                // #2711: and once Dan has recorded a reply that arrived somewhere Overture cannot see, it
                // stops saying no reply can be seen, because the badge beside it now says one arrived.
                if r.outreachChannel == .contactForm {
                    Text(FormOutreachCopy.channelLine(formURL: r.formOutreachURL,
                                                      hasWatchableConversation: r.hasWatchableConversation,
                                                      replyMarkedByHand: r.replyMarkedByHandAt != nil))
                        .font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
                }
                // #2718: the question Overture wants answered, ON THE ROW, so Dan says yes or no without
                // opening Gmail. Every branch draws something, because a state that renders nothing sits
                // in the data and vanishes from the product (L45), and the four say different things
                // rather than one sentence covering them all: found nothing yet, not read yet, stopped
                // looking, and all declined are four different facts about the same row (L11).
                proposedConversationBlock(r, of: p, now: now)
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
                // #2550: asked of what is OWED, not of `pair.next`, which carries the sort floor. Every open
                // pitch used to go rust on its own night with nothing due on it.
                let dueNow = ReachedOutQueue.isDueNow(for: r, of: p, now: now)
                let replyOffered = ReplyPanel.isOffered(for: r, in: p)
                // #2166: the label yields to Answer, whose existence already means "now". Suppressed
                // rather than deleted: on a row with nobody waiting it is the only thing saying when the
                // next touch is due, and it renders the future case too. ReachedOutRowChrome owns the
                // rule so it is testable and so #2168's guard can see the label is covered.
                // #2112: the show has been and gone and this pitch is still open, so the row says so
                // INSTEAD of counting down to a follow-up that can no longer help. A hint, never a cut:
                // Overture does not decide a pitch is lost on Dan's behalf, which is the same rule that
                // keeps WentByRetirement off shows he actually pitched. Rust, because it is the app
                // saying the quiet on this row is not what it looks like.
                if ReachedOutRowChrome.showsTimingLabel(replyOffered: replyOffered) {
                    if let hint = ReachedOutClose.passedHint(hasOpened: p.hasOpened(today: today),
                                                             isStillOpen: r.resolution == nil) {
                        Text(hint).font(OVType.meta).foregroundStyle(OVColor.rust)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if SpentNudges.isSpent(show: p),
                              let spent = SpentNudges.marker(eventDay: p.performanceDate, today: today) {
                        // #2398: the emails are done and the show is still open, which is a state this slot
                        // could not previously describe: it read exactly like a show nobody had got round
                        // to. Ahead of the countdown deliberately, because there is nothing left to count
                        // down TO, and a "in 6 days" here would be a promise Overture will not keep.
                        Text(spent).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                    // #2169: a dated form pitch names the NIGHT here ("tonight", "3 days ago") instead of
                    // counting down to a send that will never happen.
                    // #2550: and the whole slot is decided from what is OWED, not from `pair.next`, which
                    // carries #2397's floor and is a SORT anchor. Read as a due date it told Dan to reach
                    // out on every show's own night beside a row with nothing to press.
                    Text(ReachedOutQueue.timingLabel(for: r, of: p, now: now, today: today))
                        .font(OVType.meta).foregroundStyle(dueNow ? OVColor.rust : OVColor.inkSoft)
                    }
                }
                // #2128: somebody is waiting on an answer, which is the actual job on this row, so it
                // leads. Keyed on the peer who WROTE, since the row stands on whoever sorts first.
                // #2166: and it now carries the urgency the label used to, in its own fill.
                if replyOffered {
                    Button(ReplyPanelCopy.answer) {
                        answeringReply = ReplyTarget(prospect: p,
                                                     recipient: ReplyIdentity.answering(for: r, in: p))
                    }
                    .buttonStyle(.plain).font(OVType.meta)
                    .foregroundStyle(ReachedOutRowChrome.answerLabel(dueNow: dueNow))
                    .padding(.horizontal, OVSpacing.md).padding(.vertical, 4)
                    .background(Capsule().fill(ReachedOutRowChrome.answerFill(dueNow: dueNow)))
                }
                // #2112/#2224: closing the pitch out, from the stage Dan stands on rather than the
                // Archive card he never opens. Unconditional: a show can get its yes at any moment, and a
                // control that appeared only once the date had passed would be missing on exactly the
                // night it is wanted. The hint above is the other trigger for the same act.
                // #2395: the endings come from the one vocabulary, and from the half that is possible for
                // this show, so nobody is offered "Date conflict" on a pitch they already sent.
                CloseOutMenu(outcomes: ShowOutcome.menu(wasPitched: p.wasPitched)) { outcome in
                    closeOut(p, as: outcome)
                }
                // #2711: the only thing Dan could record about a DM pitch was that it ENDED. A reply that
                // arrives inside Instagram never reaches Gmail, so a conversation that had actually
                // STARTED was unrecordable, and the show sat reading silent until its decide date while
                // Overture went on pitching the rest of its contacts underneath it.
                //
                // Offered only where Overture genuinely cannot watch, so it can never become a second
                // writer racing reply detection. The undo takes its place once pressed rather than sitting
                // beside it, because a control that keeps offering itself after being pressed reads as
                // broken and gets pressed again (L44).
                HandMarkedReplyControl(recipient: r, prospect: p) {
                    HandMarkedReply.mark(r, in: p, now: now)
                    try? context.save()
                } onUndo: {
                    HandMarkedReply.undo(r, in: p)
                    try? context.save()
                }
                // #2644: while a send on this show is in flight, the action control is REPLACED by the
                // live label rather than sitting there unchanged. The three states the standing rule
                // requires are all in `LiveRunLabel`: it started (the words appear in place of the
                // button), it is still alive (the elapsed count moves), and it stalled (the timeout turns
                // into a retry) instead of one indefinite silence. The same control and the same
                // `performRowNudge` carry the nudge as well as the closing note, so both are covered.
                //
                // Replacing the button rather than sitting beside it is the L44 half: a control that
                // keeps offering itself after being pressed reads as broken, and gets pressed again.
                if let since {
                    LiveRunLabel(base: "Sending", since: since, timeout: RunTimeouts.send,
                                 font: OVType.meta, color: OVColor.inkSoft)
                } else if let label = ReachedOutAction.of(r, in: p, now: now, today: today).label {
                    // #2130: the control says what is actually due, because "due now" here is min of three
                    // clocks and meant six different things behind one wording. Nothing due, no button: an
                    // always-present control that refuses on press is the defect this replaces.
                    Button(label) { startRowAction(r, of: p, now: now) }
                        .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.forestText)
                }
            }
        }
        .padding(.vertical, OVSpacing.xs)
    }

    @ViewBuilder private func prospectRow(_ item: QueueItem, data: RenderData,
                                          departure: DepartureReason?) -> some View {
        if let departure, departure.showsSendDelight {
            // #361: the leaving delight. Appears instantly in place of the just-sent row (insertion
            // .identity), then the glide-up removal plays when `departing` clears. Reduced Motion drops
            // the glide to a plain fade; the drawn line is already dropped by the timing plan.
            SendDelightRow(item: item, timing: SendDelightTiming.plan(reduceMotion: reduceMotion))
                .transition(.asymmetric(
                    insertion: .identity,
                    removal: reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)))
        } else if departure != nil {
            // #2417: the quiet exit, for a row leaving because Dan recorded an ending. Deliberately NOT
            // SendDelightRow: the commonest endings are "no response" and "they passed", and the gold
            // seal on those reads as the app congratulating him on a rejection.
            ClosedOutDepartureRow(item: item)
                .transition(.asymmetric(
                    insertion: .identity,
                    removal: reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)))
        } else {
            // #1219/#1246: the persistent self double-booking marker, on the row itself so it travels with
            // the show and never vanishes when the OTHER show changes stage. Names the clashing show(s).
            // Not in Scout (untriaged candidates are not commitments Dan is protecting yet).
            // #1772: `data.items`, not `self.items`. This runs for every CARD, so reading the computed
            // property rebuilt the entire 724-row queue once per card on every render pass.
            let selfBookingMarker = focusedStage != .scout
                ? SelfBookingCopy.rowMarker(QueueModel.selfBookingConflictNames(for: item, among: data.items))
                : nil
            // #1699 part 3: the same night, when the published curtain times prove Dan can work both.
            // Nothing to decide, so it is not gold and carries no warning icon: gold is reserved for what
            // he can act on, and this line exists only so a doubled-up night does not go silent entirely.
            // Nil whenever the row also has a real clash, so the two lines never stack.
            let workableNote = focusedStage != .scout
                ? QueueModel.selfBookingWorkableNote(for: item, among: data.items)
                : nil
            VStack(alignment: .leading, spacing: 4) {
                if let marker = selfBookingMarker {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar.badge.exclamationmark")
                        Text(marker)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OVColor.gold)
                } else if let workableNote {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                        Text(workableNote)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                // #1922: the send's own state is read INSIDE QueueSendAwareRow, not here. Read at this
                // call site it would be read during QueueView's body, and every "Sending…" would re-derive
                // the whole store; read there, a send redraws the cards on screen and nothing else.
                QueueSendAwareRow(key: item.id, sendState: sendState) { highlightedKey, sendingSince, replySince in
                    ProspectRowFactory.row(item, today: today, prospects: prospects, context: context, feedback: feedback,
                                          dayOffOffer: dayOffOffer,
                                          gmailConnected: data.gmailConnected,
                                          // #2267: the row's own "Check again" spends money, so it goes
                                          // through the SAME confirm sheet the date selection raises,
                                          // rather than a second sentence about the same spend.
                                          onRecheckNow: { requestRecheckNow($0) },
                                          checkRunning: checkRunning,
                                          probeRunning: data.probeRunning,
                                          checkRunSince: data.checkRunSince,
                                          checkLookups: data.checkLookups,
                                          undoStack: undoStack,
                                          highlightedKey: highlightedKey, outboundSendSince: sendingSince,
                                          replySendSince: replySince,
                                          onSend: { requestSend(item) }, onSendReply: { rid in sendReply(item, rid) },
                                          onReprep: { mode in requestReprep(item, mode) },
                                          // #2524: why a date ten months out is sitting here. The verdict
                                          // is decided in the queue build; whether THIS list says it is
                                          // decided in QueueModel, not in this body.
                                          offeredEarlyAsAClient: QueueModel.saysOfferedEarlyAsAClient(
                                              item, stage: focusedStage),
                                          showingTooFar: false,
                                          userExcludedTowns: userExcludedTowns,
                                          allowedSeedTowns: allowedSeedTowns)
                }
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
            Task { @MainActor in
                if let onLaunchPrep {
                    await ProspectMutations.reprep(item, mode: mode, prospects: prospects, context: context,
                                                   feedback: feedback, startPrep: onLaunchPrep)
                } else {
                    await ProspectMutations.reprep(item, mode: mode, prospects: prospects, context: context,
                                                   feedback: feedback)
                }
            }
        }
    }

    // #2050: there is no separate Approve to guard any more. The self-booking warning did not go with it:
    // the send confirmation sheet carries it (`sendSelfBookingWarning` below), computed from the same
    // `selfBookingConflictNames` this guard reads, so the clash is still named, once, at the moment Dan
    // actually commits rather than in an alert before a second screen.
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
    //
    // #2050: also step 1 of APPROVING, which is no longer a separate press on a separate screen. A drafted
    // show reaches this the same way an approved one does, and `approving: true` is what lets the sheet
    // name the people a not-yet-approved draft is about to reach. Nothing is written until he confirms, so
    // cancelling here leaves the draft exactly as it was.
    private func requestSend(_ item: QueueItem) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              var confirmation = SendConfirmation(prospect: model, approving: true) else { return }
        // #1219: warn at the committing moment when a DIFFERENT committed show shares this date, naming it
        // so Dan remembers which one. Fires on any commitment (booked / emailed / live draft), not just an
        // already-emailed one, and compares against the whole queue so a show in any stage still counts.
        confirmation.selfBookingWarning = QueueModel.sendSelfBookingWarning(for: item, among: items)
        // #2017: the sheet redraws for whatever he ticks, so the To line, the preview's greeting and the
        // promise underneath describe the email actually about to leave rather than the default one.
        let warning = confirmation.selfBookingWarning
        pendingConfirm = PendingSend(
            id: item.id, confirmation: confirmation,
            rebuild: { selected, together in
                guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return nil }
                // Asked of a COPY's worth of state: the real choice is only written at the commit, so a
                // preview of "one email each" cannot leave the show changed if he cancels.
                let was = model.sendsTogetherOverride
                model.sendsTogetherOverride = together
                defer { model.sendsTogetherOverride = was }
                guard var rebuilt = SendConfirmation(prospect: model, approving: true,
                                                     selecting: selected) else { return nil }
                rebuilt.selfBookingWarning = warning
                return rebuilt
            },
            onSendSelection: { selected, together in
                performSend(item.id, selecting: selected, together: together)
            }
        )
    }

    // #2417: record an ending, and make the row start leaving on the PRESS rather than after the write.
    //
    // The order is the whole fix. Marking the departure first costs one card, because SendProgressState's
    // writes notify only the views that read it and QueueView's own body reads none of them (#1922). The
    // mutation that follows saves and then makes SwiftData rebuild every card, which is a quarter of a
    // second at the store's present size and grows with it. Doing the cheap visible thing first is what
    // makes the control answer immediately, whatever the rebuild costs behind the animation.
    //
    // The snapshot is taken before the write for the same reason performSend takes one: once the ending
    // lands, the row is gone from the queue's answer and the card playing the exit cannot come from it.
    private func closeOut(_ p: Prospect, as outcome: ShowOutcome) {
        let snapshot = QueueItem(p)
        withAnimation(.easeOut(duration: 0.15)) {
            sendState.depart(snapshot.id, as: snapshot, because: .closedOut)
        }
        ProspectMutations.recordOutcome(snapshot, outcome,
                                        prospects: prospects, context: context,
                                        feedback: feedback)
        // Cleared after the exit plays. Never before the rebuild lands: clearing early would drop the
        // snapshot while the real row is still in the queue's answer, and the row Dan just closed out
        // would flash back onto the screen.
        let t = SendDelightTiming.plan(reduceMotion: reduceMotion)
        DispatchQueue.main.asyncAfter(deadline: .now() + t.holdBeforeExit) {
            withAnimation(.easeOut(duration: t.exit)) {
                sendState.finishDeparting(snapshot.id)
            }
        }
    }

    private func performSend(_ naturalKey: String, selecting: [String]? = nil, together: Bool? = nil) {
        pendingConfirm = nil
        // #361: snapshot the row now, while it's still present, so its leaving delight can render after
        // the send removes it from `visible`. Only a send that EMPTIES the show (onSent fullySent) plays
        // it; a partial send on a multi-recipient show keeps the row, so no exit yet.
        let snapshot = items.first(where: { $0.id == naturalKey })
        // #2050: approve-then-send, as ONE action, because the sheet Dan just read IS the approval. On a
        // show that is already approved (a retry, or one approved before this change) it sends without
        // re-approving. The pair lives in ProspectMutations, not here, so it has a seam a test can reach.
        guard let confirmed = snapshot else { return }
        ProspectMutations.approveAndSend(confirmed, prospects: prospects, context: context, feedback: feedback,
                                      selecting: selecting, together: together,
                                      markSending: { sendState.markSending($0) },
                                      clearSending: { sendState.clearSending($0) },
                                      onNeedsReconnect: { showReconnect = true },
                                      onSent: { id, fullySent in
                                          guard fullySent, let snap = snapshot else { return }
                                          sendState.depart(id, as: snap)
                                          let t = SendDelightTiming.plan(reduceMotion: reduceMotion)
                                          DispatchQueue.main.asyncAfter(deadline: .now() + t.holdBeforeExit) {
                                              withAnimation(.easeOut(duration: t.exit)) {
                                                  sendState.finishDeparting(id)
                                              }
                                          }
                                      })
    }

    // #2130: what the row's control actually does, one branch per kind, so the wording and the behaviour
    // are decided in the same place. A send never fires from the press: it builds the exact email and puts
    // it in front of Dan first, the same confirmation the Due sheet uses (L64).
    // #2718: everything the row says and offers about a proposed conversation. The DECISIONS all live in
    // `ProposedConversation`, so this stays a rendering of a state rather than a second copy of the rule
    // (the #863/#885 rule).
    @ViewBuilder
    private func proposedConversationBlock(_ r: Recipient, of p: Prospect, now: Date) -> some View {
        switch ProposedConversation.state(of: r, now: now) {
        case .notApplicable:
            EmptyView()
        case .none(let searched):
            Text(searched ? ProposedConversationCopy.searchedAndFoundNothing
                          : ProposedConversationCopy.notSearchedYet)
                .font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
            manualLinkControl(r, of: p)
        case .stoppedLooking:
            Text(ProposedConversationCopy.stoppedLooking)
                .font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
            manualLinkControl(r, of: p)
        case .allDeclined:
            Text(ProposedConversationCopy.allDeclined)
                .font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
            manualLinkControl(r, of: p)
        case .attachedAwaitingAnswer:
            Text(ProposedConversationCopy.attachedAwaitingAnswer)
                .font(.system(size: 10)).foregroundStyle(OVColor.gold)
        // #2806: the state that used to draw nothing. Inkfaint rather than gold: nothing is waiting on
        // him, so this is an account of what happened and not a call to act, and colouring it like the
        // line above would put a second thing demanding attention on a row that needs none.
        case .attachedAndAnswered:
            Text(ProposedConversationCopy.linkedAndAnswered(wroteAddress: r.attachWroteAddress,
                                                            address: r.email))
                .font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        case .proposed(let candidate):
            VStack(alignment: .leading, spacing: 3) {
                Text(ProposedConversationCopy.question)
                    .font(OVType.meta).foregroundStyle(OVColor.ink)
                Text(ProposedConversationCopy.sender(name: candidate.fromName,
                                                     address: candidate.fromAddress))
                    .font(.system(size: 10)).foregroundStyle(OVColor.ink)
                Text(ProposedConversationCopy.detail(subject: candidate.subject,
                                                     sentAt: candidate.sentAt, now: now))
                    .font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
                // What confirming DOES, beside the control that does it, so what Dan approves is exactly
                // what happens including who it reaches (L64).
                Text(ProposedConversationCopy.confirmDetail(address: candidate.fromAddress))
                    .font(.system(size: 10)).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: OVSpacing.sm) {
                    // Three visibly different states, never one indefinite spinner: at rest, working, and
                    // (through the feedback surface) failed.
                    if linkingConversationFor == r.id {
                        ProgressView().controlSize(.small)
                        Text(ProposedConversationCopy.linking).font(OVType.meta)
                            .foregroundStyle(OVColor.inkSoft)
                    } else {
                        Button(ProposedConversationCopy.confirm) { linkProposedConversation(r, of: p) }
                            .font(OVType.meta)
                        Button(ProposedConversationCopy.decline) { declineProposedConversation(r) }
                            .buttonStyle(.plain).font(OVType.meta)
                            .foregroundStyle(OVColor.inkSoft)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    // Dan's explicit ask: a way to tell Overture about the email when it did not propose one.
    @ViewBuilder
    private func manualLinkControl(_ r: Recipient, of p: Prospect) -> some View {
        if ProposedConversation.offersManualLink(r) {
            Button(ProposedConversationCopy.manualLink) { manualLinkTarget = ManualLinkTarget(prospect: p, recipient: r) }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(OVColor.gold)
        }
    }

    private func linkProposedConversation(_ r: Recipient, of p: Prospect) {
        linkingConversationFor = r.id
        Task { @MainActor in
            let outcome = await ConfirmProposedConversation().confirm(on: r, of: p, in: context)
            linkingConversationFor = nil
            switch outcome {
            case .notConnected: showReconnect = true
            case .failed(let reason), .refused(let reason):
                feedback.acknowledge(reason, tone: .warning)
            case .attached(_, let saveFailed):
                feedback.acknowledge(saveFailed ? ProposedConversationCopy.couldNotSaveLink
                                                : ProposedConversationCopy.linked,
                                     tone: saveFailed ? .warning : .info)
            }
        }
    }

    private func declineProposedConversation(_ r: Recipient) {
        ProposedConversation.decline(on: r)
        do {
            try context.save()
        } catch {
            feedback.acknowledge(ProposedConversationCopy.couldNotSaveLink, tone: .warning)
        }
    }

    private func startRowAction(_ r: Recipient, of p: Prospect, now: Date) {
        switch ReachedOutAction.of(r, in: p, now: now, today: today) {
        case .sendNudge:
            // #2397: one kind of nudge now. The conversation track's own re-touch email went with the
            // states that chose its wording, so a follow-up is always the silent sequence's own.
            if let confirmation = SendConfirmation(followUpFor: r, of: p) {
                pendingRowNudge = PendingRowNudge(naturalKey: p.naturalKey, recipientId: r.id,
                                                  confirmation: confirmation, isClosing: false,
                                                  isConversation: false)
            }
        case .sayHowItEnded, .sayWhatHappened, .none:
            break   // no control is drawn for these
        }
    }

    // #2575: `body` is what the send sheet's text box held when Dan pressed Send, nil for a send he did
    // not edit. Passed straight through; nothing recomposes it on the way.
    private func performRowNudge(_ pending: PendingRowNudge, body: String?) {
        pendingRowNudge = nil
        // #2710: one branch now. The conversation track's only email was the closing note, which is gone,
        // so a row nudge is a follow-up and nothing else.
        ProspectMutations.sendFollowUp(pending.naturalKey, pending.recipientId,
                                       prospects: prospects, context: context, feedback: feedback,
                                       body: body,
                                       markSending: { sendState.markSending($0) },
                                       clearSending: { sendState.clearSending($0) })
    }

    private func sendReply(_ item: QueueItem, _ recipientId: String) {
        ProspectMutations.sendReply(item, recipientId, prospects: prospects, context: context, feedback: feedback,
                                    markSending: { sendState.markReplySending($0) },
                                    clearSending: { sendState.clearReplySending($0) },
                                    onNeedsReconnect: { showReconnect = true })
    }
}

// #1774: one request to put a date group on screen. An EVENT, deliberately, not a destination.
//
// QueueScrollHolder watches this with .onChange, and .onChange fires on a change. Carrying the bare group
// id, a second jump to the SAME group was not a change and was silently dropped: Dan searched a show and
// landed on it, scrolled away, searched the same show again, and the click did nothing (his walk of the
// Debug build, 2026-08-01). The scroll position had moved but the channel still held that group, so
// setting it again said nothing. That is the #1573 dead click arriving by a new route.
//
// Two searches for one show are two events even though they name one group, so each request carries its
// own identity and no two are equal. A request does still equal ITSELF, so a parent re-render that hands
// the same one down again does not re-fire the jump and yank Dan off a row he has since scrolled to.
struct QueueJumpRequest: Equatable {
    let group: String
    private let token: UUID

    init(group: String) {
        self.group = group
        self.token = UUID()
    }
}

#if DEBUG
// #1774: how many times the queue has derived its whole dataset since the count was last zeroed.
//
// This exists because the fix it measures is invisible from the outside. A queue that still re-derives on
// every scroll frame looks exactly like one that does not: both scroll, both hold their place across a
// scout, both land a deep link. The only way to tell them apart is to watch this number while scrolling,
// and see that it does not move.
//
// Surfaced beside the Debug badge in the masthead rather than logged, because NSLog output is invisible
// from the running Debug app, so a logged count is a count nobody reads.
//
// DEBUG only. In Release it would be shared mutable state ticking on the main thread for no reader.
// #1930: the count alone says an idle queue re-derived twice in three minutes. It cannot say WHY, and
// without that the only method available is eliminating candidates by reading code, which is how #1930's
// own candidate list was written and how two of its three entries turned out to be wrong (the reconcile
// timer is at its 30 minute default and the Downbeat export had not changed that day).
//
// So each derivation records a fingerprint of the inputs this view derives FROM, and reports which of them
// moved since the last one. "nothing this view reads" is the most valuable answer of the three: it means
// the invalidation came from outside (RootView rebuilding this view, or an environment change), which no
// amount of staring at QueueView would ever have told anybody.
//
// Written to a file as well as shown on screen, because catching an idle trigger means leaving the app
// alone for minutes and then reading what happened, which a number on a masthead cannot do (and NSLog
// output is invisible from the running Debug app).
enum QueueRenderCounter {
    nonisolated(unsafe) private(set) static var derivations = 0
    // What moved before the most recent derivation. Shown beside the count in the masthead.
    nonisolated(unsafe) private(set) static var lastReason = firstRender
    // #1930: keyed by SURFACE, because the trace now carries two of them and one shared "previous" would
    // make every queue derivation report the inputs of whatever rendered above it as having moved, naming
    // the wrong surface on every line.
    nonisolated(unsafe) private static var previous: [String: [String: String]] = [:]
    nonisolated(unsafe) private static var renders: [String: Int] = [:]
    // #1931: the rows the LAST derivation produced. Value-type snapshots, already built by that pass, so
    // comparing them costs no fetch and no stat.
    nonisolated(unsafe) private static var previousRows: [QueueItem]?

    static let firstRender = "first render"
    static let nothingVisible = "nothing this view reads"
    // #1931: every count identical and the rows different anyway, which is what an edit to an existing row
    // looks like: a show kept, a rank rewritten by a Prep run, a reply landing. Reported in its own words
    // rather than as `nothingVisible`, because that answer is the one the whole diagnostic is trusted for
    // (it means the invalidation came from outside this view) and a false one sends the next investigation
    // hunting the screen above the queue for something the store did.
    static let rowsChanged = "rows changed"

    static let queueSurface = "queue"
    static let rootSurface = "root"

    // Where an unattended observation ends up. Debug builds keep their own data directory, so this can
    // never land beside the live store's files.
    static var logURL: URL { StoreLocation.dataDirectory.appendingPathComponent("queue-derivations.log") }

    // `to` is injected purely so a test can watch a real line land somewhere other than this Mac's own
    // Debug data directory, which the suite would otherwise append to on every run.
    //
    // `underTests` is the seam that keeps the suite out of the file entirely. The unit suite hosts itself
    // in the full app (TEST_HOST), so a test run opens a real window that renders the real queue, and those
    // renders were landing in the same log a real observation is read from: two runs interleaved in one
    // file, each starting again at #1. The count itself is in-memory and harmless, so only the file is
    // protected. Same signal the launch-time background work already skips on (#195).
    static func recordDerivation(inputs: [String: String] = [:], rows: [QueueItem]? = nil,
                                 to url: URL? = nil,
                                 underTests: Bool = AppEnvironment.isRunningUnderTests,
                                 maxLogBytes: Int = AgentLogLocation.defaultMaxLogBytes) {
        derivations += 1
        // #1931: only ever a claim about two sets of rows that both exist. On the first derivation there is
        // nothing to compare against, and saying the rows changed would be inventing a finding.
        let rowsChanged: Bool
        if let rows, let previousRows { rowsChanged = rows != previousRows } else { rowsChanged = false }
        if let rows { previousRows = rows }
        lastReason = reason(for: inputs, since: previous[queueSurface] ?? [:], rowsChanged: rowsChanged)
        previous[queueSurface] = inputs
        guard !underTests else { return }
        append(line: "\(queueSurface) #\(derivations) \(lastReason)", to: url ?? logURL,
               maxBytes: maxLogBytes)
    }

    // #1930: a render of a surface that does not itself sweep the store, recorded so a queue derivation
    // reporting `nothingVisible` can be read against the render directly above it that triggered it. Both
    // surfaces write to ONE log, in the order the two happened, because the attribution is the whole point
    // and two files would leave it to be reconstructed from timestamps.
    //
    // Never counted as a derivation: the masthead number answers "is this app sweeping the store while
    // nobody touches it", and a render that swept nothing must not inflate it.
    @discardableResult
    static func recordRender(surface: String, inputs: [String: String] = [:], to url: URL? = nil,
                             underTests: Bool = AppEnvironment.isRunningUnderTests,
                             maxLogBytes: Int = AgentLogLocation.defaultMaxLogBytes) -> String {
        let n = (renders[surface] ?? 0) + 1
        renders[surface] = n
        let why = reason(for: inputs, since: previous[surface] ?? [:])
        previous[surface] = inputs
        guard !underTests else { return why }
        append(line: "\(surface) #\(n) \(why)", to: url ?? logURL, maxBytes: maxLogBytes)
        return why
    }

    // Which inputs moved. Pure, so the rule this diagnostic reports by is itself tested rather than being
    // one more thing taken on trust while it is used to judge everything else.
    static func reason(for inputs: [String: String], since previous: [String: String],
                       rowsChanged rowsMoved: Bool = false) -> String {
        guard !previous.isEmpty else { return firstRender }
        let changed = inputs.keys.filter { inputs[$0] != previous[$0] }
        // An input that stopped being reported is a change too, and silently dropping it would report
        // "nothing changed" for a render that was not the same shape at all.
        let dropped = previous.keys.filter { inputs[$0] == nil }
        let moved = Set(changed).union(dropped).sorted()
        // #1931: an input that moved explains this derivation on its own, so it is what gets named. The
        // rows are the answer only where no input moved, which is the case the counts are blind to.
        guard moved.isEmpty else { return moved.joined(separator: ", ") }
        return rowsMoved ? rowsChanged : nothingVisible
    }

    // Best effort, but never silent: a write that fails says so on the masthead beside the count, rather
    // than leaving an empty log to be read as an idle queue that never re-derived.
    static func append(line: String, to url: URL,
                       maxBytes: Int = AgentLogLocation.defaultMaxLogBytes) {
        // #1933: bounded, by the SAME rotation every other log in this app uses (LogRotation.cap),
        // rather than a second mechanism invented here. One line per whole-store derivation with
        // nothing trimming it meant an afternoon of scrolling, sending and re-prepping wrote thousands
        // of lines, and every later run appended to the same file: the diagnostic got harder to read
        // the more it was used, and it was unbounded disk in the directory that also holds the store.
        //
        // Capped on WRITE rather than at launch, matching FeedMovementLog, because this log's whole
        // purpose is unattended observation over a long session, and a launch-only cap would let one
        // session grow without limit, which is the case that produced the issue.
        LogRotation.cap(files: [url], maxBytes: maxBytes)
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                return
            } catch {
                lastReason += " (log write failed)"
                return
            }
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            lastReason += " (log create failed)"
        }
    }

    // #1930: how many times each live object the screen above holds has been WRITTEN. Counted at the
    // write, never read off the object, because reading an @Observable property to report it would create
    // the dependency being measured (#1922). A static count creates none, so the fingerprint can name a
    // cause that was invisible to it before: without this, every render an object triggered reported
    // `nothing this view reads`, which is the answer the whole diagnostic is trusted for.
    //
    // Zero for an object nothing has touched, never absent, so a render's fingerprint is the same SHAPE
    // every time: an input appearing mid-session would read as a change of its own (`reason` counts a
    // dropped key as movement, deliberately).
    nonisolated(unsafe) private static var writeCounts: [String: Int] = [:]

    static func noteWrite(_ label: String) { writeCounts[label, default: 0] += 1 }

    static func writes(_ label: String) -> Int { writeCounts[label] ?? 0 }

    static func reset() {
        writeCounts = [:]
        derivations = 0
        lastReason = firstRender
        previous = [:]
        renders = [:]
        previousRows = nil
    }
}
#endif

// #1774: the queue's scroll view, and the only owner of its scroll position.
//
// `.scrollPosition(id:)` is a read-write binding: SwiftUI writes it every time a date heading crosses the
// top. Bound to @State on QueueView, each of those writes invalidated a body whose first line derives the
// entire store, so scrolling past ten dates dragged all 724 prospects through the CPU ten times. @State
// belongs to the view that declares it and cannot invalidate a parent, so holding the position here means
// a scroll re-runs `content` and nothing above it.
//
// `content` is a closure rather than a built view for that same reason, and it is the load-bearing detail:
// a view built at the call site would be assembled inside QueueView.body on every scroll frame, which is
// the cost this exists to remove, just one level further down.
//
// #976: the position survives a @Query rebuild, which is why it exists at all. `prospects` is a @Query and
// this is the window Dan reviews in, rebuilt by every scout and Prep run; a plain ScrollView drops its
// offset to the top on each one (the #974 shape), so mid review the queue snapped away before he could act
// on a row. Pinned to the top visible date group, not the individual show, because the groups are the
// stable landmarks a run reshuffles shows within.
//
// #1573: the deliberate jumps (a deep link, an away-alert lead, a picked search result) arrive through
// `jumpTarget` and DRIVE this position, rather than clearing it and asking proxy.scrollTo for a row id.
// Clearing and scrolling was the bug: the two mechanisms fought over the same ScrollView and the row jump
// was silently dropped, so a picked search result did nothing at all.
struct QueueScrollHolder<Content: View>: View {
    // The group a deliberate jump wants on screen. @State on QueueView, so setting it always invalidates
    // and always reaches this view; nil means no jump is pending and the position is Dan's own scrolling.
    let jumpTarget: QueueJumpRequest?
    @ViewBuilder let content: () -> Content

    @State private var topGroup: String?

    var body: some View {
        ScrollView { content() }
            .scrollPosition(id: $topGroup, anchor: .top)
            .onChange(of: jumpTarget) { _, target in
                if let target { topGroup = target.group }
            }
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
            HStack(spacing: OVSpacing.xs) {
                Spacer(minLength: OVSpacing.sm)
                Text(ReachabilityProbeCopy.dateCheckedMarker)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OVColor.inkFaint)
                // #2268 put a "Check again" link here, answering Dan's "is there a way to re-check an
                // entire date with multiple events?". #2371 moved that job to the tick box beside the
                // date, which now stays on a finished date: one control, and one that spends nothing and
                // writes nothing until the selection bar's confirm.
            }
        }
    }
}
