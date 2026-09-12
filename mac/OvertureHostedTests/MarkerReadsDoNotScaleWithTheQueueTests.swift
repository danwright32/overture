import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #3646: drawing the queue must not read a marker file per card and per date heading.
//
// THE MEASUREMENT, as opposed to the source guards in `MarkerReadsOnTheRenderPathTests`. Those say where
// the answer has to come from and are answered by a spelling; this one draws a real queue at two sizes
// and asks what it cost. A source guard cannot see a marker read that arrives through a new helper, a new
// subview or a call the pass makes on the row's behalf, and #3646 is precisely a cost nobody put there on
// purpose: `checkRunning` was a computed property, so at the call site it read as free.
//
// The rig is `ADrawnRowReallyAsksTheStoreTests`', for its reason. The borderless window the other hosted
// queue tests use realizes no rows at all (`FeltWaitCostTests` prints `felt-wait-cards-drawn: 0` every
// run), so it cannot answer a per-row question. `ImageRenderer` has no viewport, so it renders the WHOLE
// content and realizes every row, which is exactly wrong for asking what a scroll costs and exactly right
// for asking whether the cost grows with the queue.
//
// The claim is a COMPARISON rather than a pinned number, deliberately. What a pass legitimately reads is
// the two run markers plus the reply run's, and how many times SwiftUI evaluates a body is not this
// suite's business; a pinned total would go red for a reason unrelated to the rule (L103). What must be
// true is that four times the shows over four times the dates cost the same reads. Before this issue the
// large corpus paid one extra `stat` per card and one per date heading.
@MainActor
@Suite("Drawing the queue costs the same marker reads however many shows it holds (#3646)")
struct MarkerReadsDoNotScaleWithTheQueueTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        OrgReachabilityAnswer.self, WatchedSource.self,
                                        RefusedContactAddress.self, PromotedProducer.self,
                                        DemotedHouse.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // `perDate` shows on each of `dates` days, so both dimensions of the defect move together: the card
    // read and the date-heading read.
    private func seed(_ ctx: ModelContext, dates: Int, perDate: Int) {
        for day in 0..<dates {
            // Dated FROM the clock rather than pinned, so the shows stay inside the queue's own lead-time
            // window whatever year this runs in (L130).
            let date = EasternDate.dayString(from: Date().addingTimeInterval(Double(20 + day) * 86_400))
            for n in 0..<perDate {
                let key = "row-\(day)-\(n)"
                let p = Prospect(naturalKey: key, groupName: "Ensemble \(day)-\(n)", discipline: "music",
                                 venue: "Venue \(n) Hall", performanceDate: date,
                                 sourceListingURL: nil, priorRelationship: "none", production: "self",
                                 profile: "strong", coverage: "likely_uncovered", fitScore: 6,
                                 tier: "mid", fitReason: "r", matchedClientName: nil,
                                 possibleMatchSource: nil, possibleMatchName: nil)
                p.presenter = "Ensemble \(day)-\(n) Presents"
                p.location = "New York, NY"
                ctx.insert(p)
            }
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

    private struct Drawn {
        let markerReads: Int
        let rowsDerived: Int
        let cardsBuilt: Int
        let rendered: Bool
    }

    private func draw(dates: Int, perDate: Int) throws -> Drawn {
        let c = try container()
        seed(ModelContext(c), dates: dates, perDate: perDate)

        var image: NSImage?
        var work: QueueRenderPass.WorkTally?
        let markers = DetachedRunner.MarkerReadTally.measure {
            work = QueueRenderPass.WorkTally.measure {
                let renderer = ImageRenderer(
                    content: Harness(container: c).frame(width: 900, height: 4000))
                renderer.scale = 1
                image = renderer.nsImage
            }
        }
        return Drawn(markerReads: markers.reads, rowsDerived: work?.queueRows ?? 0,
                     cardsBuilt: work?.queueItems ?? 0, rendered: image != nil)
    }

    @Test func fourTimesTheQueueCostsTheSameMarkerReads() throws {
        let small = try draw(dates: 3, perDate: 2)
        let large = try draw(dates: 12, perDate: 8)

        // The positive controls FIRST, all three of them, because a render that drew nothing and a render
        // that read no marker per row are the same silence otherwise (L98, L159).
        #expect(small.rendered && large.rendered, "nothing rendered, so every claim below is vacuous")
        #expect(large.rowsDerived > small.rowsDerived,
                "the two passes derived the same number of rows, so the corpus never grew")
        #expect(large.cardsBuilt > small.cardsBuilt, Comment(rawValue:
            "the large queue built no more cards than the small one, so its rows are not being realized "
            + "and this rig has stopped being able to answer the question it exists for"))

        // THE claim. 96 shows over 12 dates cost what 6 shows over 3 dates cost. Before this, the large
        // one paid 96 extra reads for the cards and 12 more for the headings, every pass.
        #expect(large.markerReads == small.markerReads, Comment(rawValue:
            "drawing 96 shows read \(large.markerReads) marker files and drawing 6 read "
            + "\(small.markerReads), so a marker is being read per card or per date heading again (#3646)"))
        // And a pass really does read its markers, so the equality above is not two zeros agreeing.
        #expect(small.markerReads > 0)
    }
}
