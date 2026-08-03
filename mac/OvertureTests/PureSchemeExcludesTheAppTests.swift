import Foundation
import Testing

// #1967: the pure suite's scheme must not contain the app target.
//
// This is the setting the whole issue turns on, and it is one line in a config file that anybody could
// undo without a single test noticing. Measured on 2026-08-02, with a deliberate `fatalError()` in
// OvertureApp.init:
//
//   both targets in ONE scheme   ->  "4802 tests passed" AND a non-zero exit, because xcodebuild still
//                                    prepared and launched the app host it never needed. Filtering with
//                                    -only-testing did NOT avoid the app.
//   the pure suite's own scheme  ->  "4802 tests passed", "** TEST SUCCEEDED **", exit 0.
//
// So the protection is not "the tests are unhosted", which is already asserted from the running process
// in UnhostedTestTargetTests. It is specifically that the app is not in this scheme's build, which is
// what stops a broken app deciding the run's exit code.
//
// Read from project.yml rather than the generated .xcscheme, because project.yml is what a person edits
// and the .xcscheme is regenerated from it (docs/contracts.md). A guard on the generated file would pass
// happily while the source of truth said something else.
@Suite("Pure scheme excludes the app (#1967)")
struct PureSchemeExcludesTheAppTests {

    private func projectYAML() throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("mac/project.yml")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("could not find mac/project.yml above \(#filePath)")
        return ""
    }

    // The scheme's own block, from its name to the next scheme at the same indent.
    //
    // Scoped to the `schemes:` section FIRST, and that is not a tidiness: a target and a scheme are
    // both named `Overture`, the target is declared first, and searching the whole file found the
    // TARGET every time. The positive control below caught it, failing on a clean tree for a reason
    // that had nothing to do with what it was checking, which is precisely the job it exists to do.
    private func schemeBlock(_ name: String, in yaml: String) -> String? {
        guard let schemes = yaml.range(of: "\nschemes:\n") else { return nil }
        let section = String(yaml[schemes.upperBound...])
        guard let start = section.range(of: "\n  \(name):\n")
                ?? (section.hasPrefix("  \(name):\n") ? section.range(of: "  \(name):\n") : nil) else {
            return nil
        }
        let rest = section[start.upperBound...]
        // The next line indented exactly two spaces ends this block.
        if let next = rest.range(of: "\n  [A-Za-z]", options: .regularExpression) {
            return String(rest[..<next.lowerBound])
        }
        return String(rest)
    }

    @Test func thePureSchemeDoesNotBuildTheApp() throws {
        let yaml = try projectYAML()
        let core = try #require(schemeBlock("OvertureCore", in: yaml),
                                "the OvertureCore scheme is gone; the pure suite has no app-free scheme")
        #expect(!core.contains("Overture: all"),
                """
                The app target is back in the OvertureCore scheme. That scheme exists so a broken app \
                cannot decide the pure suite's exit code: with the app in it, a fatalError at launch \
                made 4802 passing tests report a non-zero exit. Keep the app out of it.
                """)
        #expect(core.contains("OvertureTests"), "the pure scheme must still test the pure target")
    }

    // The positive control, and it is the reason the assertion above is not vacuous. If the slicing or
    // the search ever stops matching anything, THIS fails too, so the pair cannot both quietly pass
    // while checking nothing. A guard that can only ever say yes is not a guard.
    @Test func theDetectionActuallyFindsTheAppWhereItIsSupposedToBe() throws {
        let yaml = try projectYAML()
        let full = try #require(schemeBlock("Overture", in: yaml))
        #expect(full.contains("Overture: all"),
                """
                The app is no longer in the Overture scheme either, which means this check is looking \
                for something that no longer exists anywhere and the sibling test above proves nothing.
                """)
    }
}
