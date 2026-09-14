import Testing
import Foundation

// #3884: the scout's per event classify and match loop does not run on the main actor.
//
// `ScoutService` is `@MainActor` and `apply` is synchronous, so one source's whole match pass was one
// uninterrupted block of main thread work with the window unable to draw. Measured over the 127 second
// scout window of 2026-09-13 22:25:05 EDT: the freeze log recorded 97.4 seconds of main thread stall
// inside it, 77% of the window, and only 12.5% of that was inside any counted render pass. The longest
// single stall was 27.2 seconds. A macOS CPU resource report over the same window independently put 16 of
// its 22 microstackshot samples under `ScoutService.apply`, 15 of those inside
// `HistoryMatch.matchRelationship`.
//
// WHAT THE RUNTIME TEST CAN AND CANNOT SEE. It runs the pure pass and asserts it was NOT on the main
// actor, which is the property that matters and the one a plain `Task` would silently fail: a `Task`
// started from a `@MainActor` function inherits the main actor and would run the loop exactly where it
// runs today while reading as though it had moved (L3). What it cannot reach is `ScoutService` itself,
// which needs a `ModelContext`, so the wiring is asserted from the source beside it.
@Suite("The scout's match loop leaves the main actor (#3884)")
struct TheMatchLoopLeavesTheMainActorTests {

