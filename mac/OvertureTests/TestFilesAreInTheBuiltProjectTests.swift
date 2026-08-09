import Testing
import Foundation

// #2354: a test file that exists on disk but is not referenced by the committed
// `mac/Overture.xcodeproj/project.pbxproj` is never compiled, so it never runs and never fails. The
// suite reports success and the `Suite shape:` line simply omits it, which is indistinguishable at a
// glance from a healthy run. The author of the new test has no signal at all: they watch a green run
// and read it as their tests passing.
//
// Measured 2026-08-09 while building #1571: a new test file was written and `xcodegen generate` run,
// but `scripts/check-pbxproj-fresh.sh` restores the working tree when it runs, which reverted the
// project file. The full suite then passed green with the four new tests absent from it.
//
// The merge gate does eventually block a stale project file, so nothing untested can ship. This is
// about the hours before that: during development a green run means nothing, and it looks exactly
// like a green run that means something.
//
// The membership it checks is COMPILATION, not mere presence: a file can carry a PBXFileReference
// and still sit outside every Sources build phase, which is the same silence with a different cause.

// The audit as a pure function over names handed IN, so its own failure paths can be exercised with
// fixtures rather than only ever being watched to pass over the real project (L1).
enum ProjectMembershipAudit {

    enum Finding: Equatable, CustomStringConvertible {
        case nothingToInspect(what: String)
        case notCompiled(name: String, directory: String)

        var description: String {
            switch self {
            case .nothingToInspect(let what):
                return "found no \(what) to inspect at all, so this guard checked nothing. That is a "
                     + "broken path, not a clean project (#2311)."
            case .notCompiled(let name, let directory):
                return "\(directory)/\(name) is on disk but is not compiled by "
                     + "mac/Overture.xcodeproj/project.pbxproj, so nothing in it ever runs and nothing "
                     + "in it can ever fail. Run `cd mac && xcodegen generate` and commit the result."
            }
        }
    }

    // A file is compiled when the project carries a build-file entry naming it in a Sources phase.
    // That is the line xcodegen writes for every source it compiles, and it is the one that decides
    // whether the file is built, as opposed to merely listed in the navigator.
    static func compiles(_ name: String, in projectFile: String) -> Bool {
        projectFile.contains("/* \(name) in Sources */")
    }

    static func audit(testFiles: [(name: String, directory: String)], projectFile: String) -> [Finding] {
        var findings: [Finding] = []
        if testFiles.isEmpty { findings.append(.nothingToInspect(what: "test source files")) }
        if projectFile.isEmpty { findings.append(.nothingToInspect(what: "project file text")) }
        guard findings.isEmpty else { return findings }

        for file in testFiles where !compiles(file.name, in: projectFile) {
            findings.append(.notCompiled(name: file.name, directory: file.directory))
        }
        return findings
    }
}

@Suite("Every test file on disk is compiled by the built project (#2354)")
struct TestFilesAreInTheBuiltProjectTests {

    // Both test targets, because the failure is the same in either and #1967 split them: an
    // OvertureHostedTests file left out of the project is exactly as silent as an OvertureTests one.
    private static let testDirectories = ["OvertureTests", "OvertureHostedTests", "TestSupport"]

    private static func swiftFiles(in directory: String) -> [String] {
        let url = RepoRoot.mac.appendingPathComponent(directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0.hasSuffix(".swift") }.sorted()
    }

    private static func testFilesOnDisk() -> [(name: String, directory: String)] {
        testDirectories.flatMap { directory in
            swiftFiles(in: directory).map { (name: $0, directory: directory) }
        }
    }

    private static var projectFile: String {
        (try? String(contentsOf: RepoRoot.mac.appendingPathComponent("Overture.xcodeproj/project.pbxproj"),
                     encoding: .utf8)) ?? ""
    }

    // MARK: - The invariant

    @Test func everyTestFileOnDiskIsCompiled() {
        let findings = ProjectMembershipAudit.audit(testFiles: Self.testFilesOnDisk(),
                                                    projectFile: Self.projectFile)

        #expect(findings.isEmpty, "\(findings.map(\.description).joined(separator: "\n"))")
    }

    // A floor, so the check above cannot pass by walking a directory that has stopped resolving. The
    // number is deliberately far below the real count (700+ across the three directories): it is a
    // "this path still works" assertion, not a pin on how many tests exist, which would fail on every
    // ordinary addition and teach the next person to raise it without reading (L63).
    @Test func theWalkStillFindsTheTestDirectories() {
        for directory in Self.testDirectories {
            #expect(Self.swiftFiles(in: directory).count > 5,
                    "found almost no Swift files in mac/\(directory), which is a broken path")
        }
        #expect(!Self.projectFile.isEmpty, "read no project file text at all")
    }

    // MARK: - The guard's own failure paths, seen to fail

    @Test func aFileMissingFromTheProjectIsNamed() {
        let findings = ProjectMembershipAudit.audit(
            testFiles: [(name: "PresentTests.swift", directory: "OvertureTests"),
                        (name: "AbsentTests.swift", directory: "OvertureTests")],
            projectFile: "/* PresentTests.swift in Sources */")

        #expect(findings == [.notCompiled(name: "AbsentTests.swift", directory: "OvertureTests")])
    }

    // Listed in the navigator but in no Sources phase is the same silence: the file is visible in
    // Xcode, reads as part of the project, and is never built.
    @Test func aFileReferencedButNeverCompiledStillFails() {
        let findings = ProjectMembershipAudit.audit(
            testFiles: [(name: "AbsentTests.swift", directory: "OvertureHostedTests")],
            projectFile: "/* AbsentTests.swift */ = {isa = PBXFileReference; path = AbsentTests.swift; };")

        #expect(findings == [.notCompiled(name: "AbsentTests.swift", directory: "OvertureHostedTests")])
    }

    @Test func anEmptyFileListFailsInsteadOfReportingACleanProject() {
        let findings = ProjectMembershipAudit.audit(testFiles: [], projectFile: "anything")

        #expect(findings == [.nothingToInspect(what: "test source files")])
    }

    @Test func anUnreadableProjectFileFailsInsteadOfExemptingEveryFile() {
        let findings = ProjectMembershipAudit.audit(
            testFiles: [(name: "AbsentTests.swift", directory: "OvertureTests")], projectFile: "")

        #expect(findings == [.nothingToInspect(what: "project file text")])
    }
}
