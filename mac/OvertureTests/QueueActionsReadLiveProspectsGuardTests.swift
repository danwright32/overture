import Testing
import Foundation

// #4322: a card SwiftUI skips keeps the action closures an earlier body built, and those captured that
// body's copy of `QueueView`. So the actions must read the shows through an object every copy shares, or a merge
// that replaced a row since can receive a write meant for the deleted one (#3690's failure).
//
// #4358 slice E4d: that object is the queue engine now. It used to be `LiveProspects`, a box every body refreshed
// from the rows RootView handed down; the engine holds the shows by identity and every copy of the view holds the
// same engine, so there is nothing to refresh and an action resolves the show it pressed through the engine
// (`ShowIdentity`), with the engine's out of step and unreadable refusals.
//
// A SOURCE GUARD, and it says so: pressing a control inside a hosted card is not something the harness can
// do, so what is held is the wiring. Each needle is scoped to the declaration it is about rather than searched
// over the whole file, which could answer from anywhere (L135).
@Suite("Queue actions read the shows through the queue engine (#4322, #4358)")
struct QueueActionsReadLiveProspectsGuardTests {
    private let queueView = SourceGuardHelper.source("Overture/UI/QueueView.swift")

    @Test func theActionsListIsReadThroughTheEngine() throws {
        let prospects = try #require(SourceGuardHelper.propertyBody(
            "private var prospects: [Prospect] {", in: queueView), "the actions' list of shows was not found")
        #expect(prospects.contains("engine.everyShow"), Comment(rawValue:
            "the actions' list is not the engine's, so a closure from a skipped card can act on an old list"))
    }

    // Every action hands the engine itself as the resolver, never the list above: an array resolves by walking it
    // and knows nothing of a row the engine has faulted (`ShowIdentity.Refusal.outOfStep`).
    @Test func everyActionResolvesThroughTheEngine() {
        let code = SwiftSource.scannableLines(in: queueView).map(\.code).joined(separator: "\n")
        #expect(code.contains("shows: engine,"), "no action hands the engine as its resolver, so this found nothing")
        for needle in ["shows: prospects", "in: prospects)", "prospects.show(for:", "resolve(in: prospects)",
                       "LiveProspects", "liveProspects"] {
            #expect(!code.contains(needle), Comment(rawValue:
                "QueueView resolves a press through `\(needle)` rather than the engine, so an out of step show "
                + "is acted on and its stale fields saved over the stored ones (#4358 plan item 11)"))
        }
    }
}
