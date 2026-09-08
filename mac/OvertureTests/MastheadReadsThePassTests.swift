import Testing
import Foundation

// #3653 (milestone #80, Phase 3): the masthead reads the pass's answers rather than deriving its own.
//
// `QueueRenderPass` computes `pendingBookings` ONCE for the pass (`QueueRenderPass.swift:252`) and puts
// it on `RenderData`. The masthead then walked every row again for the same number, which is a second
// whole-store pass per render for a count the view was already handed.
//
// THAT IS THE #3577 SHAPE, in the same file this milestone is opening. #3577 found a duplicate
// whole-store pass that halved the felt wait when it went, and the thing that found it was a counter
// rather than a reading of the code: two whole-store passes and one slow one are the same number of
// milliseconds to anybody watching the clock (L98).
//
// WHY A SOURCE GUARD RATHER THAN A COUNTER, said plainly because this repository prefers the counter and
// is right to (L63). `QueueRenderPass.Corpus` counts sweeps over rows the PASS was handed, and
// `WorkTally` counts card construction; neither can see a walk that happens in a VIEW BODY after the pass
// has returned. That is exactly why this one survived: it is in the blind spot both instruments share.
// Making it visible to a counter means threading a tally into the view, which is #3654's work. Until
// then this is the cheaper net, and it is named as a net rather than as proof.
@Suite("The masthead reads the pass's counts rather than re-deriving them (#3653)")
struct MastheadReadsThePassTests {

    private var view: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    @Test("the masthead does not walk every row again for a count the pass already made")
    func theMastheadDoesNotRecomputePendingBookings() throws {
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "masthead", in: view),
                                "the masthead is gone, so this guard is about nothing (L98)")
        #expect(!body.contains("QueueModel.pendingBookingCount("),
                Comment(rawValue: "the masthead derives the pending booking count itself, which is a "
                        + "second whole-store walk per render for a number `RenderData.pendingBookings` "
                        + "already holds. Neither cost counter can see it, because both are bound around "
                        + "the pass and this happens in a view body after it returns (#3653, #3577)."))
    }

    // The other half, and the reason the first is not enough on its own: a guard saying the count is not
    // DERIVED here says nothing about whether the pass's answer is the one that draws. Removing the
    // recompute and leaving the number unthreaded would satisfy the assertion above and show Dan nothing.
    @Test("the number the masthead draws is the one the pass computed")
    func theMastheadIsHandedThePassesCount() throws {
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "masthead", in: view))
        #expect(body.contains("pendingBookings"),
                "the masthead no longer names the count at all, so nothing draws it")
        #expect(view.contains("pendingBookings: data.pendingBookings"),
                Comment(rawValue: "the pass's own `pendingBookings` is not threaded into the masthead, so "
                        + "either the number is derived somewhere else or nothing draws it. One "
                        + "derivation, one reader (L16)."))
    }

    // The pass is still the one place that derives it, so this cannot be satisfied by deleting the
    // feature outright (L103, and the empty-result trap in L98).
    @Test("the pass is still where the count is derived")
    func thePassStillDerivesIt() {
        let pass = SourceGuardHelper.source("Overture/UI/QueueRenderPass.swift")
        #expect(pass.contains("QueueModel.pendingBookingCount("),
                Comment(rawValue: "nothing derives the pending booking count any more, so the masthead's "
                        + "quiet is the feature being gone rather than the duplicate being removed."))
    }
}
