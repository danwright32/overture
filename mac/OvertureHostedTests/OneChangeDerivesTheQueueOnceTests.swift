import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
import Observation
@testable import Overture

// #4106: how many times does ONE change derive the whole queue?
//
// WHAT WAS MEASURED, on the live app on 2026-09-21. Every action Dan took that afternoon left the same
// signature in the freeze log: a stall spanning two render passes, then one spanning one. A genre change,
// a single dismiss and a whole-night dismiss all paid the whole-store derivation more than once, and the
// issue's first instruction was to find out why before making anything incremental.
//
// WHAT THIS HARNESS SHOWED, and it is the answer to that question. A hosted `QueueView` over 60 shows:
//   one dismiss       2 derivations: `prospects`, then `nothing this view reads`
//   one genre edit    2 derivations: `rows changed`, then `nothing this view reads`
// One saved write reaches the view by two notifications in two separate updates. The model's own
// observation fires the moment a field is set, so the body re-derives with the edit already visible.
// Then the query refetches after the save, in a task of SwiftData's own, and that refetch calls `willSet`
// on the saved objects' properties AGAIN with nothing changed: the stale-marking stack for the second
// one runs through `SwiftData` from `_SwiftData_SwiftUI`, not through any line of Overture. So the second
// derivation is announced as a change by the framework, and nothing that decides by observation can
// tell it from a real one.
//
// WHAT THE FIX DOES, then. `QueueView` derives through a `ScopeMemo`, so an evaluation that changes
// nothing the pass reads is served the answer it already has (#4106), which is
// `aRedrawWithNoDataChangeDerivesNothing` below. And since #4252 an observed change with no save since the
// build, nothing unsaved and no other context's save behind it is served as the refetch it is, with
// observation re-armed, so the three saved-change tests are held at ONE. Dan's call, 2026-09-25 in chat,
// was to tell the two apart by comparing values with supported API only; comparing every value was
// measured at more than the pass it saved, so the memo reads those three supported facts instead.
//
// A COUNT, NOT A DURATION. A count is a statement about this code; a duration is a statement about the
// machine, which is slowest exactly when it is being judged (L63, L290).
@MainActor
@Suite("What one change costs the queue (#4106)")
struct OneChangeDerivesTheQueueOnceTests {

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory(AppSchema.models)
    }

    // Three shows a night, twenty nights, all in the future so every one of them is in the Scout stage.
    // Dated from the real clock because the queue itself reads the real clock; a fixed past date would
    // put every show outside the lead time window and the queue would derive over nothing (L130).
    private static let rows = 60
    private static let showsPerNight = 3

    // One saved change, ONE derivation. It was two until #4252: the change's own, and the one SwiftData's
    // refetch re-announced with nothing changed. `ScopeMemo` now compares values before rebuilding, so the
    // refetch is served the answer the change already derived.
    private static let allowedDerivationsForOneSavedChange = 1

    private static func night(_ n: Int) -> String {
        ScoutTestClock.day(20 + n, after: Date())
    }

    private func seed(_ ctx: ModelContext) {
        for n in 0..<Self.rows {
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n)", discipline: "music",
                             venue: "Venue \(n % 17) Hall", performanceDate: Self.night(n / Self.showsPerNight),
                             sourceListingURL: nil, priorRelationship: "none",
                             production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 4 + (n % 5), tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .new)
            p.presenter = "Ensemble \(n) Presents"
            p.location = "New York, NY"
            ctx.insert(p)
        }
        try? ctx.save()
    }

    // The three objects every mutation writes to are HELD BY THE TEST and handed in, so the writes the
    // real button makes land on objects the hosted view really observes (L472, and #4112's harness
    // records what measuring a throwaway copy cost).
    private struct Harness: View {
        let container: ModelContainer
        let feedback: ActionFeedback
        let dayOffOffer: DayOffOfferRequest
        let undoStack: QueueUndoStack
        let tick: RedrawTick
        // #4358 slice E4d: the queue engine RootView builds, over the same store, started before the queue is hosted.
        let engine: QueueEngineHost.Engine
        @State private var deepLinkedKey: LeadDeepLink?
        @State private var deepLinkedKeys: LeadsDeepLink?

        var body: some View {
            // RootView's part, played here: the queue draws the engine's published pass (#4358 slice E4d).
            // `tick` is read HERE, above the queue, and handed down inside a closure, which is what
            // `RootView` does with every closure it passes: a fresh closure is a changed input, so each
            // redraw above re-evaluates the queue's body with no data behind it (#1930's "nothing this
            // view reads", reproduced on purpose).
            let n = tick.value
            QueueView(engine: engine, deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys,
                      onConnectGmail: { _ = n })
            .modelContainer(container)
            .environment(feedback)
            .environment(dayOffOffer)
            .environment(undoStack)
        }
    }

    @Observable final class RedrawTick {
        var value = 0
    }

    private struct Hosted {
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
        let context: ModelContext
        let feedback: ActionFeedback
        let offer: DayOffOfferRequest
        let undo: QueueUndoStack
        let tick: RedrawTick
    }

    private func host(_ c: ModelContainer) async throws -> Hosted {
        let engine = try await HostedQueueEngine.started(context: c.mainContext)
        let feedback = ActionFeedback()
        let offer = DayOffOfferRequest()
        let undo = QueueUndoStack()
        let tick = RedrawTick()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // AppKit's default releases the window while this scope still holds it, which crashed the shared
        // app host and truncated the whole hosted target once already (#3480).
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(Harness(container: c, feedback: feedback,
                                                              dayOffOffer: offer, undoStack: undo,
                                                              tick: tick, engine: engine)))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        // The MAIN context, because it is the one the view's own mutations write through, and a write
        // through a second context reaches the view by a different route (a merge) than the button's.
        return Hosted(window: window, hosting: hosting, context: c.mainContext,
                      feedback: feedback, offer: offer, undo: undo, tick: tick)
    }

    // #4516: the queue is taken out of the graph before its window closes, so it cannot be evaluated during
    // a later test and charged to it by the process wide counter (`HostedPassCounting.unmountAndClose`).
    private func tearDown(_ h: Hosted) {
        HostedPassCounting.unmountAndClose(h.hosting, replacingWith: AnyView(EmptyView()), in: h.window)
    }

    // Waits until the derivation count has GONE QUIET, collecting the reason for each derivation on the
    // way, rather than for a fixed time (L290, `BringingTheQueueUpTests.waitUntilDerivationsGoQuiet`).
    // Layout and display are driven on every poll because this window is never ordered front (#3480).
    private func settle(_ hosting: NSView, quietPolls: Int = 40) async -> [String] {
        var reasons: [String] = []
        var seen = QueueRenderCounter.derivations
        var quiet = 0
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            if QueueRenderCounter.derivations > seen {
                while QueueRenderCounter.derivations > seen {
                    seen += 1
                    reasons.append(QueueRenderCounter.lastReason)
                }
                quiet = 0
            } else {
                quiet += 1
            }
            if quiet >= quietPolls { return reasons }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return reasons
    }

    private func prospects(_ ctx: ModelContext) throws -> [Prospect] {
        try ctx.fetch(FetchDescriptor<Prospect>())
    }

    private func brought(up h: Hosted) async {
        let appeared = await settle(h.hosting)
        #expect(!appeared.isEmpty, Comment(rawValue:
            "the queue never derived while appearing, so this fixture measures nothing and every count "
            + "below would be zero for the wrong reason (L98)"))
    }

    // ONE show dismissed, through the same mutation the card's Dismiss menu calls.
    @Test func dismissingOneShowDerivesTheQueueNoMoreThanTheSaveAnnounces() async throws {
        let c = try container()
        let h = try await host(c)
        defer { tearDown(h) }
        seed(h.context)
        await brought(up: h)

        let all = try prospects(h.context)
        let target = try #require(all.first { $0.naturalKey == "row-5" })
        ProspectMutations.dismissForReason(QueueItem(target), .notAFit, shows: all, context: h.context,
                                           feedback: h.feedback, offer: h.offer, undo: h.undo)
        let why = await settle(h.hosting)

        // THE POSITIVE CONTROL FIRST. A ceiling of one is satisfied by a queue that never reacted to the
        // dismiss at all, which is the fixture where the defect could not happen (L159).
        #expect(target.status == .dismissed, "the dismiss did not land, so nothing below was measured")
        #expect(why.count >= 1, Comment(rawValue:
            "dismissing a show derived the queue \(why.count) times, so the queue did not react to the "
            + "change and the ceiling below would pass over a queue that had stopped updating"))
        #expect(why.count <= Self.allowedDerivationsForOneSavedChange, Comment(rawValue:
            "dismissing ONE of \(Self.rows) shows derived the whole queue \(why.count) times: "
            + "\(why.joined(separator: " | ")). Each derivation is a whole-store pass (#4106)"))
    }

    // ONE show's genre corrected, the change the freeze log recorded as passes=2 then passes=1. It moves
    // the card rather than removing it, so it is the in-place edit case rather than the removal case.
    @Test func correctingOneShowsGenreDerivesTheQueueNoMoreThanTheSaveAnnounces() async throws {
        let c = try container()
        let h = try await host(c)
        defer { tearDown(h) }
        seed(h.context)
        await brought(up: h)

        let all = try prospects(h.context)
        let target = try #require(all.first { $0.naturalKey == "row-9" })
        ProspectMutations.correctClassification(QueueItem(target), discipline: .theater, shows: all,
                                                context: h.context, feedback: h.feedback)
        let why = await settle(h.hosting)

        #expect(target.discipline == "theater", "the correction did not land, so nothing below was measured")
        #expect(why.count >= 1, Comment(rawValue:
            "correcting a genre derived the queue \(why.count) times, so the queue never saw the edit"))
        #expect(why.count <= Self.allowedDerivationsForOneSavedChange, Comment(rawValue:
            "correcting ONE show's genre derived the whole queue \(why.count) times: "
            + "\(why.joined(separator: " | ")) (#4106)"))
    }

    // #4371 (E4a part 2): ONE card action re-runs ONE card's body, through the real queue over the memo path.
    //
    // The card store the pass publishes holds each show by identity since #4371, and a card it did not
    // prebuild resolves its show through the live shows at draw time. What this pins is that drawing through
    // that resolver changes nothing a card body sees: the cards the action did not touch are the same values
    // as before and skip their bodies (`ScoutCardInputs`), and the one it touched redraws. Counted per card with
    // the card's own body counter (#4260), never timed (L63).
    //
    // THE POSITIVE CONTROLS FIRST (L159): the mount drew at least two cards, so a zero below is a body that was
    // asked and skipped, and the touched card is one of them, so its redraw can be seen at all.
    @Test func oneCardActionReRunsOneCardBody() async throws {
        let c = try container()
        let h = try await host(c)
        defer { tearDown(h) }
        let beforeMount = QueueRenderCounter.cardBodyCounts()
        seed(h.context)
        await brought(up: h)
        let mounted = QueueRenderCounter.cardBodyCounts()
        let drawn = mounted.filter { $0.value > (beforeMount[$0.key] ?? 0) && $0.key.hasPrefix("row-") }
            .map(\.key).sorted()
        #expect(drawn.count >= 2, Comment(rawValue:
            "bringing the queue up ran the bodies of \(drawn) only, so fewer than two cards were drawn and the "
            + "zeros below would mean nothing"))

        let all = try prospects(h.context)
        let targetKey = try #require(drawn.first, "no card was drawn, so there is no card to press")
        let target = try #require(all.first { $0.naturalKey == targetKey })
        let beforeAction = QueueRenderCounter.cardBodyCounts()
        ProspectMutations.correctClassification(QueueItem(target), discipline: .theater, shows: all,
                                                context: h.context, feedback: h.feedback)
        _ = await settle(h.hosting)
        let after = QueueRenderCounter.cardBodyCounts()
        let reRun = Dictionary(uniqueKeysWithValues: drawn.map { ($0, (after[$0] ?? 0) - (beforeAction[$0] ?? 0)) })

        #expect(target.discipline == "theater", "the correction did not land, so nothing below was measured")
        #expect((reRun[targetKey] ?? 0) >= 1, Comment(rawValue:
            "the card whose genre was corrected did not redraw, so it still draws the old genre (L14)"))
        let others = reRun.filter { $0.key != targetKey && $0.value != 0 }
        #expect(others.isEmpty, Comment(rawValue:
            "correcting ONE card's genre re-ran these other cards' bodies \(others.sorted { $0.key < $1.key }), "
            + "so every card action redraws every card on screen (#4322, #4371)"))
    }

    // A whole night, through `dismissAll`, the mutation the night's Dismiss confirmation calls. Several
    // rows change in one write, and that must still be one derivation rather than one per row.
    @Test func dismissingAWholeNightDerivesTheQueueNoMoreThanTheSaveAnnounces() async throws {
        let c = try container()
        let h = try await host(c)
        defer { tearDown(h) }
        seed(h.context)
        await brought(up: h)

        let all = try prospects(h.context)
        let night = Self.night(4)
        let keys = all.filter { $0.performanceDate == night }.map(\.naturalKey)
        #expect(keys.count == Self.showsPerNight, Comment(rawValue: "the fixture's night holds "
                + "\(keys.count) shows, not the \(Self.showsPerNight) it was built with"))
        _ = ProspectMutations.dismissAll(keys, reason: .notAFit, dateLabel: night, nightDate: night,
                                         shows: all, context: h.context, feedback: h.feedback,
                                         undo: h.undo)
        let why = await settle(h.hosting)

        #expect(all.filter { keys.contains($0.naturalKey) }.allSatisfy { $0.status == .dismissed },
                "the night was not dismissed, so nothing below was measured")
        #expect(why.count >= 1, Comment(rawValue:
            "dismissing a night derived the queue \(why.count) times, so the queue never saw the change"))
        #expect(why.count <= Self.allowedDerivationsForOneSavedChange, Comment(rawValue:
            "dismissing ONE night of \(keys.count) shows derived the whole queue \(why.count) times: "
            + "\(why.joined(separator: " | ")) (#4106)"))
    }

    // THE CASE THE MEMO REMOVES: the screen above redraws and nothing in the store moved. Every such
    // redraw used to be a whole-store pass, and `RootView` redraws for a banner, an undo entry, a sheet,
    // a scout heartbeat and more, none of which can be enumerated from the queue (L471).
    //
    // ZERO derivations, not one, because nothing the pass reads changed and "it rebuilt but quickly" is
    // a statement about the machine (L63).
    //
    // #4358 slice E4d: the queue holds no memo and no clock of its own any more. It draws the pass the engine
    // published, and the engine derives only when its turn takes a change in, so a redraw from above derives
    // nothing however late it arrives. The wait past the render memo's two second window (#4516) went with the
    // memo, since there is no window left for a late redraw to fall outside.
    @Test func aRedrawWithNoDataChangeDerivesNothing() async throws {
        let c = try container()
        let h = try await host(c)
        defer { tearDown(h) }
        seed(h.context)
        await brought(up: h)

        let evaluationsBefore = QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface)
        var why: [String] = []
        for _ in 0..<3 {
            h.tick.value += 1
            why += await settle(h.hosting, quietPolls: 10)
        }
        why += await settle(h.hosting)
        let evaluations = QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface)
            - evaluationsBefore

        // THE POSITIVE CONTROL. The redraws must really have reached the queue's body, or a zero below
        // means the body never ran rather than that the pass was skipped (L159).
        #expect(evaluations >= 3, Comment(rawValue:
            "three redraws above the queue evaluated its body \(evaluations) times, so this fixture never "
            + "exercised the case and the zero below would prove nothing"))
        #expect(why.isEmpty, Comment(rawValue:
            "\(evaluations) body evaluations with no data change derived the whole queue \(why.count) "
            + "time(s): \(why.joined(separator: " | ")). Every redraw of the screen above costs a "
            + "whole-store pass (#4106)"))
    }

    // #4570: bringing the queue up over a store that already holds its shows derives it ONCE, the first
    // redraw from above included.
    //
    // The queue's first build runs before any row has drawn, so it is asked for no card and every row the
    // first frame draws is built on demand. Until #4570 the first redraw after that frame then asked for
    // those cards, which the held answer had not prebuilt, and derived the whole store again (measured on
    // this harness 2026-10-07: one derivation inside `host`, then one more on the first redraw, reason
    // `nothing this view reads`). The Archive paid the same on every open; both now go through
    // `ScopeMemo.value(fingerprint:drawn:...)`, which adopts the first frame's cards.
    //
    // Counted from BEFORE `host`, because the mount derivation lands inside it and `settle` only counts
    // from where it starts. Every other test here seeds after hosting, which is a save arriving under a
    // mounted queue; this is the launch, where the store is already full.
    @Test func openingTheQueueOverAFullStoreDerivesItOnce() async throws {
        let c = try container()
        seed(c.mainContext)
        let derivationsBefore = QueueRenderCounter.derivations
        let h = try await host(c)
        defer { tearDown(h) }
        var why = await settle(h.hosting)
        let evaluationsBefore = QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface)
        h.tick.value += 1
        why += await settle(h.hosting)
        let evaluations = QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface)
            - evaluationsBefore
        let derivations = QueueRenderCounter.derivations - derivationsBefore

        // THE POSITIVE CONTROL. The redraw must really have reached the queue's body, or the count below
        // could not have grown for the reason it is about (L159).
        #expect(evaluations >= 1, Comment(rawValue:
            "a redraw above the queue evaluated its body \(evaluations) times, so this fixture never "
            + "exercised the first redraw and the count below would prove nothing"))
        #expect(derivations == 1, Comment(rawValue:
            "opening the queue over a full store and redrawing once derived it \(derivations) times "
            + "(after the mount: \(why.joined(separator: " | "))). One is the mount; a second is the first "
            + "frame's cards bought with another whole-store pass instead of adopted (#4570)"))
    }

    // #4591: shows arriving under a queue that is ALREADY mounted derive it once, the first frame's cards
    // included.
    //
    // The seed's own derivation is asked for no card, the first frame builds its cards on demand, and then
    // SwiftData's refetch after the save re-announces every row. Until #4591 that refetch had already marked
    // the held answer stale by the time the next evaluation asked for the first frame's cards, so #4570's
    // adoption was refused (it adopted only into an answer nothing had marked) and the whole store was
    // derived again with the reason `nothing this view reads`: measured on this harness 2026-10-07, every
    // run, `allProspects, prospects | nothing this view reads`. A refetch that changed nothing is served
    // (#4252), so the cards are now adopted under the same re-arm that serves it.
    //
    // This is the shape every other test here sets up in `brought(up:)`, so on main each of them started
    // from a queue that had just derived twice. #4591 offered a late refetch as the cause of its CI flakes,
    // unreproduced. #4609 measured the one that remained: a fresh store at a recycled address, below.
    @Test func showsArrivingUnderAMountedQueueDeriveItOnce() async throws {
        try await showsArriving(in: container())
    }

    // #4609: the same, over a store made at the ADDRESS of one that took a save through a second context and
    // was released, which is what an earlier test in a broad run leaves behind.
    //
    // `StoreSaveCount` kept its "this store has taken a foreign save" fact by `ObjectIdentifier`, an address,
    // so the fresh store inherited it. A store with foreign saves never has a refetch served (#4252), so the
    // save's refetch rebuilt the whole queue: `allProspects, prospects | nothing this view reads`, the exact
    // pair #4609's broad run recorded, and every saved-change test here was exposed the same way. Run alone
    // the address is never one a foreign save left, which is why the test only ever failed in company.
    @Test func showsArrivingUnderAQueueOverARecycledStoreDeriveItOnce() async throws {
        let recycled = try #require(try RecycledStore.whereAForeignSavedOneDied(AppSchema.models) { other in
            other.insert(ExcludedTown(town: "Poughkeepsie"))
        }, "UNMEASURED: no container was made at the address of a released foreign-saved one, so nothing was measured")
        try await showsArriving(in: recycled)
    }

    private func showsArriving(in c: ModelContainer) async throws {
        let h = try await host(c)
        defer { tearDown(h) }
        _ = await settle(h.hosting)
        seed(h.context)
        let why = await settle(h.hosting)

        // THE POSITIVE CONTROL. The queue must have derived for the shows at all, or the ceiling below is
        // met by a queue that never saw them (L159).
        #expect(why.count >= 1, Comment(rawValue:
            "sixty shows arriving under a mounted queue derived it \(why.count) times, so it never saw them"))
        #expect(why.count == 1, Comment(rawValue:
            "shows arriving under a mounted queue derived it \(why.count) times: \(why.joined(separator: " | ")). "
            + "One is the shows; a second is the first frame's cards bought with another whole-store pass "
            + "because the save's refetch had marked the answer before they could be adopted (#4591), or a "
            + "refetch the memo refused to serve because the store reads as foreign-saved: "
            + "\(StoreSaveCount.shared.hasForeignSaves(in: c)) (#4609)"))
    }

    // #4591: a removal that REVEALS rows derives the queue once.
    //
    // The night dismissed here is the FIRST, so it is on screen: measured 2026-10-07, this window draws six
    // cards, the first two nights, and dismissing the first draws the next night's three for the first
    // time. The change's own derivation prebuilt the six the last frame drew; the frame after it drew three
    // that pass never built; and the save's refetch then asked for them, so the queue derived the whole
    // store again for three cards, reason `nothing this view reads`, 4 runs of 4. Those cards are now
    // adopted into the answer the refetch is served, built again inside its tracking, so whatever they read
    // still marks it stale. `dismissingAWholeNightDerivesTheQueueNoMoreThanTheSaveAnnounces` dismisses a
    // night below the fold, which reveals nothing here and so could not see this.
    @Test func dismissingAVisibleNightDerivesTheQueueOnce() async throws {
        let c = try container()
        let h = try await host(c)
        defer { tearDown(h) }
        seed(h.context)
        await brought(up: h)

        let all = try prospects(h.context)
        let night = Self.night(0)
        let keys = all.filter { $0.performanceDate == night }.map(\.naturalKey)
        _ = ProspectMutations.dismissAll(keys, reason: .notAFit, dateLabel: night, nightDate: night,
                                         shows: all, context: h.context, feedback: h.feedback,
                                         undo: h.undo)
        let why = await settle(h.hosting)

        #expect(keys.count == Self.showsPerNight && all.filter { keys.contains($0.naturalKey) }
                    .allSatisfy { $0.status == .dismissed },
                "the first night was not dismissed, so nothing below was measured")
        #expect(why.count >= 1, Comment(rawValue:
            "dismissing the first night derived the queue \(why.count) times, so the queue never saw it"))
        #expect(why.count == 1, Comment(rawValue:
            "dismissing the night on screen derived the whole queue \(why.count) times: "
            + "\(why.joined(separator: " | ")). One is the change; a second is the rows it revealed, bought "
            + "with another whole-store pass instead of adopted (#4591)"))
    }

    // A TOWN renamed in place. The memo path resolved Dan's town refusals OUTSIDE its build, so only the town names
    // in its key carried a rename (#4112 closed the same gap on Sources); the engine takes the saved row in by value.
    @Test func aRefusedTownRenamedInPlaceStillReachesTheQueue() async throws {
        let c = try container()
        let h = try await host(c)
        defer { tearDown(h) }
        let town = ExcludedTown(town: "Poughkeepsie")
        h.context.insert(town)
        seed(h.context)
        await brought(up: h)

        town.town = "Hoboken"
        // #4358 slice E4d: SAVED, as `ExcludedTownEditing` saves every refusal it writes. The queue engine keeps a
        // tracker on the rows of a show, a contact and an inquiry; a small table like this one reaches it by the save,
        // which names the row, and the engine reads it again (E1a's design: "a save sees a write no tracker was armed
        // for"). The question is unchanged: the renamed town must reach the queue.
        try h.context.save()
        let why = await settle(h.hosting)

        #expect(why.count >= 1, Comment(rawValue:
            "renaming a refused town in place derived the queue \(why.count) times, so the queue is "
            + "still applying the old name (#4106)"))
    }

    // #4252: the same edit in place, but AFTER an evaluation the memo served. A served evaluation reads no
    // row field, so if nothing else keeps the body subscribed to them, the edit reaches nobody.
    @Test func anEditInPlaceAfterAServedRedrawStillReachesTheQueue() async throws {
        let c = try container()
        let h = try await host(c)
        defer { tearDown(h) }
        seed(h.context)
        await brought(up: h)

        h.tick.value += 1
        let served = await settle(h.hosting)
        #expect(served.isEmpty, Comment(rawValue:
            "the redraw derived \(served.count) time(s), so the next edit does not follow a served answer"))

        let all = try prospects(h.context)
        let target = try #require(all.first { $0.naturalKey == "row-13" })
        target.markDismissed(reason: .notAFit)
        let why = await settle(h.hosting)

        #expect(why.count == 1, Comment(rawValue:
            "an unsaved in-place dismiss after a served redraw derived the queue \(why.count) times: "
            + "\(why.joined(separator: " | ")). Zero means the screen kept the answer from before the edit"))
    }

    // #4252: and after a saved change has SETTLED, which is the case the value comparison creates. The
    // refetch's notification spent the tracking the build armed, and the comparison that served it is
    // what re-armed it; if it did not, this edit reaches nobody.
    @Test func anEditInPlaceAfterASavedChangeSettledStillReachesTheQueue() async throws {
        let c = try container()
        let h = try await host(c)
        defer { tearDown(h) }
        seed(h.context)
        await brought(up: h)

        let all = try prospects(h.context)
        let first = try #require(all.first { $0.naturalKey == "row-5" })
        ProspectMutations.dismissForReason(QueueItem(first), .notAFit, shows: all, context: h.context,
                                           feedback: h.feedback, offer: h.offer, undo: h.undo)
        let settled = await settle(h.hosting)
        #expect(settled.count == 1, Comment(rawValue:
            "the saved dismiss derived \(settled.count) times, so the edit below does not follow a "
            + "refetch served by value"))

        let second = try #require(all.first { $0.naturalKey == "row-14" })
        second.markDismissed(reason: .notAFit)
        let why = await settle(h.hosting)
        #expect(why.count == 1, Comment(rawValue:
            "an unsaved dismiss after a settled saved change derived the queue \(why.count) times: "
            + "\(why.joined(separator: " | ")). Zero means the refetch's comparison did not re-arm the "
            + "memo and the screen kept the answer from before the edit"))
    }

    // THE OTHER DIRECTION, which a memo exists to get wrong: a field edited in place and never saved must
    // still reach the queue. A key that missed it would show Dan a row that disagrees with the store,
    // which is worse than a slow screen (L40). No save, so no query notification: the only route left is
    // the model's own observation, and it must still derive.
    @Test func anEditInPlaceStillReachesTheQueueWithoutASave() async throws {
        let c = try container()
        let h = try await host(c)
        defer { tearDown(h) }
        seed(h.context)
        await brought(up: h)

        let all = try prospects(h.context)
        let target = try #require(all.first { $0.naturalKey == "row-12" })
        target.markDismissed(reason: .notAFit)
        let why = await settle(h.hosting)

        #expect(why.count == 1, Comment(rawValue:
            "an unsaved in-place dismiss derived the queue \(why.count) times. Zero means the queue "
            + "served its previous answer over a changed store; more than one is this issue's repetition: "
            + "\(why.joined(separator: " | ")) (#4106)"))
    }
}
