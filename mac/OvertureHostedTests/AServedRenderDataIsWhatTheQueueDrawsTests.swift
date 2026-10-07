import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #4106 Step V: a RenderData handed to the queue is drawn without the queue deriving one.
//
// WHAT THE SEAM IS FOR. Phase 0c.8 times the body plus a forced layout and display pass over a SERVED
// RenderData, so the derivation is outside the number (L472). That measurement is only a measurement of
// the view if the served data really does replace the derivation, and if the seam's default really is
// the production path. Both are asserted here as COUNTS, because a count is a statement about this code
// and a duration is a statement about the machine (L63, L290).
//
// THE TWO ARMS. Served: the body is evaluated and the queue derives nothing. Default: the same harness
// with no provider named derives, which is the positive control (L159) and also the proof that the
// default every other hosted test relies on is still the memo path.
@MainActor
@Suite("A served RenderData is what the queue draws (#4106 Step V)")
struct AServedRenderDataIsWhatTheQueueDrawsTests {

    // A provider that serves a prebuilt pass. Test only, which `QueueRenderDataProviderWiringTests`
    // holds the app to (L718).
    private struct Served: QueueRenderDataProvider {
        let data: QueueView.RenderData
        func servedRenderData() -> QueueView.RenderData? { data }
    }

    private static let rows = 30

    private static func night(_ n: Int) -> String {
        ScoutTestClock.day(20 + n, after: Date())
    }

    private func seed(_ ctx: ModelContext) throws -> [Prospect] {
        for n in 0..<Self.rows {
            let p = Prospect(naturalKey: "served-\(n)", groupName: "Ensemble \(n)", discipline: "music",
                             venue: "Venue \(n % 7) Hall", performanceDate: Self.night(n / 3),
                             sourceListingURL: nil, priorRelationship: "none",
                             production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 4 + (n % 5), tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .new)
            p.presenter = "Ensemble \(n) Presents"
            p.location = "New York, NY"
            ctx.insert(p)
        }
        try ctx.save()
        return try ctx.fetch(FetchDescriptor<Prospect>())
    }

    private struct Harness: View {
        let container: ModelContainer
        let provider: (any QueueRenderDataProvider)?
        @State private var deepLinkedKey: LeadDeepLink?
        @State private var deepLinkedKeys: LeadsDeepLink?

        var body: some View {
            RowsFromStore { (rows: [Prospect]) in
                if let provider {
                    QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys,
                              allProspects: rows, renderDataProvider: provider)
                } else {
                    // No provider named, exactly as every other hosted harness builds the queue.
                    QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys,
                              allProspects: rows)
                }
            }
            .modelContainer(container)
            .environment(ActionFeedback())
            .environment(DayOffOfferRequest())
            .environment(QueueUndoStack())
        }
    }

    // Hosts the harness, drives layout and display until the derivation count has gone quiet, and
    // returns how many derivations and body evaluations that took. Waits on the condition rather than a
    // fixed time (L290); the window is never ordered front, so layout and display are driven by hand
    // (#3480).
    private func drawn(_ c: ModelContainer, provider: (any QueueRenderDataProvider)?)
        async -> (derivations: Int, evaluations: Int)
    {
        let derivationsBefore = QueueRenderCounter.derivations
        let evaluationsBefore = QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: AnyView(Harness(container: c, provider: provider)))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)

        var seen = QueueRenderCounter.derivations
        var quiet = 0
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline, quiet < 40 {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let now = QueueRenderCounter.derivations
            let evaluated = QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface)
                > evaluationsBefore
            // Quiet only once the body has run at all, so a slow first layout is not read as a settled
            // queue that never derived.
            if now == seen && evaluated { quiet += 1 } else { quiet = 0 }
            seen = now
            try? await Task.sleep(for: .milliseconds(10))
        }
        return (QueueRenderCounter.derivations - derivationsBefore,
                QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface) - evaluationsBefore)
    }

    @Test func aServedRenderDataIsDrawnWithoutTheQueueDerivingOne() async throws {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let shows = try seed(c.mainContext)
        let served = QueueRenderPass.make(QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(shows), inquiries: [], orgAnswers: [],
            context: StageContext(now: Date(), geo: .none, clients: .none),
            focusedStage: .scout))
        // The fixture has to be one worth drawing, or a body that drew nothing is what was timed.
        #expect(!served.rows.isEmpty, "the served pass holds no rows, so this fixture draws nothing")

        let result = await drawn(c, provider: Served(data: served))

        #expect(result.evaluations >= 1, Comment(rawValue:
            "the queue's body never ran, so the zero below means nothing was drawn rather than that the "
            + "served RenderData replaced the derivation (L159)"))
        #expect(result.derivations == 0, Comment(rawValue:
            "the queue derived its own RenderData \(result.derivations) time(s) while one was served, so "
            + "a timing of the body over a served pass would include the derivation it exists to exclude "
            + "(#4106 Step V, L472)"))
    }

    // THE POSITIVE CONTROL, and the default every other hosted harness relies on: with no provider named,
    // the same harness derives.
    @Test func withNoProviderNamedTheQueueDerivesAsItAlwaysDid() async throws {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        _ = try seed(c.mainContext)

        let result = await drawn(c, provider: nil)

        #expect(result.evaluations >= 1, "the queue's body never ran, so this arm measured nothing")
        #expect(result.derivations >= 1, Comment(rawValue:
            "the queue drew with no provider named and derived nothing, so the default is no longer the "
            + "memo path every other hosted test assumes it is"))
    }
}
