import Testing
import Foundation

// #2724 and #2728: what a row does on screen between the press and the rebuild landing.
//
// #2417 made a closed-out row draw a dimmed exit on the press. Two questions were left after it, and they
// turn out to have different answers.
//
// **#2728 asked for a FLOOR and it already exists.** Its premise is that "the exit ends when the rebuild
// lands and the row leaves the store's answer, so its time on screen is however long that takes and
// nothing sets a floor under it". That is not what the code does. `QueueDateGroups` splices the departing
// SNAPSHOTS back into the rendered groups (`QueueModel.groups(_:withDeparting:)`), so a departing row is
// drawn from its snapshot and not from the store's answer, and it stays until `finishDeparting` runs.
// That clear is scheduled on `SendDelightTiming.plan(reduceMotion:).holdBeforeExit` and on nothing else,
// so the floor is 0.55s, or 0.28s under Reduced Motion, whatever the rebuild costs. The issue's own
// "rough direction" is a description of what #2417 shipped.
//
// Nothing pinned that, which is why this suite exists: a floor that holds by accident is one refactor from
// being tied back to the rebuild, and the failure would be a flicker nobody can reproduce on a big store.
//
// **#2724 asked for the same thing on a NIGHT dismiss and it was genuinely missing.** The departure
// machinery is keyed per row, so #2417's fix did not reach a control that removes N rows at once.
//
// WHY THESE ARE SOURCE GUARDS. Both live in `QueueView`, whose body cannot be evaluated in a unit test,
// and what is being protected is the ORDER and the SCHEDULE rather than any value a function returns.
// The behaviour they depend on, the splice and the timing plan, is tested for real elsewhere
// (`DepartingRowsSpliceTests`, `QueueDepartingFoldTests`, `SendDelightTimingTests`) and is not restated
// here.
@Suite("A departure has a floor, and a night dismiss has one too (#2724, #2728)")
struct ADepartureHasAFloorTests {

    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    // The floor itself, asserted over the value rather than the view: it must be real in BOTH modes, and
    // shorter under Reduced Motion rather than absent, because a floor of zero there would be the flicker
    // this exists to prevent, delivered to the person likeliest to be hurt by it.
    @Test("the timing plan gives a real floor in both modes")
    func theTimingPlanHasAFloorInBothModes() {
        let ordinary = SendDelightTiming.plan(reduceMotion: false)
        let reduced = SendDelightTiming.plan(reduceMotion: true)

        #expect(ordinary.holdBeforeExit > 0.2,
                Comment(rawValue: "an ordinary departure holds for \(ordinary.holdBeforeExit)s, which is short enough to "
                + "read as a flicker rather than as the screen answering (#2728, L44)"))
        #expect(reduced.holdBeforeExit > 0.2,
                "a Reduced Motion departure holds for \(reduced.holdBeforeExit)s")
        #expect(reduced.holdBeforeExit < ordinary.holdBeforeExit,
                "Reduced Motion is not honoured: it holds for as long as the ordinary plan")
        #expect(ordinary.total < 1.0, "a departure must stay under a second, which the plan's own note says")
    }

    // #2728: the clear is scheduled on the PLAN, and on nothing to do with the write or the rebuild. This
    // is what makes the floor independent of the store's size, which is the whole of what the issue asks.
    @Test("a close-out clears its departure on the timing plan, not on the rebuild")
    func aCloseOutClearsOnThePlan() throws {
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "closeOut", in: queueView))

        #expect(body.contains("SendDelightTiming.plan(reduceMotion: reduceMotion)"),
                Comment(rawValue: "the departure's length no longer comes from the timing plan, so nothing sets a floor "
                + "under it and on a small store the row draws for a frame and drops (#2728)"))
        #expect(body.contains("asyncAfter(deadline: .now() + t.holdBeforeExit)"),
                Comment(rawValue: "the clear is no longer scheduled on the hold, so its time on screen is whatever the "
                + "rebuild happens to cost"))
        // And the ORDER, which is the other half: a clear scheduled before the mark would be a floor
        // under nothing.
        let marked = try #require(body.range(of: "sendState.depart("))
        let cleared = try #require(body.range(of: "sendState.finishDeparting("))
        #expect(marked.lowerBound < cleared.lowerBound)
    }

    // #2724: the same three things, on the control that removes a whole night.
    @Test("a night dismiss marks every row leaving, before the write")
    func aNightDismissMarksEveryRowLeaving() throws {
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "dismissNight", in: queueView))

        #expect(body.contains("sendState.depart("),
                Comment(rawValue: "a night dismiss still leaves its rows on screen through the write and the rebuild "
                + "behind it, which is #2417's defect on the same screen (#2724)"))
        #expect(body.contains("ProspectMutations.dismissAll("),
                "the dismissal must still reach the one write, whatever the rows do on screen first")

        // The ORDER is the fix, not either half of it: marking after the write puts the animation behind
        // the rebuild it exists to hide.
        let marked = try #require(body.range(of: "sendState.depart("))
        let written = try #require(body.range(of: "ProspectMutations.dismissAll("))
        #expect(marked.lowerBound < written.lowerBound,
                "the rows are marked leaving BEFORE the write, or the screen still waits for the rebuild")
    }

    @Test("a night dismiss clears on the same plan a close-out does")
    func aNightDismissClearsOnTheSamePlan() throws {
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "dismissNight", in: queueView))

        #expect(body.contains("SendDelightTiming.plan(reduceMotion: reduceMotion)"),
                Comment(rawValue: "a night's rows leave on a different schedule from a single close-out's, which is two "
                + "timing rules for one exit (#2724, L263)"))
        #expect(body.contains("asyncAfter(deadline: .now() + t.holdBeforeExit)"))
        #expect(body.contains("finishDeparting("),
                Comment(rawValue: "the departures are never cleared, so every dismissed night draws its dimmed rows until "
                + "the thirty second ceiling catches them (#2729)"))
    }

    // EVERY row, not the first one. A night dismiss can carry one show or nineteen, and marking only one
    // would be indistinguishable from working on the one-row night that is also the commonest.
    @Test("it marks all of them rather than one")
    func itMarksEveryRowRatherThanOne() throws {
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "dismissNight", in: queueView))
        #expect(body.contains("for item in departing { sendState.depart("),
                "the marking is not over every row in the night")
        #expect(body.contains("for item in departing { sendState.finishDeparting("),
                "the clearing is not over every row in the night")
    }

    // The snapshots come from the rows BEFORE the write, for the reason `closeOut` records: once the
    // dismissals land these shows are gone from the queue's answer and the cards playing the exit cannot
    // come from it.
    @Test("the snapshots are taken before the write")
    func theSnapshotsAreTakenBeforeTheWrite() throws {
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "dismissNight", in: queueView))
        let snapped = try #require(body.range(of: "let departing = keys.compactMap"))
        let written = try #require(body.range(of: "ProspectMutations.dismissAll("))
        #expect(snapped.lowerBound < written.lowerBound,
                Comment(rawValue: "the snapshots are taken after the write, so they are taken from rows that have already "
                + "left the queue's answer"))
    }
}
