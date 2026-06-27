import Testing
import Foundation
@testable import Overture

// #239: the automatic OmniFocus sync (on launch / data change) is best-effort and swallows errors,
// so a revoked Automation permission or a moved app silently stops creating follow-up tasks. This
// records the last sync's result so a failure stays visible until the next success clears it.
@Suite("OmniFocus sync status (#239)")
struct OmniFocusSyncStatusTests {
    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "ofstatus-\(UUID().uuidString)")!
        return d
    }

    @Test func noRecordMeansNoFailure() {
        #expect(OmniFocusSyncStatus.lastFailure(from: freshDefaults()) == nil)
    }

    @Test func recordFailurePersistsTheMessageAndTime() {
        let d = freshDefaults()
        let when = Date(timeIntervalSince1970: 1_000)
        OmniFocusSyncStatus.recordFailure("permission denied", at: when, into: d)
        let f = OmniFocusSyncStatus.lastFailure(from: d)
        #expect(f?.message == "permission denied")
        #expect(f?.at == when)
    }

    @Test func recordSuccessClearsAPriorFailure() {
        let d = freshDefaults()
        OmniFocusSyncStatus.recordFailure("boom", at: Date(timeIntervalSince1970: 1_000), into: d)
        OmniFocusSyncStatus.recordSuccess(into: d)
        #expect(OmniFocusSyncStatus.lastFailure(from: d) == nil)
    }
}
