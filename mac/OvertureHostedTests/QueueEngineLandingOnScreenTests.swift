import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #4358 slice E4d: what a scout landing does to the queue ON SCREEN, now that the queue draws the engine's pass.
//
// TWO CLAIMS, each about a real hosted `QueueView` over a real store with the queue engine RootView builds:
//
// #4371 (B2, discussion #4326 decision 9): a card draws a VALUE the engine published, never the live row, so an
// in-place write to a drawn show during a landing re-runs NO card body until the landing closes and the engine
// publishes once; then the card redraws with the new title. Seen to fail by having one card read its live row.
//
// #4614's open question (coordinator, 2026-10-08): the memo path's store held shows by identity and could resolve a
// row drawn from a pass over UNSAVED shows as `drawnBeforeItsFirstSave` once the save re-keyed it. The engine's store
// holds values, so a card is never resolved at all; this lands unsaved shows under a held landing, saves, closes, and
// asserts every new card draws with no unexpected miss and that a press on one finds its show.
//
// Counts, never durations (L63). Every show is invented, on example.org (L155, L222).
@MainActor
@Suite("A scout landing reaches the queue's cards once, when it closes (#4358, #4371)", .serialized)
struct QueueEngineLandingOnScreenTests {

    private static let rows = 12

    private static func night(_ n: Int) -> String { ScoutTestClock.day(20 + n, after: Date()) }

    private static func show(_ key: String, night n: Int) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Ensemble \(key)", discipline: "music",
                         venue: "Venue Hall", performanceDate: night(n), sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        p.presenter = "Ensemble \(key) Presents"
        p.location = "New York, NY"
        return p
    }

    private struct Harness: View {
        let container: ModelContainer
        let engine: QueueEngineHost.Engine
        @State private var deepLinkedKey: LeadDeepLink?
        @State private var deepLinkedKeys: LeadsDeepLink?

        var body: some View {
            QueueView(engine: engine, deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys)
                .modelContainer(container)
                .environment(ActionFeedback())
                .environment(DayOffOfferRequest())
                .environment(QueueUndoStack())
        }
    }

    private struct Hosted {
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
        let engine: QueueEngineHost.Engine
        let context: ModelContext
    }

    private func host() async throws -> Hosted {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let engine = try await HostedQueueEngine.started(context: c.mainContext)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 1600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // AppKit's default releases the window while this scope still holds it (#3480).
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(Harness(container: c, engine: engine)))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        return Hosted(window: window, hosting: hosting, engine: engine, context: c.mainContext)
    }

    // Until neither the card bodies nor the engine's turns have moved for a stretch of polls (L290). Layout and display
    // are driven on every poll because this window is never ordered front (#3480).
    private func settle(_ h: Hosted) async {
        var last = -1
        var quiet = 0
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            h.hosting.layoutSubtreeIfNeeded()
            h.hosting.displayIfNeeded()
            let now = QueueRenderCounter.cardBodyCounts().values.reduce(0, +) + h.engine.counters.turns
            if now == last { quiet += 1 } else { quiet = 0; last = now }
            if quiet >= 40 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func anInPlaceTitleWriteDuringALandingRedrawsNoCardUntilItCloses() async throws {
        let h = try await host()
        defer { HostedPassCounting.unmountAndClose(h.hosting, replacingWith: AnyView(EmptyView()), in: h.window) }
        let keys = (0..<Self.rows).map { "landing-b2-\($0)" }
        for (n, key) in keys.enumerated() { h.context.insert(Self.show(key, night: n / 3)) }
        try h.context.save()
        await settle(h)
        // THE POSITIVE CONTROL: the card under test was drawn, so a zero below is a body that was not asked (L159).
        let drawn = keys.filter { QueueRenderCounter.cardDrew($0) != nil }
        let key = try #require(drawn.first, "no card of this fixture was drawn, so there is nothing to watch")
        let shows = try h.context.fetch(FetchDescriptor<Prospect>())
        let target = try #require(shows.first { $0.naturalKey == key })

        let landing = h.engine.openLanding()
        let before = QueueRenderCounter.cardBodyCounts()[key] ?? 0
        target.groupName = "Retitled Mid Landing"
        try h.context.save()
        await settle(h)
        let duringLanding = (QueueRenderCounter.cardBodyCounts()[key] ?? 0) - before
        #expect(duringLanding == 0, Comment(rawValue:
            "a title written in place during a landing re-ran the card's body \(duringLanding) time(s) before the "
            + "landing closed, so the card reads the live row rather than the engine's published value (#4371)"))
        #expect(QueueRenderCounter.cardDrew(key) != "Retitled Mid Landing",
                "the card drew the new title while the landing was still open")

        h.engine.closeLanding(landing)
        await settle(h)
        #expect(QueueRenderCounter.cardDrew(key) == "Retitled Mid Landing", Comment(rawValue:
            "after the landing closed the card drew \(QueueRenderCounter.cardDrew(key) ?? "nothing"), so the one "
            + "publish at its end did not reach it (L14)"))
    }

    @Test func showsLandedUnsavedUnderAHeldLandingDrawWithNoMissAndResolve() async throws {
        let h = try await host()
        defer { HostedPassCounting.unmountAndClose(h.hosting, replacingWith: AnyView(EmptyView()), in: h.window) }
        for n in 0..<3 { h.context.insert(Self.show("landing-seed-\(n)", night: n)) }
        try h.context.save()
        await settle(h)

        let landing = h.engine.openLanding()
        let keys = (0..<4).map { "landing-new-\($0)" }
        for (n, key) in keys.enumerated() { h.context.insert(Self.show(key, night: n)) }
        // Taken in UNSAVED first, as a landing's batches are, before the save mints their identifiers.
        await settle(h)
        try h.context.save()
        await settle(h)
        h.engine.closeLanding(landing)
        await settle(h)

        let pass = try #require(h.engine.output?.value, "the engine published nothing")
        let rows = pass.data.rows.filter { keys.contains($0.id) }
        #expect(rows.count == keys.count, Comment(rawValue:
            "the published pass holds \(rows.count) of the \(keys.count) landed shows"))
        #expect(rows.allSatisfy { $0.showID?.storeIdentifier != nil }, Comment(rawValue:
            "a landed row carries the identifier it had before its first save, so the re-key never reached it"))
        #expect(pass.data.cards.unexpectedCardMisses == 0, Comment(rawValue:
            "drawing the landed shows counted \(pass.data.cards.unexpectedCardMisses) unexpected miss(es), so a card "
            + "was built from a show the pass did not hold (#4614)"))
        for row in rows {
            let card = pass.card(for: row, resolving: h.engine)
            let identity = try #require(ShowIdentity(card), "the card for \(row.id) names no show")
            #expect(identity.resolve(in: h.engine).show != nil, Comment(rawValue:
                "a press on the landed show \(row.id) was refused, so its card still names an identity that died at "
                + "its first save (`drawnBeforeItsFirstSave`)"))
        }
    }
}
