import Testing
import Foundation
@testable import Overture

// Regression guard for #317 / #437: every on-disk handoff path must resolve through
// StoreLocation, never an independently constructed Application Support path, or a Debug build
// can silently read/write the live folder (or a hand-run script point at the wrong directory)
// with no error, just a hang or a file landing in the wrong place.
@Suite("Handoff path guard")
struct HandoffPathGuardTests {

    // The only file allowed to touch the raw applicationSupportDirectory API; every other Swift
    // source file must derive its path from StoreLocation.handoffDirectory / .dataDirectory.
    private static let sourceOfTruth = "StoreLocation.swift"

    private static var overtureSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("Overture")
    }

    private static var scriptsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("scripts")
    }

    private static func swiftFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func everyApplicationSupportDirectoryReferenceLivesInStoreLocation() throws {
        for file in Self.swiftFiles(under: Self.overtureSourceRoot) {
            let src = try String(contentsOf: file, encoding: .utf8)
            if src.contains(".applicationSupportDirectory") {
                #expect(file.lastPathComponent == Self.sourceOfTruth,
                        "\(file.lastPathComponent) references applicationSupportDirectory directly. Route through StoreLocation.handoffDirectory (or .dataDirectory) instead, so a Debug build can never silently read or write the live folder.")
            }
        }
    }

    @Test func runnerScriptsReadTheSupportDirEnvVarInsteadOfHardcoding() throws {
        for script in ["prep-run.sh", "reply-classify-run.sh"] {
            let src = try String(contentsOf: Self.scriptsRoot.appendingPathComponent(script), encoding: .utf8)
            let supportLine = src.split(separator: "\n").first { $0.hasPrefix("SUPPORT=") }
            #expect(supportLine?.contains("${OVERTURE_SUPPORT_DIR:-") == true,
                    "\(script) must read $OVERTURE_SUPPORT_DIR (with a fallback for a hand-run from a terminal), not hardcode the live Application Support path. A hardcoded path made a Debug self-send spin forever with no work found.")
        }
    }
}
