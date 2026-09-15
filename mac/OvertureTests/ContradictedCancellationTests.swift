import Testing
import Foundation
import SwiftData

// #3278: the store contradicting itself about one show, and which half is wrong.
//
// The LIVE measurement is the point of this suite. Every figure quoted for this issue so far came from
// SQL written beside the app, folding titles and venues with a plain lowercase, which is a second
// definition of the population and disagrees with the app in the direction that flatters the argument
// (L107). One such number was posted to an issue tonight and withdrawn. What this measures instead is
// the app's own predicate over Dan's own store, after a launch replay, so the count is the one his
// screen would show.
@MainActor
@Suite("A cancellation contradicted by a live twin (#3278)")
struct ContradictedCancellationTests {
    private let sandboxes = TemporarySandboxes()

    nonisolated private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }
    nonisolated private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    private func container(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, url: url,
                                                                      cloudKitDatabase: .none)])
    }

    private func memoryContext() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema,
                                                                isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func row(_ ctx: ModelContext, key: String, title: String, venue: String,
                     opens: String, runEnd: String?, missed: Int) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: title, discipline: "theater", venue: venue,
                         performanceDate: opens, sourceListingURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "unknown", coverage: "unknown", fitScore: 3,
                         tier: "medium", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: runEnd, partOfRelatedRun: runEnd != nil,
                         runSourceURLs: [], runNights: [opens])
        p.missedScoutCount = missed
        ctx.insert(p)
        return p
    }

    // THE RULE. A flagged row whose twin is still listed, at one venue, over overlapping nights.
    @Test func aFlaggedRowIsContradictedByALiveTwin() throws {
        let ctx = try memoryContext()
        let flagged = row(ctx, key: "a", title: "Marlise (A New Golden Age Musical)",
                          venue: "The Players Theatre", opens: "2026-09-04", runEnd: "2026-09-06",
                          missed: 13)
        let live = row(ctx, key: "b", title: "Marlise (A New Golden Age)",
                       venue: "The Players Theatre", opens: "2026-08-30", runEnd: "2026-09-06",
                       missed: 0)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(ContradictedCancellation.liveTwin(of: flagged, among: all)?.naturalKey == live.naturalKey)
    }

    // Every arm of the rule must be load bearing, or it is one condition wearing four names (L178).
    @Test func aRowIsNotContradictedWhenAnyArmDisagrees() throws {
        let ctx = try memoryContext()
        let flagged = row(ctx, key: "a", title: "Open Mic", venue: "Jalopy Theatre",
                          opens: "2026-09-04", runEnd: nil, missed: 13)
        row(ctx, key: "other venue", title: "Open Mic", venue: "The Cutting Room",
            opens: "2026-09-04", runEnd: nil, missed: 0)
        row(ctx, key: "other night", title: "Open Mic", venue: "Jalopy Theatre",
            opens: "2026-11-20", runEnd: nil, missed: 0)
        row(ctx, key: "other act", title: "Chamber Recital", venue: "Jalopy Theatre",
            opens: "2026-09-04", runEnd: nil, missed: 0)
        row(ctx, key: "also flagged", title: "Open Mic", venue: "Jalopy Theatre",
            opens: "2026-09-04", runEnd: nil, missed: 7)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(ContradictedCancellation.liveTwin(of: flagged, among: all) == nil,
                "a different venue, a different night, a different act and a row that is ALSO flagged must none of them contradict a cancellation")
    }

    // A row that is not flagged at all has nothing to contradict.
    @Test func anUnflaggedRowIsNeverContradicted() throws {
        let ctx = try memoryContext()
        let healthy = row(ctx, key: "a", title: "Marlise", venue: "The Players Theatre",
                          opens: "2026-09-04", runEnd: nil, missed: 0)
        row(ctx, key: "b", title: "Marlise", venue: "The Players Theatre",
            opens: "2026-09-04", runEnd: nil, missed: 0)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(ContradictedCancellation.liveTwin(of: healthy, among: all) == nil)
    }

    // #3278: the SET, computed once over the corpus, which is what the render pass can afford to call.
    //
    // `liveTwin(of:among:)` answers about ONE row and is the right shape for a test. Asking it per
    // flagged row from the pass is 41 rows against 1,233 on Dan's store, which is the whole store walked
    // per pass: the cost milestone 80 spent itself removing. This indexes the live rows by their folded
    // venue first, so a flagged row is compared only against rows in its own room.
    @Test func theSetAgreesWithAskingRowByRow() throws {
        let ctx = try memoryContext()
        let gone = row(ctx, key: "gone", title: "Marlise (A New Golden Age Musical)",
                       venue: "The Players Theatre", opens: "2026-09-04", runEnd: "2026-09-06", missed: 13)
        row(ctx, key: "live", title: "Marlise (A New Golden Age)",
            venue: "The Players Theatre", opens: "2026-08-30", runEnd: "2026-09-06", missed: 0)
        row(ctx, key: "other", title: "Space Quest",
            venue: "The Players Theatre", opens: "2026-09-04", runEnd: "2026-09-06", missed: 13)
        // The venue arm, made load bearing IN THE INDEX and not only in `liveTwin`. Without this row
        // every row in the fixture is at one venue, so an index that folded the rooms together would
        // give the same answer and the arm would be untested here (L178, L159).
        row(ctx, key: "same act elsewhere", title: "Space Quest",
            venue: "The Cutting Room", opens: "2026-09-04", runEnd: "2026-09-06", missed: 0)
        // The LIVENESS arm, likewise made load bearing in the index. Two rows can both be genuinely gone,
        // and each other's existence contradicts nothing. Added because dropping `missedScoutCount == 0`
        // from the index SURVIVED without it: every other flagged row in this fixture happens to differ
        // by venue or by act, so a room that admitted flagged rows gave the same answer (L1, L178).
        row(ctx, key: "both gone", title: "A Little Night Music",
            venue: "Joe's Pub", opens: "2026-09-04", runEnd: "2026-09-06", missed: 13)
        row(ctx, key: "both gone twin", title: "A Little Night Music (2026)",
            venue: "Joe's Pub", opens: "2026-09-04", runEnd: "2026-09-06", missed: 4)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let set = ContradictedCancellation.contradictedKeys(among: all)
        // Asserted AGAINST the row-by-row answer rather than against a literal, so the index can never
        // drift from the rule it is meant to be an index of (L58).
        let rowByRow = Set(all.filter { ContradictedCancellation.liveTwin(of: $0, among: all) != nil }
                              .map(\.naturalKey))
        #expect(set == rowByRow, "the indexed answer disagrees with asking each row on its own")
        #expect(set == [gone.naturalKey], "only the row with a live twin is contradicted")
        #expect(!set.contains("other"), "a flagged row with no live twin keeps its warning")
    }

    // THE WIRING, asked through the whole pass rather than through the rule.
    //
    // The three tests above prove the RULE, and a correct rule reaching no card is the shape this issue
    // is about: the warning would go on being drawn while every test stayed green (L3). So this one calls
    // `QueueModel.scope` and reads the card the screen would read, which is the only assertion here that
    // crosses `contradictedKeys` to the preamble to `card`. It went red before the wiring existed, on the
    // first line of it, with `the contradicted row still carries the warning`.
    @Test func thePassWithholdsTheWarningOnTheCardItself() throws {
        let ctx = try memoryContext()
        // Dated relative to the run, never a literal, so the queue's own window cannot age this fixture
        // out from under it and turn a real red into a row that is simply not on screen (L130).
        let opens = EasternDate.dayString(from: Date().addingTimeInterval(14 * 86400))
        let closes = EasternDate.dayString(from: Date().addingTimeInterval(21 * 86400))
        row(ctx, key: "gone", title: "Marlise (A New Golden Age Musical)",
            venue: "The Players Theatre", opens: opens, runEnd: closes, missed: 13)
        row(ctx, key: "live", title: "Marlise (A New Golden Age)",
            venue: "The Players Theatre", opens: opens, runEnd: closes, missed: 0)
        row(ctx, key: "alone", title: "Space Quest",
            venue: "The Players Theatre", opens: opens, runEnd: closes, missed: 13)
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        var data = QueueModel.scope(from: all)
        func warning(_ key: String) throws -> Bool {
            let row = try #require(data.rows.first { $0.id == key }, "no row for \(key)")
            return data.cards.card(for: row).disappearedFromFeed
        }

        #expect(try warning("gone") == false,
                Comment(rawValue: "the contradicted row still carries the warning: the store holds a "
                        + "live row for the same act, at the same venue, over the same nights (#3278)"))
        // The POSITIVE control in the same fixture, so a pass here can never be the whole feature being
        // switched off (L159). `alone` is flagged exactly as `gone` is and has no live twin.
        #expect(try warning("alone") == true,
                "a flagged row with nothing contradicting it must keep its warning")
    }

    // THE MEASUREMENT, and the reason this suite exists. Counted through the app's own rule, on a clone of
    // Dan's store, after a launch replay, so it is what his screen would show rather than what a query
    // beside the app says.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func noFutureShowIsFlaggedGoneWhileALiveTwinContradictsIt() async throws {
        await RealStoreTestLock.shared.acquire()
        defer { Task { await RealStoreTestLock.shared.release() } }

        let dir = try sandboxes.make(named: "contradicted-cancellation")
        guard let clone = try LiveStoreClone.makeClone(in: dir) else { return }
        let ctx = ModelContext(try container(at: clone))
        LaunchReplay.run(in: ctx, handoffDirectory: try sandboxes.make(named: "contradicted-handoff"))
        try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let today = QueueModel.easternToday()
        let onScreen = all.filter { ($0.runEndDate ?? $0.performanceDate ?? "") >= today }
        let flagged = onScreen.filter(\.disappearedFromFeed)
        let contradicted = flagged.filter { ContradictedCancellation.liveTwin(of: $0, among: all) != nil }

        print("Contradicted cancellation corpus: \(flagged.count) future row(s) flagged gone, "
              + "of \(onScreen.count) on screen; \(contradicted.count) contradicted by a live twin")

        // ASSERTED THROUGH WHAT IS DRAWN, never through the stored field, and the difference is the
        // whole point of the fix. `disappearedFromFeed` on the model stays true: the row really has
        // missed thirteen sweeps, and #3278's first half, which stops the duplicate being minted at
        // all, is not what this ships. What changes is that the CARD does not carry the warning while
        // the store holds a live twin. A test asserting the stored field were empty would be red
        // forever and would be asking for a fix nobody wrote (L63).
        //
        // And it is asked of the PASS, over the real corpus, rather than of `contradictedKeys` again.
        // Comparing the set against the rows `liveTwin` picks out would be one rule checked against
        // itself and could not go red for any reason (L70); this crosses every step between the rule
        // and the screen.
        var data = QueueModel.scope(from: onScreen, corpus: all)
        let stillWarned = contradicted.compactMap { show -> String? in
            guard let row = data.rows.first(where: { $0.id == show.naturalKey }) else { return nil }
            return data.cards.card(for: row).disappearedFromFeed ? show.groupName : nil
        }
        #expect(stillWarned.isEmpty,
                Comment(rawValue: "\(stillWarned.count) of \(flagged.count) cancellation warning(s) "
                        + "would still be drawn while a live twin contradicts them (#3278): "
                        + "\(stillWarned.prefix(4))"))
    }
}
