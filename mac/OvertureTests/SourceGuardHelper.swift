import Foundation

// Shared by view-only guard-test suites (MastheadGuardTests, ProspectRowGuardTests, …) that
// assert on the raw source text of a SwiftUI view rather than runtime behavior, for changes
// with no behavioral surface to exercise.
enum SourceGuardHelper {
    static func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        // #filePath -> .../mac/OvertureTests/<Suite>.swift; climb to mac/.
        let mac = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
        let url = mac.appendingPathComponent(relativeFromMac)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