    private func event(_ title: String) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: "\(title) Presents", venue: "Carnegie Hall",
                       performanceDate: "2027-03-14", sourceUrl: nil, location: "New York, NY")
    }

    // THE PRIMITIVE the production path stands on, measured rather than assumed: a detached task really
    // does leave the main thread here, and a plain `Task` from a `@MainActor` caller really does not.
    //
    // `pthread_main_np()` rather than `Thread.isMainThread`, which Swift 6 makes unavailable from an
    // async context. `MainActor.assertIsolated` is no good either: it TRAPS rather than failing, so a
    // regression would crash the run instead of naming itself (L445's neighbour).
    //
    // This is the half a test in this target can reach. `ScoutService` needs a `ModelContext`, so that
    // the production entry point uses this primitive is asserted from the source below, and the header
    // says so rather than implying this measures the scout itself (L400).
    @MainActor
    @Test func aDetachedTaskLeavesTheMainThreadAndAPlainOneDoesNot() async {
        #expect(pthread_main_np() != 0, "this test is not on the main thread, so it proves nothing")

        let detachedLeft = await Task.detached { pthread_main_np() == 0 }.value
        #expect(detachedLeft, Comment(rawValue:
            "a detached task ran on the main thread, so this machine cannot tell the two apart and "
            + "nothing below means anything"))

        // THE TRAP THIS EXISTS FOR, measured in the same fixture so the contrast is not a claim: a plain
        // Task started here INHERITS the main actor, so writing one would leave the loop exactly where it
        // is while reading as though it had moved (L3).
        let plainStayed = await Task { pthread_main_np() != 0 }.value
        #expect(plainStayed, Comment(rawValue:
            "a plain Task from a @MainActor caller did NOT stay on the main actor here, so the source "
            + "guard below is guarding against something this machine does not do"))
    }

    // And the pass really classifies when reached that way, so the equality below is not two empties
    // agreeing (L98, L159).
    @Test func theDetachedPassActuallyClassifies() async {
        let result = await ScoutClassify.offTheCallersActor(
            events: [event("Aurora Quartet")], clients: [], history: [],
            venueBrands: .none, sourceIds: ["s"])
        #expect(!result.prospects.isEmpty,
                "the detached pass produced no prospect, so it measured nothing")
    }

    // Identical results whichever way it is reached, which is what lets `apply` keep classifying inline
    // for its 111 existing callers while the scout hands a pass in (L263).
    @Test func theInlinePassAndTheDetachedOneAgree() async {
        let events = [event("Aurora Quartet"), event("Brooklyn Art Song Society")]
        let inline = ScoutClassify.run(events: events, clients: [], history: [],
                                       venueBrands: .none, sourceIds: ["s"])
        let detached = await ScoutClassify.offTheCallersActor(events: events, clients: [], history: [],
                                                             venueBrands: .none, sourceIds: ["s"])
        #expect(inline == detached)
        #expect(!inline.prospects.isEmpty, "both agreed on nothing, so this measured nothing")
    }

    // The counts are kept apart on the way back, because they are kept apart downstream: `skipped` is
    // every decision not to pursue and `suppressedOrgs` is only the ones somebody asked Dan to stop.
    @Test func theResultCarriesBothCountsSeparately() {
        let result = ScoutClassify.run(events: [event("Aurora Quartet")], clients: [], history: [],
                                       venueBrands: .none, sourceIds: ["s"])
        #expect(result.skipped >= 0)
        #expect(result.suppressedOrgs.count <= result.skipped,
                "an org was reported as suppressed without being counted as skipped")
    }

    // THE WIRING, which no runtime test in this target can reach: `ScoutService` needs a `ModelContext`.
    // Asserted from the source, and the three claims are the three ways this could be built and do
    // nothing (L3).
    @Test func theScoutGoesThroughTheOffActorEntryPoint() {
        let source = SourceGuardHelper.source("Overture/Integration/ScoutService.swift")
        #expect(!source.isEmpty, "ScoutService.swift could not be read, so this measured nothing")

        let sweepsOffTheActor = SourceGuardHelper.containsCode("await applySweepOffTheActor(", in: source)
        #expect(sweepsOffTheActor, Comment(rawValue:
            "runNative calls applySweep directly again, so the whole match pass is back on the main "
            + "actor and the window cannot draw while a source is matched (#3884)"))

        // The corpus read is LAZY on the pre-classified path. Reading it there anyway would add a whole
        // table fetch, measured at 158.8 ms over 1,238 rows, to the very block this shortens.
        let readsTheCorpusLazily = SourceGuardHelper.containsCode("let corpus = venueBrandCorpus(in: context)",
                                                                  in: source)
        #expect(readsTheCorpusLazily, Comment(rawValue:
            "the venue brand corpus is no longer read through the shared helper, so the pre-classified "
            + "path may be paying a whole table fetch it does not need"))

        // And the caller's failed read travels with the pass. Without it a run that could not read the
        // corpus would report a clean one (#3071, L98).
        let carriesTheDegradedRead =
            SourceGuardHelper.containsCode("degradedReads.append(contentsOf: preClassified.degradedReads)",
                                           in: source)
        #expect(carriesTheDegradedRead, Comment(rawValue:
            "a pre-classified pass drops the store reads that failed while making it, so a degraded "
            + "corpus reads as a clean run"))
    }

    // #3905: the OTHER path into the same loop, which #3884 named and did not convert. It is the one
    // that froze the app for 34.2 s on 2026-09-13, with two 10 s samples putting 8,485 of 8,498 main
    // thread samples under it. Asserted from the source for the same reason as the sweep above:
    // `ScoutExtractIngest` needs a `ModelContext`, so no test in this target can drive it.
    @Test func theExtractIngestAlsoClassifiesOffTheActor() {
        let source = SourceGuardHelper.source("Overture/Integration/ScoutExtractIngest.swift")
        #expect(!source.isEmpty, "ScoutExtractIngest.swift could not be read, so this measured nothing")

        let classifiesOffTheActor =
            SourceGuardHelper.containsCode("await ScoutClassify.offTheCallersActor(", in: source)
        #expect(classifiesOffTheActor, Comment(rawValue:
            "the extract ingest classifies inline on the main actor again, so importing a read holds "
            + "the window for as long as it takes (#3905, and #3887 measured it at 34.2 s)"))

        // Through the SAME shared pieces as the sweep, so the two paths cannot drift about what a
        // classify pass is or what a failed corpus read means (L263).
        let readsTheSharedCorpus =
            SourceGuardHelper.containsCode("ScoutService.venueBrandCorpus(in: context)", in: source)
        #expect(readsTheSharedCorpus, "the ingest reads the brand corpus some other way than the shared helper")
        let carriesTheDegradedRead =
            SourceGuardHelper.containsCode("degradedReads: corpus.degradedReads", in: source)
        #expect(carriesTheDegradedRead, Comment(rawValue:
            "the ingest drops the store reads that failed while classifying, so a degraded corpus reads "
            + "as a clean import"))
    }

    // Both paths, named together, because the defect this pair exists for is converting ONE of them and
    // believing the class is covered: that is exactly what happened between #3884 and #3905 (L30).
    @Test func neitherPathIntoTheLoopClassifiesOnTheMainActor() {
        for file in ["Overture/Integration/ScoutService.swift",
                     "Overture/Integration/ScoutExtractIngest.swift"] {
            let source = SourceGuardHelper.source(file)
            #expect(!source.isEmpty, Comment(rawValue: "\(file) could not be read"))
            let awaitsTheClassify =
                SourceGuardHelper.containsCode("await ScoutClassify.offTheCallersActor(", in: source)
            #expect(awaitsTheClassify, Comment(rawValue:
                "\(file) reaches the match loop without awaiting it off the actor"))
        }
    }

    // A plain `Task` INHERITS the caller's actor, so the one thing that would make all of this decorative
    // is the detach going missing. Asserted by name.
    @Test func theDetachIsNotAPlainTask() {
        let source = SourceGuardHelper.source("Overture/Domain/ScoutClassify.swift")
        #expect(!source.isEmpty, "ScoutClassify.swift could not be read, so this measured nothing")
        let detaches = SourceGuardHelper.containsCode("await Task.detached(priority: .userInitiated) {",
                                                      in: source)
        #expect(detaches, Comment(rawValue:
            "the pass is started with a plain Task, which INHERITS the main actor from a @MainActor "
            + "caller. It would run exactly where it runs today while reading as though it had moved "
            + "(#3884, L3)"))
    }
}
