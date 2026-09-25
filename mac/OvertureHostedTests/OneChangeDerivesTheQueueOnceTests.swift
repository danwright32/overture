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
// WHAT THE FIX DOES, then. `QueueView` now derives through a `ScopeMemo`, so an evaluation that changes
// nothing the pass reads is served the answer it already has. That removes every derivation provoked by
// something other than the store (a banner, an undo entry, a sheet, `RootView` redrawing), which is
// `aRedrawWithNoDataChangeDerivesNothing` below. It does NOT remove the saved write's second derivation,
// for the reason above, and the three saved-change tests pin that at two rather than pretending
// otherwise, so it cannot become three. Taking it to one needs a derivation that can say WHICH shows
// changed, which is the incremental half #4106 names as its direction and is recorded there.
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

    // One saved change: its own derivation, and the one SwiftData's refetch re-announces. See the header
    // for the measurement, and #4106 for what taking this to one needs.
    private static let allowedDerivationsForOneSavedChange = 2

    private static func night(_ n: Int) -> String {
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: Date())!
        return EasternDate.dayString(from: day)
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
        @State private var deepLinkedKey: LeadDeepLink?
        @State private var deepLinkedKeys: LeadsDeepLink?

        var body: some View {
            // RootView's part, played here: the rows come from one whole-table query and are handed down,
            // which is the path whose second notification this suite is about (#3846).
            // `tick` is read HERE, above the queue, and handed down inside a closure, which is what
            // `RootView` does with every closure it passes: a fresh closure is a changed input, so each
            // redraw above re-evaluates the queue's body with no data behind it (#1930's "nothing this
            // view reads", reproduced on purpose).
            let n = tick.value
            RowsFromStore { (rows: [Prospect]) in
                QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys,
                          allProspects: rows, onConnectGmail: { _ = n })
            }
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

    private func host(_ c: ModelContainer) -> Hosted {
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
                                                              tick: tick)))
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
        let h = host(c)
        defer { h.window.close() }
        seed(h.context)
        await brought(up: h)

        let all = try prospects(h.context)
        let target = try #require(all.first { $0.naturalKey == "row-5" })
        ProspectMutations.dismissForReason(QueueItem(target), .notAFit, prospects: all, context: h.context,
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
        let h = host(c)
        defer { h.window.close() }
        seed(h.context)
        await brought(up: h)

        let all = try prospects(h.context)
        let target = try #require(all.first { $0.naturalKey == "row-9" })
        ProspectMutations.correctClassification(QueueItem(target), discipline: .theater, prospects: all,
                                                context: h.context, feedback: h.feedback)
        let why = await settle(h.hosting)

        #expect(target.discipline == "theater", "the correction did not land, so nothing below was measured")
        #expect(why.count >= 1, Comment(rawValue:
            "correcting a genre derived the queue \(why.count) times, so the queue never saw the edit"))
        #expect(why.count <= Self.allowedDerivationsForOneSavedChange, Comment(rawValue:
            "correcting ONE show's genre derived the whole queue \(why.count) times: "
            + "\(why.joined(separator: " | ")) (#4106)"))
    }

    // A whole night, through `dismissAll`, the mutation the night's Dismiss confirmation calls. Several
    // rows change in one write, and that must still be one derivation rather than one per row.
    @Test func dismissingAWholeNightDerivesTheQueueNoMoreThanTheSaveAnnounces() async throws {
        let c = try container()
        let h = host(c)
        defer { h.window.close() }
        seed(h.context)
        await brought(up: h)

        let all = try prospects(h.context)
        let night = Self.night(4)
        let keys = all.filter { $0.performanceDate == night }.map(\.naturalKey)
        #expect(keys.count == Self.showsPerNight, Comment(rawValue: "the fixture's night holds "
                + "\(keys.count) shows, not the \(Self.showsPerNight) it was built with"))
        _ = ProspectMutations.dismissAll(keys, reason: .notAFit, dateLabel: night, nightDate: night,
                                         prospects: all, context: h.context, feedback: h.feedback,
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
    @Test func aRedrawWithNoDataChangeDerivesNothing() async throws {
        let c = try container()
        let h = host(c)
        defer { h.window.close() }
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

    // THE OTHER DIRECTION, which a memo exists to get wrong: a field edited in place and never saved must
    // still reach the queue. A key that missed it would show Dan a row that disagrees with the store,
    // which is worse than a slow screen (L40). No save, so no query notification: the only route left is
    // the model's own observation, and it must still derive.
    @Test func anEditInPlaceStillReachesTheQueueWithoutASave() async throws {
        let c = try container()
        let h = host(c)
        defer { h.window.close() }
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
