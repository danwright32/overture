import Testing
import Foundation
import SwiftData

// #2530: a row whose `inactiveReason` is `.orgRefusal` is the one record in Overture that must never be
// quietly rewritten. It records a person having said no.
//
// `WatchlistEditing` guarded the RESULT of the two consent routes: `add` and `resumeWatching` both return
// `.refused` and leave `isActive` false. Nothing guarded the row's other FIELDS, so any other route into a
// WatchedSource could edit a refusal record and no test would notice. Found live while reviewing PR #2527:
// its revive branch called `editURL` on whatever `resumeWatching` returned, so typing a refused org back in
// with a different address rewrote that record's `listingsURL`, cleared its page-derived state and set
// `hasUnreadChanges` on a row that must never be read again. `anOrgThatRefusedCannotBeAddedByHandEither`
// passed throughout, because it asserts only the result, the row count and `isActive`.
//
// So this pins the row itself rather than any one route's answer, and it derives BOTH of its lists from the
// source rather than from memory (L96): every route that can reach a WatchedSource, and every field that
// route could change. A hand-written list of either would only ever check what somebody remembered, and the
// route that gets added next is exactly the one missing from it.
@MainActor
@Suite("A refused source cannot be edited by any route (#2530)")
struct RefusedSourceIsImmutableTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([WatchedSource.self, Prospect.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // A refused row carrying a value in every field a route might plausibly touch, so "unchanged" is a
    // real claim rather than a comparison of empty against empty.
    private func refusedSource(in ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: "refused-org", orgName: "Refused Org",
                              listingsURL: "https://refused.example/events", kind: .html)
        s.isActive = false
        s.inactiveReason = .orgRefusal
        s.lastContentHash = "hash-from-before-the-refusal"
        s.lastObservedContentHash = "observed-from-before-the-refusal"
        s.confirmedEmptyHash = "confirmed-empty-before-the-refusal"
        s.pendingContentHash = "pending-from-before-the-refusal"
        s.venueName = "The Room As It Was"
        s.venueLocation = "Brooklyn, NY"
        s.hasUnreadChanges = false
        s.lastPlacedCount = 4
        ctx.insert(s)
        try? ctx.save()
        return s
    }

    private func liveSource(in ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: "live-org", orgName: "Live Org",
                              listingsURL: "https://live.example/events", kind: .html)
        s.isActive = true
        s.lastContentHash = "hash"
        s.venueName = "A Room"
        s.venueLocation = "Brooklyn, NY"
        ctx.insert(s)
        try? ctx.save()
        return s
    }

    // Every stored field, rendered as text. Compared whole rather than field by field so a route that
    // changes something nobody thought to name is still caught.
    //
    // `everyStoredFieldIsInTheSnapshot` below is what keeps this honest as WatchedSource grows: a field
    // added later and left out of here would make this snapshot silently blind to it, which is the same
    // shape of defect as the one being fixed.
    private func snapshot(_ s: WatchedSource) -> String {
        [
            s.sourceId, s.orgName, s.listingsURL ?? "nil", s.kindRaw, String(s.isActive),
            s.inactiveReasonRaw ?? "nil", s.healthRaw, s.lastErrorRaw ?? "nil",
            String(describing: s.lastCheckedAt), String(describing: s.lastManualReadAt),
            String(describing: s.lastSucceededAt), s.lastContentHash ?? "nil",
            String(s.successfulCheckCount), String(s.hasUnreadChanges), s.confirmedEmptyHash ?? "nil",
            s.pendingContentHash ?? "nil", s.pendingPageMonthsRaw, s.lastObservedContentHash ?? "nil",
            String(s.lastFetchWasInsecure), String(s.baselineFeedCount), String(s.degradedStreak),
            String(s.lastDegradedCount), String(s.emptyStreak), String(describing: s.lastNonEmptyAt),
            String(s.failedReadStreak), String(s.lastReadableCount), String(s.lastUnreadableCount),
            String(s.lastUnreadableTitleCount), String(s.lastStructuralGapCount),
            s.lastDroppedShowLabelsRaw, String(s.lastPlacedCount), String(s.hadPlacedBeforeLastRun),
            s.venueLocation ?? "nil", s.venueName ?? "nil", s.ticketingFeedURL ?? "nil",
            String(describing: s.clientTagOverride), s.clientTagClientId ?? "nil",
            String(s.mergeSameDateVenue), String(s.pageCount), String(describing: s.addedAt),
            s.notes ?? "nil"
        ].joined(separator: "|")
    }

    // Each route that can reach a WatchedSource, as a name and a call. `everyRouteIsCovered` below checks
    // this list against the source, so a route added later fails rather than quietly going unguarded.
    private func routes() -> [(name: String, run: (WatchedSource, ModelContext) -> Void)] {
        [
            ("editURL", { s, ctx in _ = WatchlistEditing.editURL(s, to: "https://elsewhere.example/events", in: ctx) }),
            ("setVenueName", { s, ctx in WatchlistEditing.setVenueName(s, to: "A Different Room", in: ctx) }),
            ("setVenueLocation", { s, ctx in _ = WatchlistEditing.setVenueLocation(s, to: "Queens, NY", in: ctx) }),
            ("clearStateDerivedFromTheWatchedPage", { s, _ in
                WatchlistEditing.clearStateDerivedFromTheWatchedPage(s)
            }),
            ("confirmEmpty", { s, ctx in _ = WatchlistEditing.confirmEmpty(s, in: ctx) }),
            ("stopWatching", { s, ctx in WatchlistEditing.stopWatching(s, in: ctx) }),
            ("resumeWatching", { s, ctx in _ = WatchlistEditing.resumeWatching(s, in: ctx) })
        ]
    }

    // Functions that take a WatchedSource and are supposed to ASK something rather than change it. Kept as
    // a second list rather than an exemption, so a function added later must be classified as one or the
    // other and cannot simply be skipped. The classification is then checked rather than trusted: each of
    // these is required below to leave a LIVE row alone, which is what makes it a query.
    private func queries() -> [(name: String, run: (WatchedSource, ModelContext) -> Void)] {
        [
            ("isRefusalRecord", { s, _ in _ = WatchlistEditing.isRefusalRecord(s) })
        ]
    }

    @Test func aQueryChangesNothingAboutAnyRow() throws {
        for query in queries() {
            let ctx = try context()
            let live = liveSource(in: ctx)
            let before = snapshot(live)

            query.run(live, ctx)

            #expect(snapshot(live) == before,
                    "\(query.name) is listed as a query but changed a live row, so it is a route")
        }
    }

    @Test func noRouteChangesAnythingAboutARefusedRow() throws {
        for route in routes() {
            let ctx = try context()
            let refused = refusedSource(in: ctx)
            let before = snapshot(refused)

            route.run(refused, ctx)

            #expect(snapshot(refused) == before, """
                \(route.name) changed a refused row.
                before: \(before)
                after:  \(snapshot(refused))
                """)
        }
    }

    // The other half, and the one that stops the test above passing for the wrong reason. If these routes
    // simply did nothing to any row, every assertion above would hold while the app was broken. Each route
    // must be shown to DO something to a live row, so "unchanged" means refused and not inert.
    @Test func everyOneOfThoseRoutesDoesChangeALiveRow() throws {
        for route in routes() where route.name != "resumeWatching" {
            let ctx = try context()
            let live = liveSource(in: ctx)
            let before = snapshot(live)

            route.run(live, ctx)

            #expect(snapshot(live) != before,
                    "\(route.name) changed nothing on a LIVE row, so its refusal case proves nothing")
        }
    }

    // resumeWatching is the exception to the case above and gets its own, because a live row is already
    // being watched: there is nothing for it to resume. It is shown to act on a row stopped for an ordinary
    // reason instead, which is the state it exists for.
    @Test func resumeWatchingDoesChangeARowStoppedForAnOrdinaryReason() throws {
        let ctx = try context()
        let stopped = liveSource(in: ctx)
        WatchlistEditing.stopWatching(stopped, in: ctx)
        let before = snapshot(stopped)

        _ = WatchlistEditing.resumeWatching(stopped, in: ctx)

        #expect(snapshot(stopped) != before,
                "resumeWatching changed nothing on a stopped row, so its refusal case proves nothing")
        #expect(stopped.isActive)
    }

    // And the answer a route gives is still the refusal, not a silent success, wherever the route has a
    // result that can carry one. A row left unchanged while the caller is told it worked is the same defect
    // one level up.
    @Test func aRouteWithAResultSaysItWasRefused() throws {
        let ctx = try context()
        let refused = refusedSource(in: ctx)

        #expect(WatchlistEditing.resumeWatching(refused, in: ctx) == .refused(orgName: "Refused Org"))
        #expect(WatchlistEditing.editURL(refused, to: "https://elsewhere.example/events", in: ctx)
                == .refused(orgName: "Refused Org"))
    }

    // MARK: - The two lists, derived from the source rather than remembered

    // Every `static func` in WatchlistEditing that takes a WatchedSource is a route into one, so it has to
    // appear in `routes()` above. Derived by reading the file, because a hand-written list only ever checks
    // what somebody remembered and the route added next is the one missing from it (L96).
    @Test func everyRouteIsCovered() throws {
        let source = try macFile("Overture/Domain/WatchlistEditing.swift")
        let covered = Set(routes().map(\.name)).union(queries().map(\.name))

        var missing: [String] = []
        for (_, line) in SwiftSource.scannableLines(in: source) {
            guard line.contains("static func"), line.contains("_ source: WatchedSource") else { continue }
            guard !line.contains("private static func") else { continue }
            guard let name = line.split(separator: "func").last?
                .split(separator: "(").first?.trimmingCharacters(in: .whitespaces) else { continue }
            if !covered.contains(name) { missing.append(name) }
        }

        #expect(missing.isEmpty, """
            These functions take a WatchedSource and are in neither list: \(missing).
            Add each to routes() if it changes the row, or to queries() if it only asks something. A \
            function in neither can rewrite a refusal record with nothing going red.
            """)
    }

    // Every stored field on WatchedSource has to be in `snapshot`, or the comparison is blind to whatever
    // a route changes there. The mirror of the check above: that one covers the routes in, this one covers
    // what they can reach.
    @Test func everyStoredFieldIsInTheSnapshot() throws {
        let model = try macFile("Overture/Domain/WatchedSource.swift")
        let snapshotSourceText = try macFile("OvertureTests/RefusedSourceIsImmutableTests.swift")

        var missing: [String] = []
        for (_, line) in SwiftSource.scannableLines(in: model) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("var ") || trimmed.hasPrefix("@Attribute(.unique) var ") else { continue }
            // Computed properties read the stored ones, so pinning the stored value covers them.
            guard !line.contains("{") else { continue }
            guard let name = trimmed.replacingOccurrences(of: "@Attribute(.unique) ", with: "")
                .dropFirst("var ".count)
                .split(separator: ":").first?.trimmingCharacters(in: .whitespaces) else { continue }
            if !snapshotSourceText.contains("s.\(name)") { missing.append(name) }
        }

        #expect(missing.isEmpty, """
            These stored fields of WatchedSource are not in snapshot(): \(missing).
            A route could change any of them on a refused row and the comparison above would not see it.
            """)
    }

    // Read through the shared search, which halts loudly if the repo is not there: a file this could not
    // find would make every assertion above vacuously true, which is #1967's exact failure. Paths are
    // relative to the mac folder, which is the convention SourceGuardCoverageGuardTests resolves every
    // path literal in a test file against, so a file that moves is caught there too.
    private func macFile(_ path: String) throws -> String {
        try String(contentsOf: RepoRoot.mac.appendingPathComponent(path), encoding: .utf8)
    }
}
