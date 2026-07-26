import SwiftUI
import SwiftData

// #800: the sources Overture re-checks on every scout. Read-only for now: Phase 4 is what adds a source
// and Phase 5 is what lets Dan stop watching one. It ships here so the migration that made Carnegie row
// one is visible in the app rather than only in a database.
//
// The sections are separate, and they are labelled in WORDS, because the one confusion Dan named is a
// broken source reading as an org that asked him to stop. SourceGrade is what decides which section a
// row lands in, and it is a tested domain rule, so this view has no logic of its own to get wrong.
struct SourcesView: View {
    // #970: read ONE source now. Handed in rather than reached for, because starting a detached run is
    // RootView's job (it owns the live-run state and the one-at-a-time guard), and a view that launched
    // its own run would be a second place that could start one.
    var readOne: (WatchedSource) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback
    @Query(sort: \WatchedSource.orgName) private var sources: [WatchedSource]
    // #794: read to compute each source's lifetime yield (found/kept/sent/booked). The tally and its
    // sentence both live in SourceYield, a tested pure function, so this view has no counting of its own.
    @Query private var prospects: [Prospect]

    // #802: the sheet is where the watchlist is MANAGED, because it was previously the only place it
    // could be seen and nowhere it could be changed: a calendar could only join by pasting a lead, and
    // unticking "keep watching" on that sheet was a dead end with no way back.
    @State private var showAdd = false
    @State private var newOrgName = ""
    @State private var newURL = ""
    @State private var addMessage: String?
    // #1209: the Downbeat client list, loaded once when the sheet opens, to show whether a source matches a
    // known client (and so gets the returning-client year-ahead read). Read-only; only the manual tag on
    // the source is written.
    @State private var clients: [DownbeatClient] = []
    // #1356: the export's health, kept alongside the clients it loaded. An empty client list from a
    // MISSING or unreadable export would make the coverage diagnostic below render nothing, which reads
    // exactly like "every client is covered". Holding the health lets that case fail loud instead.
    @State private var clientsHealth: DownbeatBridge.Health = .ok
    // #1356: clients Dan has marked "not one I scout", so the coverage gap list converges to real gaps.
    @Query private var dismissedCoverage: [DismissedCoverageClient]
    @State private var showIgnoredClients = false
    // The coverage gap list, CACHED. Computing it (an O(clients x sources) fuzzy match, ClientCoverage) is
    // expensive, and the body re-evaluates on every keystroke and scroll tick, so computing it inline made
    // typing lag, froze a long scroll, and let a "Not one I scout" tap queue into a multi-dismiss cascade.
    // It is recomputed by the .onChange below ONLY when ClientCoverage.signature changes (a source name /
    // tag, the client list, or the dismissed set), never on an unrelated redraw.
    @State private var coverageResult = ClientCoverage.Result.empty

    // #1429: every source's lifetime tally, computed in ONE pass over prospects and CACHED, the same
    // signature-then-recompute pattern #1356/#1374 used for the coverage list on this very sheet. The old
    // code ran SourceYield.tally (an O(all prospects) scan) once PER source row inside row(_:), and the
    // scroll-position binding re-evaluated the whole list body on every scroll tick, so one top-to-bottom
    // scroll multiplied (row count x every prospect) across many redraws on the main thread and froze the
    // app. Each row now reads its tally from this map in O(1); the map recomputes only when a prospect a
    // tally actually counts changes (SourceYield.signature).
    @State private var tallies: [String: SourceYield.Tally] = [:]
    // #1429: the returning-client verdict per source, CACHED for the same reason. The old code called
    // ClientHorizon.isClient inline once per row on every redraw, each a token-set fuzzy match against the
    // whole Downbeat client list. It recomputes alongside the coverage result (same inputs: a source's
    // name, its tag, and the client list), so a row reads its flag in O(1).
    @State private var clientFlags: [String: Bool] = [:]

    // #1175: which single-venue-feed source's location Dan is editing (its sourceId), and the draft text.
    @State private var editingLocationFor: String?
    @State private var locationDraft = ""

    // #1529: the same pair for the VENUE NAME of a source whose shows come from a ticketing feed that
    // names no room.
    @State private var editingVenueNameFor: String?
    @State private var venueNameDraft = ""

    // #1432: what Dan has typed into the search field. Only the string lives here; every decision it
    // drives (is this a search, does this name match, what the sheet says when nothing does) belongs to
    // SourceSearch, so none of it sits in a view the suite cannot run (#863).
    @State private var searchQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(OVColor.line)

            if showAdd { addForm; Divider().overlay(OVColor.line) }

