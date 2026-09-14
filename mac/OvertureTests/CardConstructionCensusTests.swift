import Testing
import Foundation

// #3654: the ratio the task-local decision rests on, RE-DERIVED rather than quoted.
//
// `QueueRenderPass.WorkTally` counts per-card work through a task local rather than a parameter, and the
// argument for that is a ratio: `QueueItem(` has hundreds of construction sites and almost all of them
// are in test files that are not about cost, so threading a tally through would buy compile-time coverage
// of a handful of app sites at the price of every one of those edits.
//
// That ratio was written into the comment as "318 construction sites, 314 of them in 93 test files",
// measured in the #2048 era. By 2026-09-08 the real figures were 392 and 380, so the number a reader
// would have checked the reasoning against was stale by 74, and a figure with a date beside it reads as
// more trustworthy the older it gets (L32, L316, and #3487's rule for a store-wide count quoted in
// prose). The prose no longer carries numbers. This does.
//
// IT IS A GUARD ON THE ARGUMENT, not on the count. A test pinning "392" would go red on every added test
// and be updated without being read, which is how a ratchet stops being a measurement (L182). What it
// asserts is the thing the decision turns on: the app's share is small enough that a parameter would
// still be the wrong trade. It PRINTS the reading either way, so the figure is on every run rather than
// in a sentence somebody has to believe.
@Suite("The card-construction census the task-local decision rests on (#3654)")
struct CardConstructionCensusTests {
    // Where the argument would change. At a tenth of all sites the app would be a large enough share that
    // threading a parameter is worth arguing about again; it is 3% today. Deliberately far from the
    // current reading rather than just above it, so ordinary growth does not fire it (L172).
    private static let appShareThatWouldChangeTheArgument = 0.10

    private func sites(in files: [AppSourceWalk.File]) -> Int {
        files.reduce(0) { $0 + $1.text.components(separatedBy: "QueueItem(").count - 1 }
    }

    @Test func theAppsShareOfCardConstructionIsStillSmall() {
        let app = AppSourceWalk.files(under: RepoRoot.app)
        let tests = AppSourceWalk.files(underAll: [RepoRoot.url.appendingPathComponent("mac/OvertureTests"),
                                                   RepoRoot.url.appendingPathComponent("mac/OvertureHostedTests")],
                                        floor: 100)
        let appSites = sites(in: app)
        let testSites = sites(in: tests)
        let total = appSites + testSites

        // UNMEASURED is its own outcome. A walk that found nothing and a tree with no card construction
        // in it leave the same empty result, and the emptiest possible failure must not read as the
        // cleanest possible pass (L98).
        #expect(total > 0, "no card construction found anywhere, so this measured nothing")
        guard total > 0 else { return }

        let share = Double(appSites) / Double(total)
        print("card-construction-census: \(appSites) app sites, \(testSites) test sites, "
              + "app share \(String(format: "%.1f", share * 100))%")
        #expect(share < Self.appShareThatWouldChangeTheArgument, Comment(rawValue:
            "the app now holds \(appSites) of \(total) card-construction sites "
            + "(\(String(format: "%.0f", share * 100))%), which is enough that threading a tally through "
            + "as a parameter is worth re-arguing. The comment on QueueRenderPass.WorkTally says why it "
            + "is a task local; that reasoning was measured against an app share in the low single "
            + "figures."))
    }

    // The other half of the same argument, and the half that would actually break: the task local's value
    // is that NOTHING HAS TO OPT IN. A card built anywhere is counted, whichever initialiser was used, so
    // this asserts every one of them passes through the counted line.
    @Test func everyCardInitialiserPassesThroughTheCounter() {
        let model = SourceGuardHelper.source("Overture/UI/QueueView+Model.swift")
        #expect(!model.isEmpty, "the source could not be read, so this measured nothing")
        // One recorded call, in the initialiser every other one delegates to.
        let recorded = model.components(separatedBy: "QueueRenderPass.WorkTally.recordQueueItem()").count - 1
        #expect(recorded == 1, Comment(rawValue:
            "there are \(recorded) card counters in this file rather than one. Two would double-count "
            + "every card and the cost pins would be measuring the counter; none would leave the pins "
            + "reading zero while the work happened (L11)."))
        #expect(model.contains("self.init(p, sendGroups: SendGroup.CardGroups(of: p))"), Comment(rawValue:
            "the convenience initialiser no longer delegates to the counted one, so a card built through "
            + "it is invisible to every cost pin in this repository"))
    }
}
