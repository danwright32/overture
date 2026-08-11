import Testing
import Foundation

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
        RepoRoot.mac
            .appendingPathComponent("Overture")
    }

    private static var scriptsRoot: URL {
        RepoRoot.mac
            .appendingPathComponent("scripts")
    }

    @Test func everyApplicationSupportDirectoryReferenceLivesInStoreLocation() throws {
        for file in AppSourceWalk.urls(under: Self.overtureSourceRoot) {
            let src = try String(contentsOf: file, encoding: .utf8)
            if src.contains(".applicationSupportDirectory") {
                #expect(file.lastPathComponent == Self.sourceOfTruth,
                        "\(file.lastPathComponent) references applicationSupportDirectory directly. Route through StoreLocation.handoffDirectory (or .dataDirectory) instead, so a Debug build can never silently read or write the live folder.")
            }
        }
    }

    @Test func runnerScriptsReadTheSupportDirEnvVarInsteadOfHardcoding() throws {
        // As of #552, SUPPORT= resolution lives in lib/runner-setup.sh, sourced by both runner
        // scripts, rather than duplicated inline in each one. Check the shared source of truth
        // instead of the callers, so this guard still means something after that refactor.
        let src = try String(contentsOf: Self.scriptsRoot.appendingPathComponent("lib/runner-setup.sh"), encoding: .utf8)
        // #1711 turned the one-line `SUPPORT="${OVERTURE_SUPPORT_DIR:-$HOME/...}"` into a branch, so the
        // assignments are indented and there are two of them. Matching them trimmed, and failing when
        // there are none at all, keeps this from going vacuous the next time that line moves.
        let supportLines = src.split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("SUPPORT=") }
        #expect(!supportLines.isEmpty,
                "lib/runner-setup.sh no longer assigns SUPPORT anywhere, so this guard is watching nothing.")
        #expect(supportLines.contains { $0.contains("$OVERTURE_SUPPORT_DIR") },
                "lib/runner-setup.sh must read $OVERTURE_SUPPORT_DIR (with a fallback for a hand-run from a terminal), not hardcode the live Application Support path. A hardcoded path made a Debug self-send spin forever with no work found.")
        #expect(supportLines.allSatisfy { $0.contains("$") },
                "every SUPPORT= assignment in lib/runner-setup.sh must be built from a variable. One spelling out the live Application Support path is what made a Debug self-send spin forever with no work found.")

        for script in ["prep-run.sh", "reply-classify-run.sh", "scout-extract-run.sh"] {
            let scriptSrc = try String(contentsOf: Self.scriptsRoot.appendingPathComponent(script), encoding: .utf8)
            #expect(scriptSrc.contains("lib/runner-setup.sh"),
                    "\(script) must source lib/runner-setup.sh for its SUPPORT resolution rather than reintroducing its own inline copy.")
            #expect(!scriptSrc.split(separator: "\n").contains { $0.hasPrefix("SUPPORT=") },
                    "\(script) must not redefine SUPPORT= inline; that duplication is exactly what #552 removed.")
        }
    }
}
