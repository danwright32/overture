import Foundation

// #2365: how a TEST builds a `StageContext`, and the reason it is spelled differently from the way the
// app builds one.
//
// The app never pins the day: it passes an instant and lets the context derive Overture's Eastern day
// from it, which is the whole property `StageContext` exists to make unrepresentable
// (`StageContextTests.noProductionCallSitePinsTheDay` is what holds that true rather than a comment).
// A test wants the opposite: a fixed day it can reason about, without having to work backwards to an
// instant that produces it.
//
// So the pinning spelling lives HERE, in a file only the test target compiles, rather than as a
// convenience on the type itself. A shipping call site cannot reach for it by habit, because it cannot
// see it, and a reader meeting `.at("2026-08-07")` knows immediately that the day was chosen by the
// test rather than derived from a clock.
//
// In `OvertureTests` rather than `TestSupport` for a mechanical reason worth writing down, since the
// obvious instinct is that a shared helper belongs in the shared folder. `TestSupport` is compiled into
// BOTH test targets, and `OvertureHostedTests` reaches the app by LINKING it rather than by compiling
// its sources in, so a `TestSupport` file cannot name an app type at all. Every helper living there
// today (`SourceGuardHelper`, `SwiftSource`, `CopyInventory`) is pure Foundation for exactly that
// reason. `StageContext` is an app type, so this extension can only live in the target that compiles
// the app's sources. No hosted test builds a context today; if one ever needs to, it needs its own
// spelling rather than this one moved.
extension StageContext {
    // `today` is unlabelled and first because it is the thing a test is almost always saying something
    // about. `geo` keeps its default here, deliberately and in the opposite direction to the app's rule:
    // a test that is not about Dan's geography refusals should not have to name them, and a test that IS
    // about them says so in the one place it matters.
    static func at(_ today: String, now: Date = Date(), geo: GeoRefusals = .none,
                   clients: ClientWindow = .none) -> StageContext {
        StageContext(now: now, geo: geo, clients: clients, today: today)
    }
}
