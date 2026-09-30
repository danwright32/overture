import Testing
import Foundation

// #4322: a card SwiftUI skips keeps the action closures an earlier body built, and those captured that
// body's copy of `QueueView`, whose `allProspects` is the list of shows as it stood then. So the actions read
// the shows through `LiveProspects`, one object every copy shares and every body refreshes before drawing,
// and a merge that replaced a row since cannot receive a write meant for the deleted one (#3690's failure).
//
// A SOURCE GUARD, and it says so: pressing a control inside a hosted card is not something the harness can
// do, so what is held is the wiring, in the two places it lives. Each needle is scoped to the declaration it
// is about rather than searched over the whole 2,600 line file, which could answer from anywhere (L135).
@Suite("Queue actions read the shows through the live box (#4322)")
struct QueueActionsReadLiveProspectsGuardTests {
    private let queueView = SourceGuardHelper.source("Overture/UI/QueueView.swift")

    @Test func theActionsListIsReadThroughTheLiveBox() throws {
        let prospects = try #require(SourceGuardHelper.propertyBody(
            "private var prospects: [Prospect] {", in: queueView), "the actions' list of shows was not found")
        #expect(prospects.contains("liveProspects.rows"), Comment(rawValue:
            "the actions read `allProspects` directly again, so a closure from a skipped card acts on an old list"))
        #expect(!prospects.contains("allProspects"))
    }

    @Test func everyBodyRefreshesTheBoxBeforeDrawing() throws {
        let body = try #require(SourceGuardHelper.propertyBody("var body: some View {", in: queueView),
                                "QueueView's body was not found")
        let adopt = try #require(body.range(of: "liveProspects.adopt(allProspects)"), Comment(rawValue:
            "QueueView's body no longer hands the box the shows it was given, so the box goes stale"))
        let pass = try #require(body.range(of: "makeRenderData()"))
        #expect(adopt.lowerBound < pass.lowerBound, "the box is refreshed after the body has started drawing")
    }
}
