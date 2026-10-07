import Foundation

// #4582: Downbeat's export and the imported booking history, for a test that hands a landing neither file.
//
// Under /dev/null, so nothing can ever be written there and both always read as ABSENT, which is what a Mac with
// no Downbeat export and no imported history looks like. A test whose subject is either file writes its own into a
// sandbox instead. Never the default (`DownbeatBridge.defaultURL`, `LocalHistory.importedURL`): under test that is
// `StoreLocation.testRunHandoffDirectory`, one folder every test process on the Mac shares (#2097), so a file any
// other test, worktree or concurrent run left there would decide this test's verdict.
// `TestsNameTheirLandingInputFilesTests` fails a test that reaches a landing without naming both.
enum AbsentHandoff {
    static let export = URL(fileURLWithPath: "/dev/null/no-downbeat-export.json")
    static let history = URL(fileURLWithPath: "/dev/null/no-imported-history.json")
}
