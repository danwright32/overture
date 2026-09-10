import Foundation
import SwiftData

// #3496: replay what a LAUNCH does to a copy of the store, so a live-store invariant is asserted against
// the state Dan actually sees rather than against the interval between two launches (L385).
//
// Why the WHOLE sequence rather than the passes that clear duplicates. Dan's call, 2026-09-10 (this
// session, in chat). A hand written list of passes beside the real one is a second definition that drifts
// silently (L41, L263), and it already had: `OneVenueIdentityLiveStoreTests` replayed
// `NaturalKeyVenueMigration` alone while `LaunchMigrations` runs `DriftedRunMerge` and
// `SameNightTitleVariantMerge` after it, and those two are what actually clear a same-night duplicate. So
// the suite asserted "no duplicates remain" having replayed none of the work that removes them. Naming
// the three here would only move that same drift one file across: the day a fourth pass is added, this
// list is short by one and nothing says so.
//
// ISOLATED from this Mac, which is the part to keep. `LaunchMigrations.run` takes its settings store, its
// handoff folder and its clock as seams with real defaults, and `PresenterWithheldRecheck.boundary`
// WRITES a date into the settings store when it finds none. Replaying with the defaults would therefore
// have a test stamp a boundary into the REAL app's settings, which the running Overture then reads: a
// test reaching out and changing live state (L2). Every seam is supplied here, so no caller can forget
// one, and the settings suite is thrown away afterwards.
// In OvertureTests rather than TestSupport, deliberately: TestSupport is compiled into BOTH test
// targets, and the hosted one LINKS the app rather than compiling it in, so an app type named here is
// not in scope there. Every caller of this lives in OvertureTests.
enum LaunchReplay {

    // The handoff folder is REQUIRED rather than defaulted, so a caller cannot silently replay against
    // this Mac's real one. The clock is a parameter with a real default rather than a hidden `Date()`,
    // because a caller asserting anything date-relative needs to pin both ends of it (L130).
    @discardableResult
    static func run(in context: ModelContext, handoffDirectory: URL, now: Date = Date()) -> Bool {
        // Force-unwrapped deliberately: `UserDefaults(suiteName:)` returns nil only for a name that
        // collides with a reserved domain, and a fresh UUID cannot. A silent fallback to `.standard`
        // here would reintroduce exactly the live write this isolation exists to prevent, so failing
        // loudly is the safe direction (L42).
        let suiteName = "overture-launch-replay-\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: suiteName)!
        defer { isolated.removePersistentDomain(forName: suiteName) }

        return LaunchMigrations.run(in: context,
                                    // The recheck judges against two files a test process does not have,
                                    // so with the real loader it silently no-ops and anything asserted
                                    // through it asserts nothing (LaunchMigrations' own note on it).
                                    possibleMatchInputs: { (_: [Prospect]) -> PossibleMatchRecheck.Inputs? in nil },
                                    defaults: isolated,
                                    handoffDirectory: handoffDirectory,
                                    now: now)
    }
}
