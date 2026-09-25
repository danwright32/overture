import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
import Observation
@testable import Overture

// #4113: opening a menu or popover on one card must not re-evaluate the queue around it.
//
// WHAT THE ISSUE SUSPECTED. Dan opened a card's genre control on 2026-09-21 and dismissed it without
// choosing anything, and the freeze log recorded 1.62s and 1.17s. The write-up guessed that the open
// state invalidated the surrounding tree (state held above the card, a binding the list observes).
//
// WHAT THE RECORD SAYS, re-checked 2026-09-25. Both stall records carry `passes=0` and `rootDraws=0`.
// The installed build was from 2026-09-20, before #4255's render memo, so on that build EVERY evaluation
// of `QueueView.body` ran `makeRenderData` and bumped `passes`. A zero there means neither `RootView` nor
// `QueueView` evaluated its body during the episode at all. The sample's cumulative reading agrees: of
// the 486 samples under the one window layout, 165 are `PopoverBridge.updatePopover` and
// `NSPopover showRelativeToRect` (building the popover window), about 96 are SwiftUI sizing the stacks
// already on screen, and only 51 are any body evaluation at all.
//
// WHAT THIS SUITE HOLDS. A popover or a menu changes the WINDOW around the card: its key state moves to
// the popover and back, which SwiftUI hands every view as `controlActiveState`. That is the one channel
// by which opening something on one card reaches every other view in the window without any of them
// reading the card's state, so it is the channel this measures. Measured here over 60 shows: flipping it
// re-evaluates neither the queue's body nor any card's. A card that starts reading window activity would
// re-evaluate every realised card on every popover and menu, and this goes red.
//
// WHAT IT CANNOT DO, measured rather than assumed: press the genre control itself. The hosted window is
// never ordered front (#3480), and SwiftUI builds no accessibility tree for it, so a walk of the hosting
// view's accessibility children finds no labels at all and there is nothing to press. The card's own
// open state is private `@State`, which only that card's body reads, and nothing above the card reads a
// preference or a geometry (no `onPreferenceChange` or `GeometryReader` on the queue's path).
//
// A COUNT, NOT A DURATION, for the reason `OneChangeDerivesTheQueueOnceTests` gives (L63, L290).
@MainActor
@Suite("Opening a card's menu stays in the card (#4113)")
struct OpeningACardMenuStaysInTheCardTests {

    private static let rows = 60
    private static let showsPerNight = 3

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

    // The window's activity, as SwiftUI hands it down when a popover takes key and gives it back.
    @Observable final class WindowActivity { var key = true }

    // Applies the activity in a view of its own, holding the queue as a value it was given, so a flip
    // re-evaluates THIS body and nothing else of the harness's. Written inline in the harness body, the
    // flip would rebuild the queue's closure input and measure the harness rather than the channel (L472).
    private struct ActiveState<Content: View>: View {
        let activity: WindowActivity
        let content: Content
        var body: some View {
            content.environment(\.controlActiveState, activity.key ? .key : .inactive)
        }
    }

    private struct Harness: View {
        let container: ModelContainer
        let feedback: ActionFeedback
        let dayOffOffer: DayOffOfferRequest
        let undoStack: QueueUndoStack
        let activity: WindowActivity
        @State private var deepLinkedKey: LeadDeepLink?
        @State private var deepLinkedKeys: LeadsDeepLink?

        var body: some View {
            ActiveState(activity: activity, content: RowsFromStore { (rows: [Prospect]) in
                QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys,
                          allProspects: rows, onConnectGmail: {})
            })
            .modelContainer(container)
            .environment(feedback)
            .environment(dayOffOffer)
            .environment(undoStack)
        }
    }

    private static func cardTotal() -> Int { QueueRenderCounter.cardBodyCounts().values.reduce(0, +) }
    private static func queueTotal() -> Int {
        QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface)
    }

    // Waits until neither count has moved for a stretch of polls, rather than for a fixed time (L290).
    // Layout and display are driven on every poll because this window is never ordered front (#3480).
    private func settle(_ hosting: NSView) async {
        var last = -1
        var quiet = 0
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let now = Self.queueTotal() + Self.cardTotal()
            if now == last { quiet += 1 } else { quiet = 0; last = now }
            if quiet >= 40 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aPopoverTakingTheWindowReEvaluatesNeitherTheQueueNorAnyCard() async throws {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let activity = WindowActivity()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // AppKit's default releases the window while this scope still holds it (#3480).
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: AnyView(Harness(container: c, feedback: ActionFeedback(),
                                                              dayOffOffer: DayOffOfferRequest(),
                                                              undoStack: QueueUndoStack(),
                                                              activity: activity)))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        let cardsBeforeSeed = Self.cardTotal()
        seed(c.mainContext)
        await settle(hosting)

        // THE POSITIVE CONTROL FIRST: cards were drawn and counted. Without it a zero below would be a
        // queue that never drew a card, which is the fixture where the defect cannot happen (L159).
        #expect(Self.cardTotal() > cardsBeforeSeed,
                "no card body was evaluated while the queue appeared, so the counts below measure nothing")

        let queueBefore = Self.queueTotal()
        let cardsBefore = QueueRenderCounter.cardBodyCounts()

        // The popover takes key, then gives it back.
        activity.key = false
        await settle(hosting)
        activity.key = true
        await settle(hosting)

        let queueEvaluations = Self.queueTotal() - queueBefore
        let cardsEvaluated = QueueRenderCounter.cardBodyCounts()
            .filter { $0.value != (cardsBefore[$0.key] ?? 0) }.keys.sorted()

        #expect(queueEvaluations == 0,
                "the window changing key state evaluated the queue's body again, so every popover or menu on any card re-lays out the whole queue")
        #expect(cardsEvaluated.isEmpty,
                "the window changing key state re-evaluated cards that read nothing from it")
        // Named separately so a red run says WHICH cards and how many times, which the literal above cannot.
        if !cardsEvaluated.isEmpty || queueEvaluations != 0 {
            Issue.record("queue body +\(queueEvaluations); cards re-evaluated: \(cardsEvaluated)")
        }
    }
}
