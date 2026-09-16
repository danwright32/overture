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
// `ImageRenderer` is the way round it, and it realizes rows where the other rig realizes none. That makes
// it useless for asking what a scroll costs and right for asking whether a drawn row reaches the store at
// all, which is a yes-or-no question.
//
// #3833 CORRECTED WHAT THIS SAYS, and the correction is the point. It used to say the renderer "has no
// viewport, so it renders the WHOLE content and realizes every row rather than a screenful". Measured at
// frame width 900 and height 4000 on 2026-09-11: a 6 show corpus realized 6 of 6, and a 96 show corpus
// realized 24 of 96. So the claim held at fixture scale and failed at anything like production scale,
// which is the direction that matters, because a test written on the strength of it would measure a
// quarter of what its author believed and report the result as complete (L354, L101).
//
// What is true is narrower and is what this rig may be used for: it realizes as many rows as FIT THE
// FRAME it is given, and no more. The corpus here is six, and `theRigRealizesEveryRowOfThisCorpus` below
// MEASURES that all six are realized rather than leaving it to this paragraph, so the day a change makes
// this rig draw a fraction of six the suite says so instead of quietly answering about part of it.
//
// A test that needs every row of a LARGER corpus drawn cannot have it from here. Give the frame a height
// that fits them and measure the realized count, the way that test does.
@MainActor
@Suite("A row that really draws asks the pass's store for its card (#3654)")
struct ADrawnRowReallyAsksTheStoreTests {
    private static let rows = 6

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory([Prospect.self, Recipient.self, Inquiry.self, OrgReachabilityAnswer.self, WatchedSource.self, RefusedContactAddress.self, PromotedProducer.self, DemotedHouse.self])
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
            // #3846: QueueView takes its rows rather than querying the table itself, because RootView
            // already holds an identical bare query and two of them share nothing. This harness plays
            // RootView's part, so what is measured below is still the store-to-screen path.
            RowsFromStore { (rows: [Prospect]) in
                QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys,
                          allProspects: rows)
            }
            .modelContainer(container)
            .environment(feedback)
            .environment(dayOffOffer)
        }
    }

    // #3833: what one draw of this rig actually did, so a claim about it can be ASSERTED rather than read
    // off a comment. `queueItems` is the number of cards the render path built, which is how many rows
    // were realized; `queueRows` is how many the pass derived, which is the whole corpus.
    private struct Drawn {
        let rendered: Bool
        let rowsDerived: Int
        let cardsRealized: Int
    }

    private func draw(_ c: ModelContainer, height: CGFloat) -> Drawn {
        var image: NSImage?
        let work = QueueRenderPass.WorkTally.measure {
            let renderer = ImageRenderer(content: Harness(container: c).frame(width: 900, height: height))
            renderer.scale = 1
            image = renderer.nsImage
        }
        return Drawn(rendered: image != nil, rowsDerived: work.queueRows, cardsRealized: work.queueItems)
    }

    // #3833: the header's claim, measured, rather than a sentence nothing checks.
    //
    // The rig realizes as many rows as fit the frame. At this corpus and this frame every row fits, and
    // THAT is what makes the yes-or-no question below answerable about the whole of it. If a change ever
    // makes this rig draw a fraction of six, this says so instead of the test above quietly answering
    // about part of the corpus and reading as complete (L354, L101).
    @Test func theRigRealizesEveryRowOfThisCorpus() throws {
        let c = try container()
        seed(ModelContext(c))
        let drawn = draw(c, height: 2400)

        #expect(drawn.rendered, "nothing rendered at all, so everything below would be vacuous (L98)")
        #expect(drawn.rowsDerived >= Self.rows, Comment(rawValue:
            "the pass derived \(drawn.rowsDerived) rows from a corpus of \(Self.rows), so the corpus "
            + "never reached the pass and the realized count below is about nothing"))
        #expect(drawn.cardsRealized >= Self.rows, Comment(rawValue:
            "this rig realized \(drawn.cardsRealized) of \(Self.rows) rows, so it is drawing a "
            + "FRACTION of its corpus and every test resting on it is answering about that fraction "
            + "while reading as complete (#3833). Give the frame a height that fits them all, or say in "
            + "the test what the partial count means"))

        // Printed the way FeltWaitCostTests prints its own, so the figure lives in every run's output
        // rather than only in a comment that would go stale silently (L32, L316).
        print("drawn-row-cards-realized: \(drawn.cardsRealized) card(s) from a corpus of "
              + "\(drawn.rowsDerived) row(s), at frame 900x2400")
    }

    // THE test. Drawing the queue builds cards, and it builds them from the render path rather than from
    // the pass: the pass is asked for nothing on the first frame, because nothing has been drawn yet.
    @Test func drawingTheQueueBuildsCardsFromTheRenderPath() throws {
        let c = try container()
        seed(ModelContext(c))

        let drawn = draw(c, height: 2400)

        #expect(drawn.rendered, "nothing rendered at all, so everything below would be vacuous (L98)")
        // The positive control FIRST, because every claim under it is about a render that happened. A
        // pass that ran and a screen that drew nothing produce the same silence otherwise (L159).
        #expect(drawn.rowsDerived > 0, "the pass built no rows, so the queue never derived anything")
        // THE claim. Cards exist, and every one of them was built while the body was drawing: the first
        // frame asks the pass for nothing, because the registry is empty until something has been drawn.
        #expect(drawn.cardsRealized > 0, Comment(rawValue:
            "the queue drew and not one card was built, so a drawn row is getting its content from "
            + "somewhere other than the store, or the rows are not being realized and this rig has "
            + "stopped being able to answer the question it exists for"))
    }
}
