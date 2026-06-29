import Testing
import Foundation
@testable import Overture

// The detached runner must tell the launched script WHICH data folder to use, or a Debug build
// (whose handoff dir is the isolated Overture-Debug subfolder) launches a script that reads the
// live folder, finds no work-list, and dies — the same Debug/Release leak class as #317. The
// script reads OVERTURE_SUPPORT_DIR, so the launch environment must carry the build's handoff dir.
@Suite("Detached runner environment")
struct DetachedRunnerTests {
    @Test func injectsSupportDirectoryForTheScript() {
        let dir = URL(fileURLWithPath: "/Users/x/Library/Application Support/Overture-Debug/Overture",
                      isDirectory: true)

        let env = DetachedRunner.runnerEnvironment(base: ["PATH": "/usr/bin"], supportDirectory: dir)

        // The script keys its queue/results/marker off this, so the Debug build reads its own folder.
        #expect(env["OVERTURE_SUPPORT_DIR"] == "/Users/x/Library/Application Support/Overture-Debug/Overture")
        // The inherited environment is preserved, not replaced.
        #expect(env["PATH"] == "/usr/bin")
    }
}
