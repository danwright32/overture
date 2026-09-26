import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
import Observation
@testable import Overture

// #4109: a card that changes position must never be drawn over its neighbours.
//
// WHAT WAS SEEN, 2026-09-21. Dan corrected a show's genre, its score dropped, and for about a second the
// card was drawn ON TOP of the card below it, with the genre picker frozen part way through closing.
//
// WHAT CAUSED IT. Every mutation that acknowledges itself (`feedback.acknowledge`) does so in the same
// turn as its write, and the acknowledgement banner animated on `feedback.revision` with an
// `.animation(_:value:)` placed on the CONTENT it overlays. Attached at `RootView`, that content is the
// whole window. So the update that re-sorted the queue was an ANIMATED update: every card that moved was
// interpolated from its old slot to its new one over 0.2s, the list around it laid out at the end state
// from the first frame. When the main thread stalled in that window (the whole-store rebuild #4106
// measures, 0.9s), the animation froze mid-flight and a card sat half way between two slots, over its
// neighbour. The transaction is the mechanism, so the transaction is what this asserts: the update that
// moves a card must carry no animation, which is the only way every frame draws each card in exactly one
// slot whatever the machine is doing (L63).
//
// WHY NOT RENDERED FRAMES. An animation interpolates what is DRAWN, never what layout reports: every
// geometry reading in a test answers with the destination, so a frame overlap check over reported frames
// passes on the defective build. A frozen mid-flight frame exists only on a live display under load, which
// is the thing a test must not depend on (L290).
@MainActor
@Suite("A moved card is never animated across its neighbours (#4109)")
struct AMovedCardIsNeverAnimatedAcrossItsNeighboursTests {

    // Every transaction that reached the queue's subtree, with whether it carried an animation.
    @MainActor final class TransactionLog {
        var animated: [String] = []
        var seen = 0
        func record(_ t: Transaction) {
            seen += 1
            if let animation = t.animation { animated.append(String(describing: animation)) }
        }
    }

    private static func night(_ n: Int) -> String {
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: Date())!
        return EasternDate.dayString(from: day)
    }

    // One night of three. The target leads on fit with no genre read; the genre correction rescoring it
    // is what moves it down, which is the move Dan made.
    private func seed(_ ctx: ModelContext) {
        let shows: [(key: String, discipline: String, fit: Int)] = [
            ("lead", "other", 10), ("second", "music", 6), ("third", "music", 5),
        ]
        for show in shows {
            let p = Prospect(naturalKey: show.key, groupName: "Ensemble \(show.key)",
                             discipline: show.discipline,
                             venue: "Venue \(show.key) Hall", performanceDate: Self.night(0),
                             sourceListingURL: nil, priorRelationship: "none",
                             production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: show.fit, tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .new)
            p.presenter = "Ensemble \(show.key) Presents"
            p.location = "New York, NY"
            ctx.insert(p)
        }
        try? ctx.save()
    }

    // RootView's arrangement, reproduced: the queue under the acknowledgement banner, which is attached
    // to the window's content exactly as `RootView` attaches it.
    private struct Harness: View {
        let container: ModelContainer
        let feedback: ActionFeedback
        let dayOffOffer: DayOffOfferRequest
        let undoStack: QueueUndoStack
        let log: TransactionLog
        @State private var deepLinkedKey: LeadDeepLink?
        @State private var deepLinkedKeys: LeadsDeepLink?

        var body: some View {
            RowsFromStore { (rows: [Prospect]) in
                QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys,
                          allProspects: rows, onConnectGmail: { })
                    .transaction { log.record($0) }
            }
            .modelContainer(container)
            .actionFeedbackBanner(feedback)
            .environment(feedback)
            .environment(dayOffOffer)
            .environment(undoStack)
        }
    }

    private struct Hosted {
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
        let context: ModelContext
        let feedback: ActionFeedback
    }

    private func host(_ c: ModelContainer, log: TransactionLog) -> Hosted {
        let feedback = ActionFeedback()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // AppKit's default releases the window while this scope still holds it (#3480).
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(Harness(container: c, feedback: feedback,
                                                              dayOffOffer: DayOffOfferRequest(),
                                                              undoStack: QueueUndoStack(), log: log)))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        return Hosted(window: window, hosting: hosting, context: c.mainContext, feedback: feedback)
    }

    // Until the queue's derivation count goes quiet, driving layout and display on every poll because
    // this window is never ordered front (#3480). Never a fixed sleep (L290).
    private func settle(_ hosting: NSView, quietPolls: Int = 40) async -> Int {
        var seen = QueueRenderCounter.derivations
        var derived = 0
        var quiet = 0
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            if QueueRenderCounter.derivations > seen {
                derived += QueueRenderCounter.derivations - seen
                seen = QueueRenderCounter.derivations
                quiet = 0
            } else {
                quiet += 1
            }
            if quiet >= quietPolls { return derived }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return derived
    }

    @Test func correctingAGenreThatMovesTheCardDoesNotAnimateTheMove() async throws {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let log = TransactionLog()
        let h = host(c, log: log)
        defer { h.window.close() }
        seed(h.context)
        let appeared = await settle(h.hosting)
        #expect(appeared > 0, "the queue never derived while appearing, so nothing below was measured (L98)")

        let all = try h.context.fetch(FetchDescriptor<Prospect>())
        let target = try #require(all.first { $0.naturalKey == "lead" })
        let before = log.seen
        log.animated = []
        let revisionBefore = h.feedback.revision
        // The genre editor's Save, through the mutation it calls: one write, one acknowledgement.
        ProspectMutations.correctClassification(QueueItem(target), discipline: .notALivePerformance,
                                                prospects: all, context: h.context, feedback: h.feedback)
        let derived = await settle(h.hosting)

        // POSITIVE CONTROLS FIRST. Each of these is a fixture where the defect could not have happened:
        // a card that did not move, a queue that did not react, a banner that was never raised (L159).
        let neighbours = all.filter { $0.naturalKey != "lead" }.map(\.fitScore)
        #expect(neighbours.allSatisfy { target.fitScore < $0 }, Comment(rawValue:
            "the correction left the target at fit \(target.fitScore) against neighbours \(neighbours), so "
            + "the card did not move and this measured nothing"))
        #expect(h.feedback.revision > revisionBefore,
                "the correction raised no acknowledgement, so the banner's animation was never in play")
        #expect(derived > 0, "the queue never re-derived after the correction, so no card moved on screen")
        #expect(log.seen > before, "no update reached the queue after the correction, so the probe saw nothing")

        #expect(log.animated.isEmpty, Comment(rawValue:
            "the update that moved the card carried an animation (\(log.animated.joined(separator: ", "))), "
            + "so the card is interpolated between its old slot and its new one and is drawn over its "
            + "neighbour for as long as the main thread stalls mid-flight (#4109)"))
    }
}
