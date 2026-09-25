import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #4112: how many times does the Sources sheet rebuild when ONE row is removed?
//
// WHAT WAS MEASURED, on the live app on 2026-09-21. Dan pressed "Stop watching" on FRIGID New York and
// felt a freeze. The log recorded a 2.44s stall with `surface=sourcesSheet` and `passes=8`, then 0.36s
// (2 passes), 0.56s (3) and 0.35s (3) on the same sheet, then 0.60s on the queue as it caught up. Load
// was 4.4, so the Mac was not the cause. Removing ONE row from a 74 row list cost eight rebuilds.
//
// WHAT THE STACK SAMPLE COULD NOT SAY, and why this test is a COUNT rather than a duration. In
// `KEPT-chunk-1790019023.txt` the main thread is idle 71.7% of the ten second window, Overture's own
// frames account for under 3%, and outside the idle wait no single leaf carries even 1%: the cost is
// spread thinly through AppKit and SwiftUI teardown and layout. So the redraw COUNT is the measurement
// here and the per-pass cost is not attributed. A count is also the only half that can sit in a suite:
// it is a statement about this code, where a duration is a statement about the machine (L63, and #3918
// measured what happens when that is forgotten).
//
// THE INSTRUMENT CAME FIRST (L309). Until this change nothing on this surface recorded WHY it
// rebuilt: `QueueRenderCounter` kept a reason trace for the queue and the root only, so `passes=8` was
// the whole of what anybody could know. This suite reads the reasons, so a burst can be attributed
// rather than guessed at, which is what #4112 asks for in as many words.
@MainActor
@Suite("Removing one watched source costs one pass (#4112)", .serialized)
struct RemovingOneSourceCostsOnePassTests {

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory(AppSchema.models)
    }

    // THE REAL COUNT, not a two row fixture. Dan's list held 74 rows when this was measured, and a
    // rebuild burst is exactly the thing a small fixture hides: the work per pass scales with the list,
    // so a two row sheet can rebuild eight times and nobody feels it (L606, L354).
    private static let rows = 74

    private func seed(_ ctx: ModelContext) -> [WatchedSource] {
        var made: [WatchedSource] = []
        for n in 0..<Self.rows {
            let s = WatchedSource(sourceId: "src-\(n)", orgName: "Organisation \(n)",
                                  listingsURL: "https://org\(n).example/events", kind: .html)
            ctx.insert(s)
            made.append(s)
        }
        try? ctx.save()
        return made
    }

    // The feedback object is HELD BY THE TEST and handed in, not created inside the harness.
    //
    // The first version made its own with `@State` and then called the mutation with a throwaway
    // `ActionFeedback()`, so the banner the real button raises was written to an object nothing on
    // screen observed. That is a rig measuring a path the product never takes: every mutation here goes
    // through the environment's feedback, and the undo banner it raises is one of the things that can
    // rebuild this sheet (L472).
    private struct Harness: View {
        let container: ModelContainer
        let prospects: [Prospect]
        let feedback: ActionFeedback

        var body: some View {
            SourcesView(prospects: prospects)
                .modelContainer(container)
                .environment(feedback)
        }
    }

    // #4247: the REAL type is hosted, never wrapped in `AnyView`. The first version of this suite wrapped
    // it, which is a tree the app does not have (`ExternalRebuildProbeTests` records the difference, L472),
    // so a count read through it was a count of the wrapper's behaviour as much as the sheet's.
    private func host<V: View>(_ view: V) -> (window: NSWindow, hosting: NSHostingView<V>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // AppKit's default releases the window while this scope still holds it, which crashed the shared
        // app host and truncated the whole hosted target once already (#3480).
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    // Waits until the sheet has GONE QUIET rather than for a fixed time, on
    // `BringingTheQueueUpTests.waitUntilDerivationsGoQuiet`'s precedent and for its reason: the thing
    // being established is an absence, and a fixed settle asserts about how fast the machine is, which
    // is slowest exactly when it is being judged (L290).
    //
    // The layout and display are driven on every poll because this window is never ordered front, so
    // AppKit runs no display cycle of its own for it (#3480).
    @discardableResult
    private func waitUntilQuiet(in hosting: NSView, quietPolls: Int = 25,
                                timeout: Duration = .seconds(20)) async -> Bool {
        var last = QueueRenderCounter.renderCount(for: QueueRenderCounter.sourcesSurface)
        var quiet = 0
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let now = QueueRenderCounter.renderCount(for: QueueRenderCounter.sourcesSurface)
            quiet = (now == last) ? quiet + 1 : 0
            last = now
            if quiet >= quietPolls { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    // WHAT THIS RUN IS ALLOWED TO COST. One row leaving the list is one change, so the sheet derives once.
    //
    // DERIVATIONS, not body evaluations, and the difference is the whole finding. SwiftUI re-evaluates
    // a body for reasons a view does not control, and that is cheap; re-running the whole-store
    // derivation is what costs seconds. Holding the count of EVALUATIONS to one would be asking SwiftUI
    // for a guarantee it does not give, and it would fail for reasons that are not defects (L63).
    //
    // TWO as the ceiling, and what is known about the reading under it.
    //
    // Under #4112 this harness read TWO, and the second was put down first to the memo being invalidated
    // by its own subject and then to SwiftData's re-fetch after the save. Those readings were taken with
    // the sheet wrapped in `AnyView` and with the reason trace reading the banner's revision during body
    // evaluation. In every run taken under #4247 it read ONE derivation over two evaluations: with the
    // real type hosted, with the read removed, and with `AnyView` put back by mutation, so the wrapper is
    // not what the difference turns on. The write here goes through a SEPARATE context, so the sheet's own
    // rows only learn of it when the main context merges and its query re-fetches.
    //
    // The ceiling is NOT lowered to one, because nothing measured here says why #4112 read two, and a
    // ceiling set at a count whose cause is unknown is a flake waiting for a loaded machine (L290). The
    // app shaped test below writes through the sheet's own context, as the button does, and names each
    // of the three derivations that costs.
    private static let allowedDerivationsForOneRemoval = 2

    @Test func removingOneSourceRebuildsTheSheetOnce() async throws {
        let c = try container()
        let ctx = ModelContext(c)
        let sources = seed(ctx)

        let feedback = ActionFeedback()
        let (window, hosting) = host(Harness(container: c, prospects: [], feedback: feedback))
        defer { window.close() }

        // Let the sheet appear and settle first. What is being measured is the cost of a CHANGE, not the
        // cost of appearing, and folding the two would make a cheap removal on a slow first draw read
        // the same as an expensive one (L63).
        _ = await waitUntilQuiet(in: hosting)
        let before = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface)
        let rendersBefore = QueueRenderCounter.renderCount(for: QueueRenderCounter.sourcesSurface)
        #expect(rendersBefore > 0, Comment(rawValue:
            "the sheet never rendered at all, so this fixture measures nothing and the count below "
            + "would be zero for the wrong reason (L98)"))
        #expect(before > 0, Comment(rawValue:
            "the sheet never DERIVED at all, so the memo answered a question nobody had asked and the "
            + "count below would be zero because nothing ever ran (L98)"))
        let reasonsBefore = QueueRenderCounter.reasons(for: QueueRenderCounter.sourcesSurface).count

        // ONE row removed, through the same path the button takes.
        WatchlistMutations.stopWatching(sources[0], context: ctx, feedback: feedback)

        _ = await waitUntilQuiet(in: hosting)
        let derivations = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface) - before
        let evaluations = QueueRenderCounter.renderCount(for: QueueRenderCounter.sourcesSurface) - rendersBefore
        let why = Array(QueueRenderCounter.reasons(for: QueueRenderCounter.sourcesSurface)
            .dropFirst(reasonsBefore))
        print("removal-reading bare: derivations=\(derivations) evaluations=\(evaluations) reasons=\(why)")

        // THE POSITIVE CONTROL FIRST. A test asserting a count stays AT OR BELOW one is satisfied by a
        // sheet that never reacted to the removal at all, which is the fixture where the thing could not
        // happen (L159). The removal must produce a derivation before the ceiling means anything.
        #expect(derivations >= 1, Comment(rawValue:
            "removing a row derived the sheet \(derivations) times, so the sheet did not react to the "
            + "removal at all and the ceiling below would pass over a sheet that had stopped working"))
        #expect(derivations <= Self.allowedDerivationsForOneRemoval, Comment(rawValue:
            "removing ONE of \(Self.rows) rows derived the Sources sheet \(derivations) times against "
            + "an allowance of \(Self.allowedDerivationsForOneRemoval), over \(evaluations) body "
            + "evaluation(s). Each derivation is a whole-store pass. What moved before each "
            + "evaluation: \(why.joined(separator: " | ")) (#4112)"))
    }

    // THE SHEET UNDER THE APP'S OWN INPUTS, which is the harness #4112's comment asked for.
    //
    // The harness above hosts `SourcesView` alone, handed an empty constant for the store and with no
    // Downbeat roster, so the coverage and calendar work never runs and nothing above the sheet re-fetches
    // anything. This one puts the sheet under a parent that holds the SAME queries `RootView` holds
    // (`RootView.swift`, the `@Query` block at the top of the view) and hands the whole-table read down the
    // way `RootView` does, with a roster that names some of the watched sources, so every input the live
    // sheet has is live here too.
    //
    // A parent holding the queries rather than `RootView` itself, because the sheet is presented from a
    // private `@State` flag that a hosted test cannot raise, and a window that is never ordered front
    // presents no sheet at all (#3480). What the parent reproduces is the part that matters to a count:
    // every query that re-fetches after a save, and a store read handed down anew each time.
    private struct AppShapedHarness: View {
        let container: ModelContainer
        let feedback: ActionFeedback
        let roster: ClientRoster
        var body: some View {
            Parent()
                .modelContainer(container)
                .environment(feedback)
                .environment(roster)
        }
        struct Parent: View {
            @Query(filter: PrepQueueBuilder.needsPrepPredicate) private var toPrepByStatus: [Prospect]
            @Query private var allProspects: [Prospect]
            @Query private var allInquiries: [Inquiry]
            @Query private var watchedSources: [WatchedSource]
            @Query private var excludedTownRows: [ExcludedTown]
            @Query private var allowedSeedTownRows: [AllowedSeedTown]
            var body: some View {
                // Read, so each query is live and re-fetches after a save as `RootView`'s do.
                let _ = (toPrepByStatus.count, allInquiries.count, watchedSources.count,
                         excludedTownRows.count, allowedSeedTownRows.count)
                SourcesView(prospects: allProspects)
            }
        }
    }

    // A roster the test can change after the sheet is up, without touching the store.
    @MainActor
    private final class RosterFile {
        var clients: [DownbeatClient]
        init(_ clients: [DownbeatClient]) { self.clients = clients }
    }

    private static func client(_ name: String) -> DownbeatClient {
        DownbeatClient(id: "client-\(name)", displayName: name, shortName: nil, email: "", contractEmail: "",
                       phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false, specialBehaviors: [],
                       notes: nil, hostingSite: "")
    }

    // Twelve of the watched sources are a client's, by name, so the client window holds twelve ids. A
    // window of one or two cannot show the ordering defect `aRosterReloadThatChangesNoVerdictDerivesNothing`
    // is about, because a set that small prints the same way however it was built.
    private static let clients = (0..<12).map { client("Organisation \($0 * 5)") } + [client("Unmatched Guild")]

    private func seedProspects(_ ctx: ModelContext, rows: Int) {
        let dates = LiveDateClustering.dates(forRows: rows)
        for n in 0..<rows {
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n % 90)", discipline: "music",
                             venue: "Venue \(n % 169) Hall", performanceDate: dates[n],
                             sourceListingURL: nil, priorRelationship: "none",
                             production: "presenter", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 4 + (n % 5), tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: n % 3 == 0 ? .drafted : .new)
            p.sourceIds = ["src-\(n % Self.rows)"]
            p.location = "New York, NY"
            ctx.insert(p)
        }
        try? ctx.save()
    }

    private struct AppShaped {
        let container: ModelContainer
        let sources: [WatchedSource]
        let feedback: ActionFeedback
        let roster: ClientRoster
        let file: RosterFile
        let window: NSWindow
        let hosting: NSView
    }

    // Seeds, hosts and SETTLES, and reports what appearing cost, so every test below measures a change
    // from a quiet sheet rather than folding the cost of appearing into it (L63).
    private func appShaped() async throws -> (AppShaped, appearing: Int) {
        let c = try container()
        let ctx = c.mainContext
        let sources = seed(ctx)
        seedProspects(ctx, rows: 400)
        let file = RosterFile(Self.clients)
        let roster = ClientRoster(load: { [file] _ in MainActor.assumeIsolated { (file.clients, .ok) } })
        roster.reload()
        let feedback = ActionFeedback()
        let before = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface)
        let (window, hosting) = host(AppShapedHarness(container: c, feedback: feedback, roster: roster))
        _ = await waitUntilQuiet(in: hosting)
        let appearing = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface) - before
        return (AppShaped(container: c, sources: sources, feedback: feedback, roster: roster, file: file,
                          window: window, hosting: hosting), appearing)
    }

    // OPENING THE SHEET derives the store ONCE.
    //
    // It derived TWICE, measured here on 2026-09-25, and the second was a key that moved with nothing
    // changed. The first body evaluation runs before `.onChange(initial: true)` has decided the client
    // window, so `roomContext` builds the window itself and the derivation is right. The `.onChange` then
    // stores the SAME window, and the key had it as `String(describing: clientWindow)`: `nil` on the first
    // pass, `Optional(...)` on the second, so the key moved and the whole store was derived again for an
    // identical answer. The key now names the window's set of ids, which is the same on both passes.
    @Test func openingTheSheetWithClientsDerivesOnce() async throws {
        let (sheet, appearing) = try await appShaped()
        defer { sheet.window.close() }
        #expect(!sheet.roster.window(for: sheet.sources).clientSourceIds.isEmpty, Comment(rawValue:
            "no watched source is a client's, so the client window this test is about is empty and "
            + "the count below measures a sheet without it (L159)"))
        #expect(appearing == 1, Comment(rawValue:
            "opening the Sources sheet derived the whole store \(appearing) times, against one. What "
            + "moved: \(QueueRenderCounter.reasons(for: QueueRenderCounter.sourcesSurface).suffix(4)) (#4112)"))
    }

    // A ROSTER RELOAD THAT CHANGES NO VERDICT derives nothing.
    //
    // A client nobody's source matches joins the roster. `ClientCoverage.signature` moves (the client list
    // is part of it), so the `.onChange` runs and writes all four of its values: the coverage result, the
    // calendar result, the flags and the window. The window it writes holds exactly the ids it held, so
    // nothing the derivation reads has changed. This is the path that exposed the second key defect: a
    // `Set` printed with `String(describing:)` lists its members in an order that is not a property of
    // its contents, so the re-built window could print differently and move the key. No store write here,
    // deliberately, so SwiftData's own re-fetch (see the removal test below) cannot be what derives.
    @Test func aRosterReloadThatChangesNoVerdictDerivesNothing() async throws {
        let (sheet, _) = try await appShaped()
        defer { sheet.window.close() }
        let before = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface)
        let rendersBefore = QueueRenderCounter.renderCount(for: QueueRenderCounter.sourcesSurface)
        let reasonsBefore = QueueRenderCounter.reasons(for: QueueRenderCounter.sourcesSurface).count

        sheet.file.clients = Self.clients + [Self.client("Another Unmatched Society")]
        sheet.roster.reload()

        _ = await waitUntilQuiet(in: sheet.hosting)
        let derivations = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface) - before
        let evaluations = QueueRenderCounter.renderCount(for: QueueRenderCounter.sourcesSurface) - rendersBefore
        let why = QueueRenderCounter.reasons(for: QueueRenderCounter.sourcesSurface).dropFirst(reasonsBefore)
        // THE POSITIVE CONTROL: the reload reached the sheet and the cascade ran, or a zero below means
        // nothing happened rather than that nothing was re-derived (L159).
        #expect(evaluations >= 1 && why.contains { $0.contains("clients") }, Comment(rawValue:
            "the reload never reached the sheet (\(evaluations) evaluations, reasons \(Array(why))), so "
            + "this fixture did not exercise the cascade"))
        #expect(derivations == 0, Comment(rawValue:
            "a roster reload that changed no source's verdict derived the whole store \(derivations) "
            + "time(s). What moved: \(why.joined(separator: " | ")) (#4112)"))
    }

    // A TOWN RENAMED IN PLACE still re-derives, which is what the key's town NAMES are for.
    //
    // `geo` used to be built inside the memo's observation tracking, so an in-place edit of a row's
    // `town` was caught there. It is built outside it now (the removal test says why), and the identity
    // half of the key cannot see a field edit. Unsaved, deliberately: a save makes SwiftData refresh every
    // row, which re-derives on its own and would pass this test whatever the key said.
    @Test func aTownRenamedInPlaceStillReDerives() async throws {
        let (sheet, _) = try await appShaped()
        defer { sheet.window.close() }
        let ctx = sheet.container.mainContext
        let town = ExcludedTown(town: "yonkers")
        ctx.insert(town)
        try ctx.save()
        _ = await waitUntilQuiet(in: sheet.hosting)
        let before = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface)

        town.town = "white plains"

        _ = await waitUntilQuiet(in: sheet.hosting)
        let derivations = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface) - before
        #expect(derivations >= 1, Comment(rawValue:
            "renaming an excluded town in place derived the sheet \(derivations) times, so its rooms are "
            + "still judged against the old town (L40, #4112)"))
    }

    // ONE REMOVAL UNDER THE APP'S INPUTS, and what each derivation it costs is for.
    //
    // THREE, and each is named, which is what #4112 asked for in place of a count. Measured 2026-09-25
    // with the memo's stale flag and a per field observer on sample rows:
    //
    //   1. The write. `WatchlistEditing.stopWatching` sets `isActive` and `inactiveReasonRaw`, which the
    //      pass reads to section the row. One re-derivation after a write that changed what the last one
    //      read is correct.
    //   2. The `WatchedSource` re-fetch. After the save, SwiftData re-fetches every query over the table
    //      and, doing so, fires `willSet` on EVERY property of EVERY row it returns, changed or not:
    //      an untouched row fired all 41 of its fields. Observation cannot tell that from a real edit.
    //   3. The `Prospect` re-fetch, the same thing again: one untouched show fired all 136 of its fields,
    //      although the save touched no show at all.
    //
    // Before this change the tracking also watched the queries' OWN result storage, because the sources
    // and the town tables were read inside it. That is removed, and it was measured to share its turn
    // with the row refresh, so it did not change the count. The queries coalesce by table: holding all
    // six of `RootView`'s queries here costs the same three as holding one.
    //
    // WHY 2 AND 3 REMAIN. Telling a refresh from an edit needs the VALUES, and a value snapshot of what
    // the pass reads was measured at 3.95 ms against a 6.21 ms derivation (`SourcesSheetCostTests`,
    // 2026-09-08) and paid on every body evaluation, which is most of the cost it would save and a
    // regression on every scroll. #3656 also ruled out hashing it, because a collision draws a number the
    // store disagrees with. So they are explained here rather than removed.
    //
    // WHAT THIS SAYS ABOUT THE LIVE EIGHT. The live `passes=8` counts BODY EVALUATIONS, and it was taken
    // before the memo landed, when every evaluation derived. Menu and hover state on a real press add
    // evaluations of their own, and since the memo those derive nothing.
    //
    // #4247: the reason trace used to name the FIRST of these three `feedbackRevision`. That was the trace
    // itself reading the banner's revision during body evaluation, which subscribed the sheet to every
    // message; the banner's own modifier never did. With the read gone the first derivation still
    // happens, because the write marked it stale, and it now arrives on whichever evaluation comes next.
    private static let allowedDerivationsForOneRemovalUnderTheApp = 3

    @Test func removingOneSourceUnderTheAppsInputsDerivesOncePerThingThatMoved() async throws {
        let (sheet, _) = try await appShaped()
        defer { sheet.window.close() }
        let before = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface)
        let reasonsBefore = QueueRenderCounter.reasons(for: QueueRenderCounter.sourcesSurface).count

        // Through the same path and the same context the button uses.
        WatchlistMutations.stopWatching(sheet.sources[3], context: sheet.container.mainContext,
                                        feedback: sheet.feedback)

        _ = await waitUntilQuiet(in: sheet.hosting)
        let derivations = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface) - before
        let why = QueueRenderCounter.reasons(for: QueueRenderCounter.sourcesSurface).dropFirst(reasonsBefore)
        // The reading itself, printed so a run records it and not only a verdict over it.
        print("removal-reading app-shaped: derivations=\(derivations) reasons=\(Array(why))")
        #expect(derivations >= 1, Comment(rawValue:
            "removing a row derived the sheet \(derivations) times, so the sheet never reacted and the "
            + "ceiling below would pass over one that had stopped working (L159)"))
        #expect(derivations <= Self.allowedDerivationsForOneRemovalUnderTheApp, Comment(rawValue:
            "removing ONE of \(Self.rows) rows under the app's inputs derived the Sources sheet "
            + "\(derivations) times against \(Self.allowedDerivationsForOneRemovalUnderTheApp). What "
            + "moved: \(why.joined(separator: " | ")) (#4112)"))
    }

    // A BANNER WITH NO DATA CHANGE neither rebuilds the sheet nor derives it.
    //
    // #4247 CORRECTS WHAT #4112 FIRST RECORDED HERE. #4112's reason trace named `feedbackRevision` as the
    // first cause of a removal's rebuilds, and this test was written to hold a banner at zero
    // DERIVATIONS, with at least one EVALUATION as its positive control. Both halves described the
    // instrument. The trace read `feedback.revision` while the body was evaluated, and reading an
    // observed property there subscribes the whole body to it, so the trace added to explain the
    // rebuilds was itself what rebuilt the sheet on every banner. #4197 measured the same shape on four
    // other sheets: the banner is a `ViewModifier` that reads the feedback in its OWN body, so a message
    // invalidates the modifier and never the sheet beneath it.
    //
    // So the assertion is now the stronger one: ZERO evaluations, not only zero derivations. A body pass
    // behind the memo is cheaper than a derivation but it is not free (the key alone walks every row's
    // identity), and a banner has no business causing one.
    //
    // THE POSITIVE CONTROL is that the banner is really up over this sheet, not that the sheet rebuilt:
    // the sheet's own banner has mounted and carries the message just raised (L159, and
    // `ABannerDerivesNothingOnAnySheetTests` reads it the same way).
    @Test func aBannerWithNoDataChangeNeitherRebuildsNorDerives() async throws {
        let c = try container()
        let ctx = ModelContext(c)
        _ = seed(ctx)

        let feedback = ActionFeedback()
        let (window, hosting) = host(Harness(container: c, prospects: [], feedback: feedback))
        defer { window.close() }

        _ = await waitUntilQuiet(in: hosting)
        let derivationsBefore = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface)
        let rendersBefore = QueueRenderCounter.renderCount(for: QueueRenderCounter.sourcesSurface)
        #expect(derivationsBefore > 0, Comment(rawValue:
            "the sheet never derived while appearing, so this fixture cannot tell a memo that works "
            + "from one that was never asked (L98)"))

        // A message, and nothing else. No store write, no query change.
        let message = "Stopped watching Organisation 0. \(UUID().uuidString)"
        feedback.acknowledge(message)

        _ = await waitUntilQuiet(in: hosting)
        let derivations = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface)
            - derivationsBefore
        let evaluations = QueueRenderCounter.renderCount(for: QueueRenderCounter.sourcesSurface)
            - rendersBefore
        print("banner-reading sourcesSheet: derivations=\(derivations) evaluations=\(evaluations)")

        #expect(feedback.topBanner > 0 && feedback.message == message, Comment(rawValue:
            "the banner never appeared over the Sources sheet, so this fixture never exercised the case "
            + "and the counts below prove nothing (L159)"))
        #expect(evaluations == 0, Comment(rawValue:
            "raising a banner with no data change re-evaluated the Sources sheet \(evaluations) "
            + "time(s). The banner modifier reads the feedback in its own body; the sheet re-evaluates "
            + "only if something in ITS body reads it too (#4247, #4197)"))
        #expect(derivations == 0, Comment(rawValue:
            "raising a banner with no data change derived the whole Sources sheet \(derivations) "
            + "time(s) over \(evaluations) body evaluation(s) (#4112, #4247)"))
    }
}
