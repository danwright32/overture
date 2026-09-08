import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #3654: a row that really draws really asks the store for its card.
//
// WHY THIS EXISTS AND WHY IT IS AWKWARD. Everything else about the narrowing is checked against the pass
// or against the source: `CardsOnlyForWhatRendersTests` drives the store directly, and
// `RenderPathGetsCardsFromTheStoreTests` holds the shape (no array of cards on `RenderData`, one
// row-request site, a registry the pass reads and writes). None of that is the app DRAWING. Built is not
// wired, and wired is not proven (L3).
//
// The rig every other hosted queue test uses cannot do it. Its window is borderless and deliberately
// never ordered front, because ordering it front crashes the shared app host (#3480), and its
// `LazyVStack` therefore realizes no rows at all: `FeltWaitCostTests` prints
// `felt-wait-cards-drawn: 0` on every run, which is that fact rather than a defect.
//
// `ImageRenderer` is the way round it, and the reason it works is the reason it is not a substitute for
// the other rig: it has no viewport, so it renders the WHOLE content and realizes every row rather than a
// screenful. That makes it useless for asking what a scroll costs and exactly right for asking whether a
// drawn row reaches the store at all, which is a yes-or-no question. The corpus is small on purpose,
// because this one renders all of it.
@MainActor
@Suite("A row that really draws asks the pass's store for its card (#3654)")
struct ADrawnRowReallyAsksTheStoreTests {
    private static let rows = 6

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        OrgReachabilityAnswer.self, WatchedSource.self,
                                        RefusedContactAddress.self, PromotedProducer.self,
                                        DemotedHouse.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func seed(_ ctx: ModelContext) {
        for n in 0..<Self.rows {
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n)", discipline: "music",
                             venue: "Venue \(n) Hall",
                             // Dated FROM the clock rather than pinned, so the shows stay inside the
                             // queue's own lead-time window whatever year this runs in (L130).
                             performanceDate: EasternDate.dayString(
                                 from: Date().addingTimeInterval(Double(30 + n) * 86_400)),
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil)
            p.presenter = "Ensemble \(n) Presents"
            p.location = "New York, NY"
            ctx.insert(p)
        }
        try? ctx.save()
    }

    private struct Harness: View {
        let container: ModelContainer
        @State private var deepLinkedKey: LeadDeepLink?
        @State private var deepLinkedKeys: LeadsDeepLink?
        @State private var feedback = ActionFeedback()
        @State private var dayOffOffer = DayOffOfferRequest()

        var body: some View {
            QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys)
                .modelContainer(container)
                .environment(feedback)
                .environment(dayOffOffer)
        }
    }

    // THE test. Drawing the queue builds cards, and it builds them from the render path rather than from
    // the pass: the pass is asked for nothing on the first frame, because nothing has been drawn yet.
    @Test func drawingTheQueueBuildsCardsFromTheRenderPath() throws {
        let c = try container()
        seed(ModelContext(c))

        var image: NSImage?
        let work = QueueRenderPass.WorkTally.measure {
            let renderer = ImageRenderer(content: Harness(container: c).frame(width: 900, height: 2400))
            renderer.scale = 1
            image = renderer.nsImage
        }

        #expect(image != nil, "nothing rendered at all, so everything below would be vacuous (L98)")
        // The positive control FIRST, because every claim under it is about a render that happened. A
        // pass that ran and a screen that drew nothing produce the same silence otherwise (L159).
        #expect(work.queueRows > 0, "the pass built no rows, so the queue never derived anything")
        // THE claim. Cards exist, and every one of them was built while the body was drawing: the first
        // frame asks the pass for nothing, because the registry is empty until something has been drawn.
        #expect(work.queueItems > 0, Comment(rawValue:
            "the queue drew and not one card was built, so a drawn row is getting its content from "
            + "somewhere other than the store, or the rows are not being realized and this rig has "
            + "stopped being able to answer the question it exists for"))
    }
}