            if sources.isEmpty {
                empty
            } else {
                // #1432: pinned above the scroll rather than inside it, so it cannot scroll away from Dan
                // half-way down the list he is trying to search.
                searchField
                Divider().overlay(OVColor.line)

                // #1432: matching is SourceSearch's decision, not this view's. An empty query returns every
                // source unchanged, so an unsearched sheet renders exactly what it always did.
                let visible = SourceSearch.filter(sources, query: searchQuery)

                if visible.isEmpty {
                    // Only reachable while searching, since an empty watchlist took the branch above. It has
                    // to SAY so: a blank sheet where the sources were reads as the sources having gone.
                    noMatches
                } else {
                    // #1440: a plain scroll view, deliberately. Holding Dan's place across a scout rebuild (#974)
                    // was done first by a `.scrollPosition` PIN and then by per-section geometry tracking, and
                    // BOTH drove a SwiftUI layout feedback loop that froze the sheet on a fast flick right after it
                    // opened (proven by a main-thread sample of the live hang: the loop ran through the per-section
                    // GeometryReader preference). A dumb scroll has no such loop, so it neither jumps nor freezes.
                    // The cost is #974: if a scout refreshes the list WHILE the sheet is open it may snap to the
                    // top, a minor annoyance worth trading for a sheet that never hangs. Revisit place-holding only
                    // with an approach that cannot re-enter layout.
                    ScrollView {
                        // #1440: a plain VStack, NOT a LazyVStack. A lazy list does not build off-screen rows, so
                        // it only ESTIMATES the height of the big "watching" section (~35 rows as one child); a
                        // fast flick into it realizes the real, much larger height, the content size snaps, and the
                        // scroll lurches to the bottom (the "jumps to the bottom after about halfway" bug). For a
                        // watchlist of a few dozen rows in a 460pt sheet, building it all up front is cheap and
                        // gives the scroll a stable, correct height from the first frame, so there is nothing to
                        // lurch to. (The separate freeze was a scroll-position-tracking layout loop, removed above.)
                        VStack(alignment: .leading, spacing: OVSpacing.lg) {
                            // #1356: the coverage gap list sits above the sources, because it is where Dan acts on
                            // a gap (add a source, or tag one below). It renders nothing when every client is
                            // covered, the common case once the non-targets are dismissed once.
                            //
                            // #1432: hidden while searching. It is a diagnostic about the WHOLE watchlist, not a
                            // search result, so leaving it on top of a filtered list would put an answer to a
                            // question Dan did not ask above the one he did. Its cached value is untouched by the
                            // search (the filter never reaches the recompute's inputs below), so clearing the
                            // field brings it straight back without recomputing anything.
                            if !SourceSearch.isSearching(searchQuery) {
                                coverageSection
                            }
                            // Sectioning, ordering and the omit-empty rule all come from the tested domain
                            // function, so this view has no judgement of its own to get wrong. #1432: it is handed
                            // the FILTERED list, and it already drops sections that end up empty, so a search
                            // keeps every heading it still has rows for. That is the point of keeping the
                            // headings (Dan's call, 2026-07-23): a source that asked him to stop stays labelled
                            // as one in the results, rather than sitting namelessly beside one he watches.
                            // #1541: the sources the toolbar badge is counting come FIRST, ahead of every
                            // graded section. The badge used to send Dan into an alphabetical list of 66
                            // with no route to the row it meant: the state it fires on grades as
                            // `.watching`, so no existing heading grouped it, and it sat wherever its
                            // initial put it. The split lifts those rows OUT of `visible`, so nothing is
                            // listed twice, and it uses the same predicate the badge counts, so the two
                            // can never disagree. Empty means absent, exactly like every other section.
                            let attention = SourceAttention.split(visible)
                            if !attention.needsALook.isEmpty {
                                attentionSection(attention.needsALook)
                            }
                            ForEach(SourceGrade.sections(attention.rest), id: \.grade) { section($0.grade, $0.sources) }
                        }
                        .padding(OVSpacing.lg)
                    }
                    // Sizes to its content rather than to a fixed height, so today's one-source watchlist does not
                    // open as a mostly empty box, and a long one still scrolls instead of running off the screen.
                    .frame(maxHeight: 460)
                }
            }
        }
        .frame(width: 560)
        .background(OVColor.canvas)
        // #845: its own banner. A sheet is a separate window on macOS, so the one on the main view cannot
        // cover it, and the Undo this sheet offers would have been drawn behind it (#285).
        .actionFeedbackBanner()
        // #1209: the Downbeat client list, read once when the sheet opens, so each row can show whether it
        // matches a known client. Read-only; nothing here writes it.
        .task {
            let loaded = DownbeatBridge.loadWithHealth(now: Date())
            // #1429: sort the roster ONCE here, so the "Always" override submenu can iterate it in order
            // without re-sorting every time a row's menu is built. Order is irrelevant to every other reader
            // of `clients` (the coverage match and the client-flag match are order-independent).
            clients = DownbeatClient.sortedByName(loaded.clients)
            clientsHealth = loaded.health
        }
        // #1429: recompute the cached tallies ONLY when a prospect a tally counts actually changes. The
        // signature is O(prospects) to evaluate each redraw (cheap next to the old O(rows x prospects) per
        // redraw), and the single-pass recompute behind it runs only when it differs, so a scroll no longer
        // drags the whole store through the main thread.
        .onChange(of: SourceYield.signature(prospects), initial: true) {
            tallies = SourceYield.tallies(in: prospects)
        }
        // Recompute the cached coverage result AND the per-source returning-client flags ONLY when their
        // real inputs change. The signature is cheap to evaluate every redraw; the O(clients x sources)
        // matches behind it run only when the signature differs, so a keystroke or scroll no longer drags
        // either through the main thread. The flags depend on the same inputs the signature captures (each
        // source's name and tag, and the client list), so they ride the same gate.
        .onChange(of: ClientCoverage.signature(sources: sources, clients: clients,
                                               dismissedIds: Set(dismissedCoverage.map(\.clientId))),
                  initial: true) {
            coverageResult = ClientCoverage.result(sources: sources, clients: clients,
                                                   dismissedIds: Set(dismissedCoverage.map(\.clientId)))
            clientFlags = ClientHorizon.clientFlags(sources: sources, clients: clients)
        }
    }

    // #1356: Downbeat clients no watched source arms as returning, so their next season would not surface
    // a year ahead. All the deciding (armed / near-miss / dismissed) lives in ClientCoverage, a tested pure
    // type; this view only renders what it returns. Fails loud when the export is unavailable rather than
    // showing an empty list that reads as "all covered".
    @ViewBuilder
    private var coverageSection: some View {
        if clientsHealth != .ok {
            coverageBox {
                Text(CoverageCopy.coverageUnavailable)
                    .font(.system(size: 11)).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            let gaps = coverageResult.gaps
            let ignoredClients = coverageResult.ignored
            if !gaps.isEmpty || !ignoredClients.isEmpty {
                coverageBox {
                    if !gaps.isEmpty {
                        Text(CoverageCopy.sectionExplanation)
                            .font(.system(size: 11)).foregroundStyle(OVColor.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 0) {
                            ForEach(gaps, id: \.client.id) { gap in
                                coverageRow(gap)
                                if gap.client.id != gaps.last?.client.id { Divider().overlay(OVColor.line) }
                            }
                        }
                        .background(OVColor.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(OVColor.line))
                    }
                    if !ignoredClients.isEmpty {
                        ignoredClientsDisclosure(ignoredClients)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func coverageBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            HStack(spacing: OVSpacing.xxs) {
                Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 11))
                Text(CoverageCopy.sectionTitle).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(OVColor.ink)
            content()
        }
    }

    private func coverageRow(_ gap: UnarmedClient) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OVSpacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text(gap.client.displayName).font(.system(size: 12)).foregroundStyle(OVColor.ink)
                if let near = gap.nearMissSourceName {
                    Text(CoverageCopy.nearMiss(sourceName: near))
                        .font(.system(size: 11)).foregroundStyle(OVColor.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button(CoverageCopy.dismissLabel) { dismissCoverageClient(gap.client) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OVColor.inkSoft)
        }
        .padding(.vertical, OVSpacing.xs)
        .padding(.horizontal, OVSpacing.sm)
    }

    @ViewBuilder
    private func ignoredClientsDisclosure(_ ignored: [DownbeatClient]) -> some View {
        DisclosureGroup(isExpanded: $showIgnoredClients) {
            VStack(spacing: 0) {
                ForEach(ignored, id: \.id) { client in
                    HStack {
                        Text(client.displayName).font(.system(size: 11)).foregroundStyle(OVColor.inkSoft)
                        Spacer()
                        Button(CoverageCopy.restoreLabel) { restoreCoverageClient(client.id) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OVColor.forest)
                    }
                    .padding(.vertical, OVSpacing.xxs)
                }
            }
        } label: {
            Text(CoverageCopy.ignoredDisclosure(count: ignored.count))
                .font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
        }
    }

    private func dismissCoverageClient(_ client: DownbeatClient) {
        CoverageDismissEditing.dismiss(clientId: client.id, into: context)
        feedback.acknowledge(CoverageCopy.dismissedAck(name: client.displayName),
                             action: .init(label: "Undo") { restoreCoverageClient(client.id) })
    }

    private func restoreCoverageClient(_ clientId: String) {
        CoverageDismissEditing.restore(clientId: clientId, in: context)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sources").font(.system(size: 15, weight: .semibold)).foregroundStyle(OVColor.ink)
                Text("The calendars Overture re-checks on every scout.")
                    .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
            }
            Spacer()
            Button(WatchlistEditing.addButtonTitle(isOpen: showAdd)) { showAdd.toggle(); addMessage = nil }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(OVColor.forest)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(OVSpacing.lg)
    }

    // #1432: finding one source on a watchlist that passed 38 in #359's backfill and only grows. The
    // control is the SHARED one (OVSearchField), so this field and the toolbar's show search look and
    // behave alike rather than being two search bars that happen to resemble each other.
    private var searchField: some View {
        OVSearchField(query: $searchQuery,
                      placeholder: SourceSearch.fieldPlaceholder,
                      clearLabel: SourceSearch.clearButtonLabel)
            .padding(.horizontal, OVSpacing.lg)
            .padding(.vertical, OVSpacing.xs)
    }

    // #1432: a search that found nothing says so. Silence here would read as the watchlist having emptied.
    private var noMatches: some View {
        Text(SourceSearch.noMatchesLine)
            .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(OVSpacing.lg)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            TextField("Organization", text: $newOrgName)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
            TextField("Their events or season page", text: $newURL)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
            Text("Their calendar, not one show: a single show's page never changes again, so watching it would watch nothing.")
                .font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
                .fixedSize(horizontal: false, vertical: true)

            if let addMessage {
                Text(addMessage).font(.system(size: 11)).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Watch it") { addSource() }
            }
        }
        .padding(OVSpacing.md)
        .background(OVColor.surfaceSunk)
    }

    // #1417: both of these live in WatchlistMutations now, with every other action that says something
    // to Dan, so the "only claim success once it saved" rule is stated once and is testable (#863).
    private func stopWatching(_ source: WatchedSource) {
        WatchlistMutations.stopWatching(source, context: context, feedback: feedback)
    }

    private func resumeWatching(_ source: WatchedSource) {
        WatchlistMutations.resumeWatching(source, context: context, feedback: feedback)
    }

    // #1417: the add itself and its refusals live in WatchlistMutations. What stays here is this form's
    // own state, which is why .notSaved leaves it open holding what Dan typed: closing it is this
    // screen's way of saying the source was added, and it must not say that over a write that failed.
    private func addSource() {
        switch WatchlistMutations.addSource(orgName: newOrgName, listingsURL: newURL,
                                            context: context, feedback: feedback) {
        case .added:
            newOrgName = ""; newURL = ""; showAdd = false; addMessage = nil
        case .message(let text):
            addMessage = text
        case .notSaved:
            break
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            Text("No sources yet.").font(.system(size: 13, weight: .medium)).foregroundStyle(OVColor.ink)
            Text("Carnegie Hall is added the first time Overture opens your store.")
                .font(.system(size: 12)).foregroundStyle(OVColor.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(OVSpacing.lg)
    }

    // #1541: the same section shape as a graded one, so a row reads identically wherever it sits and Dan
    // is not learning a second layout. Rust, like Failing: these are the rows the toolbar sent him for,
    // and every one of them has either broken outright or lost the ability to tell him a show was
    // cancelled. Its wording lives on SourceAttention, never here (#863/#885).
    private func attentionSection(_ rows: [WatchedSource]) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            HStack(spacing: OVSpacing.xxs) {
                Image(systemName: SourceAttention.sectionSystemImage).font(.system(size: 11))
                Text(SourceAttention.sectionLabel).font(.system(size: 12, weight: .semibold))
                Text("(\(rows.count))").font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
            }
            .foregroundStyle(OVColor.rust)

            VStack(spacing: 0) {
                ForEach(rows) { source in
                    row(source)
                    if source.persistentModelID != rows.last?.persistentModelID {
                        Divider().overlay(OVColor.line)
                    }
                }
            }
            .background(OVColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(OVColor.line))
        }
    }

    private func section(_ grade: SourceGrade, _ rows: [WatchedSource]) -> some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            HStack(spacing: OVSpacing.xxs) {
                Image(systemName: grade.systemImage).font(.system(size: 11))
                Text(grade.label).font(.system(size: 12, weight: .semibold))
                Text("(\(rows.count))").font(.system(size: 12)).foregroundStyle(OVColor.inkFaint)
            }
            .foregroundStyle(grade.isBroken ? OVColor.rust : OVColor.ink)

            // #841: only where it says something the heading and the sheet's subtitle do not.
            if let explanation = grade.explanation {
                Text(explanation).font(.system(size: 11)).foregroundStyle(OVColor.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(rows) { source in
                    row(source)
                    if source.persistentModelID != rows.last?.persistentModelID {
                        Divider().overlay(OVColor.line)
                    }
                }
            }
            .background(OVColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(OVColor.line))
        }
    }

    // #1175: true only for a single-venue feed whose own data carries no city (VenueTix). A thin predicate
    // delegating to the adapter's already-tested host check, so the view keeps no routing rule of its own.
    private func isSingleVenueFeed(_ source: WatchedSource) -> Bool {
        guard let s = source.listingsURL, let url = URL(string: s) else { return false }
        return VenueTixCalendar.handles(url)
    }

    // #1175: where Dan supplies a single-venue feed's address. Three states: editing (a field + Save), a
    // saved address (shown, with Edit), or none yet (a prompt, with Add).
    //
    // #1185: when none is set, the prompt varies by whether the source has actually surfaced shows. Before
    // any have, it is the neutral setup prompt (there is nothing unplaced yet, only a thing worth doing);
    // once shows exist, they are actively resolving as location-unknown, so it states that consequence and
    // nudges him to fix it. One line that varies, decided in VenueLocationCopy, so the row never says the
    // missing address twice (#843).
    @ViewBuilder
    private func venueLocationControl(_ source: WatchedSource, hasSurfacedShows: Bool) -> some View {
        if editingLocationFor == source.sourceId {
            VStack(alignment: .leading, spacing: OVSpacing.xxs) {
                TextField(VenueLocationCopy.placeholder, text: $locationDraft)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .onSubmit { saveLocation(source) }
                HStack(spacing: OVSpacing.xs) {
                    Spacer()
                    OVCapsuleButton(label: VenueLocationCopy.cancel, tint: OVColor.inkSoft) {
                        editingLocationFor = nil
                    }
                    OVCapsuleButton(label: VenueLocationCopy.save, tint: OVColor.forest) {
                        saveLocation(source)
                    }
                }
            }
        } else if let location = source.venueLocation {
            HStack(alignment: .firstTextBaseline, spacing: OVSpacing.xs) {
                Text(location).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                OVCapsuleButton(label: VenueLocationCopy.edit, tint: OVColor.inkSoft) {
                    beginEditingLocation(source)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: OVSpacing.xs) {
                Text(VenueLocationCopy.promptWhenUnset(hasSurfacedShows: hasSurfacedShows))
                    .font(.system(size: 11)).foregroundStyle(OVColor.gold)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                OVCapsuleButton(label: VenueLocationCopy.add, tint: OVColor.forest) {
                    beginEditingLocation(source)
                }
            }
        }
    }

    private func beginEditingLocation(_ source: WatchedSource) {
        locationDraft = source.venueLocation ?? ""
        editingLocationFor = source.sourceId
    }

    private func saveLocation(_ source: WatchedSource) {
        WatchlistMutations.saveVenueLocation(source, to: locationDraft, context: context, feedback: feedback)
        editingLocationFor = nil
    }

    // #1529: where Dan names the ROOM for a source whose shows come off a ticketing feed that publishes no
    // venue anywhere. Until he does, every one of those shows arrives with no venue and stays out of the
    // queue, which is why the unnamed state is the loud one. Same three states as the address control
    // above (editing, named, unnamed); which rows show it at all is TicketingFeedRead.needsVenueName's
    // call, so the view holds no rule of its own.
    @ViewBuilder
    private func venueNameControl(_ source: WatchedSource) -> some View {
        if editingVenueNameFor == source.sourceId {
            VStack(alignment: .leading, spacing: OVSpacing.xxs) {
                TextField(VenueNameCopy.placeholder, text: $venueNameDraft)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .onSubmit { saveVenueName(source) }
                HStack(spacing: OVSpacing.xs) {
                    Spacer()
                    OVCapsuleButton(label: VenueNameCopy.cancel, tint: OVColor.inkSoft) {
                        editingVenueNameFor = nil
                    }
                    OVCapsuleButton(label: VenueNameCopy.save, tint: OVColor.forest) {
                        saveVenueName(source)
                    }
                }
            }
        } else if let venue = source.venueName {
            HStack(alignment: .firstTextBaseline, spacing: OVSpacing.xs) {
                Text(VenueNameCopy.named(venue)).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                OVCapsuleButton(label: VenueNameCopy.edit, tint: OVColor.inkSoft) {
                    beginEditingVenueName(source)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: OVSpacing.xs) {
                Text(VenueNameCopy.promptWhenUnset)
                    .font(.system(size: 11)).foregroundStyle(OVColor.gold)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                OVCapsuleButton(label: VenueNameCopy.add, tint: OVColor.forest) {
                    beginEditingVenueName(source)
                }
            }
        }
    }

    private func beginEditingVenueName(_ source: WatchedSource) {
        // Prefilled with the org name: on the row this exists for it is usually the right answer, and Dan
        // is confirming rather than typing. It is still HIS answer, which is the whole point: the app may
        // not assume it (the Bargemusic rule), and an ensemble that sells through somebody else's hall is
        // exactly the row where he will type something different.
        venueNameDraft = source.venueName ?? source.orgName
        editingVenueNameFor = source.sourceId
    }

    private func saveVenueName(_ source: WatchedSource) {
        WatchlistMutations.saveVenueName(source, to: venueNameDraft, context: context, feedback: feedback)
        editingVenueNameFor = nil
    }

    // #1209: the returning-client state line plus a menu to override the automatic Downbeat match. The
    // effective state and all wording live in ClientHorizon / ClientTagCopy, so this view holds no rule.
    // #1286: most of the ~37 non-Carnegie rows are neither a client nor tagged, so the override menu is
    // tucked behind a compact overflow icon (labelled by the same "Returning client" text for the
    // accessibility name and a hover tooltip) instead of a full-width menu button on every row. The state
    // line already appears ONLY where there is something to say (ClientTagCopy.stateLabel returns nil for an
    // untagged non-client, tested), so a plain venue row shows just the icon, and a client row shows its
    // state line beside it.
    @ViewBuilder
    private func clientTagControl(_ source: WatchedSource) -> some View {
        // #1429: read the cached flag instead of running ClientHorizon.isClient (a whole-roster fuzzy match)
        // inline on every redraw. Absent from the map means not-a-client, the same default the map holds
        // until the client list has loaded.
        let isClient = clientFlags[source.sourceId] ?? false
        HStack(spacing: OVSpacing.xs) {
            if let label = ClientTagCopy.stateLabel(isClient: isClient, override: source.clientTagOverride,
                                                    namedClient: namedClientName(source)) {
                Text(label).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Menu {
                Button(ClientTagCopy.optionAutomatic) { setClientTag(source, nil, clientId: nil) }
                // #1358: "Always" opens a submenu to optionally name WHICH Downbeat client performs at this
                // source (the shared-venue case, where the org name is the venue, not the client), so the
                // coverage diagnostic can count that client as covered instead of leaving it a hidden gap.
                Menu(ClientTagCopy.optionAlways) {
                    clientTagAlwaysButton(source, label: ClientTagCopy.optionAlwaysNoClient, clientId: nil)
                    // #1429: `clients` is already sorted for display (sorted once when loaded above), so the
                    // submenu iterates it directly rather than re-sorting on every menu build.
                    if !clients.isEmpty {
                        Divider()
                        ForEach(clients, id: \.id) { c in
                            clientTagAlwaysButton(source, label: c.displayName, clientId: c.id)
                        }
                    }
                }
                Button(ClientTagCopy.optionNever) { setClientTag(source, false, clientId: nil) }
            } label: {
                Label(ClientTagCopy.menuTitle, systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    .font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(ClientTagCopy.menuTitle)
        }
    }

    // One row in the "Always" submenu: tags the source "always" naming `clientId` (nil = bare always), with a
    // checkmark on the source's current selection so Dan sees what he picked without having to guess.
    @ViewBuilder
    private func clientTagAlwaysButton(_ source: WatchedSource, label: String, clientId: String?) -> some View {
        let selected = source.clientTagOverride == true && source.clientTagClientId == clientId
        Button {
            setClientTag(source, true, clientId: clientId)
        } label: {
            if selected {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    // The display name of the Downbeat client a source's "always" tag names, or nil for a bare tag. Only a
    // lookup, no rule: the arming/coverage rules stay in ClientCoverage (#863).
    private func namedClientName(_ source: WatchedSource) -> String? {
        guard let id = source.clientTagClientId else { return nil }
        return clients.first { $0.id == id }?.displayName
    }

    private func setClientTag(_ source: WatchedSource, _ value: Bool?, clientId: String?) {
        source.clientTagOverride = value
        source.clientTagClientId = clientId
        try? context.save()
    }

    private func row(_ source: WatchedSource) -> some View {
        // #794/#978/#1185: the lifetime tally, reused for the yield line below and for whether a single-venue
        // feed has actually surfaced shows yet (which decides its address nudge). The counting lives in
        // SourceYield, a tested pure function; #1429 moved it out of the per-row path into the cached
        // `tallies` map (computed once for the whole store), so this reads its own in O(1). A source absent
        // from the map surfaced nothing and reads as the zero tally, which is what the scan returned too.
        let tally = tallies[source.sourceId] ?? .zero
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: OVSpacing.xs) {
                Text(source.orgName).font(.system(size: 13, weight: .medium)).foregroundStyle(OVColor.ink)
                Spacer()
                Text(lastChecked(source)).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
            }

            if let url = source.listingsURL {
                Text(url).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint).lineLimit(1)
            }

            // #1175: a single-venue feed (VenueTix) carries no city in its own data, so its shows resolve
            // as location-unknown rather than the local venue they are. This is where Dan supplies the
            // address once; it is then stamped into the synthesized listing so the geography gate places
            // the shows. Shown only on those rows, since every other source's shows carry their own place.
            // #1529: and a source whose own page turned out to be a front for a ticketing feed needs BOTH
            // answers: which room (nothing on that feed says, and the app may not assume) and where it is.
            if TicketingFeedRead.readsATicketingFeed(source) {
                venueNameControl(source)
            }
            if isSingleVenueFeed(source) || TicketingFeedRead.readsATicketingFeed(source) {
                venueLocationControl(source, hasSurfacedShows: tally.found > 0)
            }

            // #1209: whether this source is treated as a returning client, so its calendar is read a year
            // ahead and its far-future shows are not defaulted out of a Prep run. Automatic by a Downbeat
            // name match, with a menu to force it on (a client at a shared venue the match misses) or off.
            // Not shown on Carnegie's native feed, which reads its own fixed window.
            if source.kind != .algolia {
                clientTagControl(source)
            }

            // #803: CHECKED and READ are different things, and the sheet could not tell them apart. The
            // free daily run fetches and hashes every calendar and reads none of them, so a source can
            // report "checked an hour ago" for weeks while nobody has looked at what is on it. That is
            // the design, but invisible it becomes a leak: shows sitting unread on a calendar that
            // reports as perfectly healthy.
            //
            // #840: said only when it adds something. Read in the same run that checked it (a native
            // feed, or any source a scout just read) is one event, and Dan's Carnegie row described it
            // twice: "Checked 8 hours ago", then "Read 8 hours ago". Repetition teaches him to skim, and
            // the state this exists to surface is the one line here he must never skim past.
            // #843: the failure is passed in because a `notRead` run leaves this line and the failure line
            // below saying the same thing; the read-state decides, in one tested place, to step aside for
            // it rather than repeat it.
            let readState = SourceReadState.of(source)
            if readState.isWorthShowing(lastCheckedAt: source.lastCheckedAt, failure: source.lastFailure) {
                Text(readState.label)
                    .font(.system(size: 11))
                    .foregroundStyle(readState.needsAScout ? OVColor.gold : OVColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // #794: what this source has actually earned over its lifetime, kept-first: "3 of 12 kept",
            // with sent/booked appended when present. A source that extracts perfectly and produces
            // nothing Dan keeps is dead weight ("0 of 12 kept"), and that has to be visible, or a source
            // sits generating junk forever. Nothing here removes it: only a refusal (or Dan's own removal)
            // takes a source off the list.
            //
            // #978: the read count is handed in so the same line can cover the case #794 alone cannot: a
            // source read many times that has NEVER once surfaced a pitchable show (found is still zero).
            // A brand-new or off-season source read only once or twice stays silent; past the threshold it
            // reads that it has never turned up a show and may be pointed at the wrong page (#1178), which
            // pairs with the Fix control now on this row (#1177). The decision lives in SourceYield, so this
            // view still has no counting of its own.
            if let yield = SourceYield.line(tally, reads: source.successfulCheckCount) {
                Text(yield).font(.system(size: 11)).foregroundStyle(OVColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A named failure, never a bare "broken". A source Dan cannot act on is a source he will
            // learn to ignore.
            if let failure = source.lastFailure {
                Text(failure.message).font(.system(size: 11)).foregroundStyle(OVColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // #1027/#1177: the SAME fix/confirm controls the end-of-scout popup offers, on the durable
            // sheet. Moved OUT of the failure block (#1177) so an editable source that reads fine but is
            // empty can be re-pointed too: The Cell read as perfectly healthy while pointed at the wrong,
            // empty page (#1127), and until now "Fix the address" only ever appeared on a source that had
            // failed. The optional failure lets one component serve both: Fix is always offered here (a
            // wrong address is plausible on any editable source), Confirm only when there is an empty-page
            // failure to confirm. Carnegie's native feed has no URL to correct (algolia is excluded), and a
            // source Dan stopped is not shown these at all.
            // #1450: the kind gate moved into the component, which now draws nothing at all for a source
            // it has nothing to offer. A source Dan stopped is still shown none of these.
            if source.isActive {
                SourceFixConfirmActions(source: source, failure: source.lastFailure)
            }

            // #891: shows on this calendar whose own page Overture could not open. A source quietly
            // returning half its shows unreadable is BROKEN, not quiet, and those two looked identical
            // here. Past the tolerance it has also stopped being able to mark anything gone (#887), and
            // the sentence says so, because that consequence is the part Dan can act on.
            //
            // Gold, not rust: this is a source degrading, not a source that failed. The wording is decided
            // in SourceReadability, never here (#863/#885).
            if let readability = source.readabilityNote {
                // #1428/#1472/#1498: a line that needs nothing from Dan reads as plain text, not the gold
                // signal colour. It is disclosed without being dressed as an alarm; only a source that has
                // actually forfeited its cancelling keeps the gold. #1498 moved the last case over: a stray
                // unread page inside the tolerance costs the source nothing, and the row that prompted it was
                // a festival whose page had not announced a venue, which is not work Dan could do.
                Text(readability).font(.system(size: 11))
                    .foregroundStyle(source.readabilityNoteIsInformationalOnly ? OVColor.ink : OVColor.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // #1544: this source's page came back unencrypted, because its https handshake is broken and
            // Overture fell back to the cleartext address Dan stored. Worth saying: those bytes could have
            // been altered in flight and they feed the reconcile that cancels shows.
            //
            // PLAIN TEXT, not gold, by the same rule as the readability line directly above (#1428/#1472/
            // #1498) and by Dan's own call on review: gold is for a source that has forfeited its ability
            // to say a show is gone, which is work he can act on. Another site's broken certificate is not
            // work he can act on at all. Disclosed without being dressed as an alarm, and it clears itself
            // the day they fix it. It shipped gold and was corrected. Wording lives on the model (#863).
            if let insecure = source.insecureFetchNote {
                Text(insecure).font(.system(size: 11))
                    .foregroundStyle(OVColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // #1029: the #986 venue-precision line is gone from Dan's view. It told him how many shows
            // "said where they are", and he did not understand why it mattered ("I do not understand what
            // that matters"). The underlying placement data still records on every run (WatchedSource's
            // lastPlacedCount / hadPlacedBeforeLastRun); only its Dan-facing sentence was removed. The
            // alternative, rewriting it to state its consequence, was set aside per that signal.

            // #875: the RUN'S OWN account of this source, which until now was decoded and thrown away
            // while Dan was shown only the generic sentence for the verdict. The generic line says WHAT
            // happened ("The run ended before reading this page"); this one says WHY, and why is the only
            // part he can act on.
            //
            // The sentence goes in the row and the raw log tail goes on hover (Dan's call, 2026-07-13):
            // a failing source would otherwise unroll six lines of shell output into the sheet and make
            // every row around it unreadable. Both halves are decided in SourceNote, never here (#863).
            if let note = source.runNote {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(source.runNoteDetail ?? note)
            }

            // A permanently dead source needs a way out that is DAN'S choice, or a failing source would
            // be reported at him every run forever with nothing he could do about it. Recorded as his
            // decision, never as a refusal.
            //
            // #1450: EVERY active source, Carnegie's native feed included. It used to be excluded here
            // because it has no page to correct, which is true of Fix and has nothing to do with leaving
            // the watchlist: the exclusion took the only exit off the one source that could never get it
            // back any other way. "Read this one" stays excluded, because reading Carnegie on demand is a
            // separate question this change does not answer.
            //
            // #842: it has to LOOK like something he can do. Styled as an 11pt plain line under three
            // other 11pt lines, it read as a fourth statement of fact, and it is the only way a source
            // ever leaves the watchlist: #802 rests on a failing source never auto-deactivating, so Dan
            // removing it himself is the deliberate escape hatch. An escape hatch he cannot see is not
            // one. Same bordered-capsule idiom the queue's own secondary action (Dismiss) uses, so
            // "you can do this" looks the same everywhere in the app, and sitting on its own trailing
            // line rather than in the metadata stack. #1460: "same idiom" is now enforced, not matched by
            // eye: both wear the shared ovCapsuleAction() modifier (the Dismiss menu had drifted chunkier).
            //
            // #1451: that idiom is OVCapsuleButton's, not this row's. These three actions used to spell
            // it out here in six lines each, which meant they matched the sheet's own venue-location
            // controls (already on the component, #1175) only because someone had matched them by eye.
            if source.isActive {
                HStack {
                    Spacer()
                    // #970: reads THIS source, now. The scout otherwise reads oldest-first, and every
                    // source shares a lastCheckedAt (the daily run checks them in one pass), so "read
                    // that one" is not otherwise expressible: a capped run picks arbitrarily among a
                    // tie. Costs one run instead of twenty.
                    if source.kind.hasEditablePage {
                        OVCapsuleButton(label: WatchlistEditing.readOneTitle, tint: OVColor.inkSoft) {
                            readOne(source)
                            dismiss()
                        }
                        .help(WatchlistEditing.readOneHelp)
                    }

                    OVCapsuleButton(label: SourceFixConfirmCopy.stopWatchingTitle, tint: OVColor.inkSoft) {
                        stopWatching(source)
                    }
                }
                .padding(.top, 2)
            }

            // #845: the way back, on the row itself.
            //
            // Stopping was always reversible (the row, its feed history and the source id stamped on every
            // prospect it ever surfaced all survive), but the only route back was to retype the org name
            // and the URL into the add form, and nothing on this sheet said even that. So a reversible
            // action read as a permanent one, and #802 rests on Dan being willing to take it: a failing
            // source is never auto-deactivated, precisely so that removing it stays his deliberate choice.
            //
            // ONLY on a source Dan stopped himself. An org that asked him to stop is a different section
            // and a different state, and it never gets this button. WatchlistEditing.resumeWatching
            // enforces that too, because a guarantee that lives in a view lasts until the next view.
            if SourceGrade(source) == .removed {
                HStack {
                    Spacer()
                    OVCapsuleButton(label: "Watch again", tint: OVColor.forest) {
                        resumeWatching(source)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, OVSpacing.sm)
        .padding(.vertical, OVSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // "Never" is a real answer and is said out loud, rather than being left as a blank cell that reads
    // like a rendering bug.
    private func lastChecked(_ source: WatchedSource) -> String {
        SourceReadState.lastCheckedLine(at: source.lastCheckedAt, now: Date())   // #885
    }
}

// #1175: the venue-location control's own words, kept out of the view body so the copy inventory reads
// them and a test can pin them (#863/#885).
enum VenueLocationCopy {
    static let placeholder = "Street, city, state"

    // #1175/#1185: the prompt shown while a single-venue feed has no address, worded by whether it has
    // actually surfaced shows yet. Two complete literals (not a composed one) so each lands in the copy
    // inventory as a whole sentence for the cold read. Before any shows exist it is a neutral setup prompt;
    // once shows exist they are actively resolving as location-unknown, so it states that consequence and
    // nudges Dan to supply the address (the Add control sits right beside it).
    static func promptWhenUnset(hasSurfacedShows: Bool) -> String {
        hasSurfacedShows
            ? "No address yet, so its shows are not placed in your area."
            : "Add this venue's address so its shows count as in your area."
    }

    static let add = "Add address"
    static let edit = "Edit"
    static let save = "Save"
    static let cancel = "Cancel"

    static func savedAck(org: String) -> String {
        "Saved \(org)'s address. Its shows are placed on the next read."
    }
}

// #1529: naming the ROOM for a source whose shows come off a ticketing feed. Separate from the address
// above and not a restatement of it: one says which room, the other says where that room is, and this
// source publishes neither. The unnamed line states the fact and what it costs; the control beside it is
// what says what to do, so the two never say the same thing twice (#843).
enum VenueNameCopy {
    static let placeholder = "The room its shows play in"

    static let promptWhenUnset = "Its shows are sold through a ticketing feed that names no room, so they stay out of the queue."

    static let add = "Name the venue"
    static let edit = "Edit"
    static let save = "Save"
    static let cancel = "Cancel"

    // Fronted with a label because this row carries two Dan-supplied lines (the room and its address) and
    // a bare name beside a bare address leaves him working out which is which.
    static func named(_ venue: String) -> String { "Venue: \(venue)" }

    static func savedAck(org: String) -> String {
        "Saved \(org)'s venue. Its shows are read again on the next scout."
    }
}
