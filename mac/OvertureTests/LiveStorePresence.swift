import Foundation
import Testing

// Is there a live store on THIS machine at all?
//
// #4076 added a live store suite that THREW when there was none, and the GitHub-hosted runner never has
// one, so `swift-tests` went red on every branch cut after it and stayed red. That is the failure L411
// names: a test depending on machine state it cannot SET has to DETECT that state and report UNMEASURED,
// because a red there is indistinguishable from a real one. It is also the exact thing that suite's own
// header says it exists not to do, that "a test that goes red ... would block every merge in the
// repository until the DATA was settled".
//
// SHARED rather than copied a third time. `ContradictedCancellationTests` and
// `GateConsumersAgreeLiveStoreTests` each grew their own spelling of this question, and a second copy is
// how one caller comes to disagree with another about what "there is a store" means (L263, L370).
//
// Deliberately NOT a check that the store can be OPENED or that it holds rows. This answers one question,
// whether the file is there, which is what decides between "run this suite" and "this machine cannot be
// asked". A store that exists and cannot be read is a real failure and must stay red.
enum LiveStorePresence {

    // The RELEASE store, never the Debug one. A test bundle is a debug build, so asking
    // `StoreLocation.storeURL` without pinning this resolves the Overture-Debug path, which is not the
    // store these suites mean and is usually absent even on Dan's Mac (#3977 is the same trap on the
    // Downbeat export beside it).
    nonisolated static var url: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    nonisolated static var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // The words a skipped test shows, in one place so every suite skips for the same stated reason.
    // A `Comment` rather than a String: that is what the skip trait takes, and a String constant does
    // not convert where a literal would, so typing it here keeps every call site a one liner.
    static let absenceReason: Comment =
        "no live store on this machine, so this suite is UNMEASURED rather than green"
}
