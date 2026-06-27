import Testing
import Foundation
@testable import Overture

// #288: the permission probe must target the SAME OmniFocus the AppleScript drives. The AppleScript
// uses the friendly name ("OmniFocus"), which macOS resolves to the installed app's real bundle id,
// so a dynamically resolved id has to be probed first, with the known candidates kept only as a
// fallback. Resolution and the probe itself read live system/TCC state and stay untestable; the pure
// id-list logic is what these tests cover.
@Suite("OmniFocus automation permission (#288)")
struct OmniFocusAutomationPermissionTests {
    @Test func probesTheResolvedIdFirstThenTheCandidates() {
        let ids = OmniFocusAutomationPermission.bundleIDsToProbe(
            resolved: "com.omnigroup.OmniFocus5",
            candidates: ["com.omnigroup.OmniFocus4", "com.omnigroup.OmniFocus3"])
        #expect(ids.first == "com.omnigroup.OmniFocus5")
        #expect(ids == ["com.omnigroup.OmniFocus5", "com.omnigroup.OmniFocus4", "com.omnigroup.OmniFocus3"])
    }

    @Test func fallsBackToTheCandidatesWhenNothingResolves() {
        let candidates = ["com.omnigroup.OmniFocus4", "com.omnigroup.OmniFocus3"]
        #expect(OmniFocusAutomationPermission.bundleIDsToProbe(resolved: nil, candidates: candidates) == candidates)
        #expect(OmniFocusAutomationPermission.bundleIDsToProbe(resolved: "", candidates: candidates) == candidates)
    }

    @Test func doesNotDuplicateAResolvedIdAlreadyInTheCandidates() {
        let candidates = ["com.omnigroup.OmniFocus4", "com.omnigroup.OmniFocus4.MacAppStore"]
        let ids = OmniFocusAutomationPermission.bundleIDsToProbe(resolved: "com.omnigroup.OmniFocus4",
                                                                candidates: candidates)
        #expect(ids == ["com.omnigroup.OmniFocus4", "com.omnigroup.OmniFocus4.MacAppStore"])
        #expect(ids.count == candidates.count)
    }

    @Test func theDefaultCandidateListStillCoversDansKnownInstall() {
        #expect(OmniFocusAutomationPermission.candidateBundleIDs.contains("com.omnigroup.OmniFocus4"))
    }
}
