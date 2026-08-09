import Testing
import Foundation

// #2311: the shared walk must REFUSE when it finds nothing, and every source guard must use it, so a
// guard cannot go on reporting a clean app while checking no files at all.
@Suite("A walk that finds nothing refuses instead of reporting a clean app (#2311)")
struct AppSourceWalkTests {

    // MARK: - The decision

    @Test func aWalkThatFoundNothingIsRefused() {
        let refusal = AppSourceWalk.refusal(found: 0, floor: 100, directory: "/nowhere/Overture")

        #expect(refusal != nil)
        #expect(refusal?.contains("/nowhere/Overture") == true, "the refusal must name the directory it walked")
        #expect(refusal?.contains("broken path") == true)
    }

    // The interesting boundary is not zero. A path that resolves to a SUBDIRECTORY of the app yields a
    // handful of real files, so a guard standing on it looks alive while checking almost nothing.
    @Test func aWalkThatFoundAFewFilesIsAlsoRefused() {
        #expect(AppSourceWalk.refusal(found: 7, floor: 100, directory: "/some/Overture/UI") != nil)
    }

    @Test func aWalkThatFoundEnoughIsAccepted() {
        #expect(AppSourceWalk.refusal(found: 100, floor: 100, directory: "/some/Overture") == nil)
        #expect(AppSourceWalk.refusal(found: 400, floor: 100, directory: "/some/Overture") == nil)
    }

    // MARK: - The wiring, seen to fire

    // Built is not wired (L3). The decision above is worth nothing unless an empty walk actually
    // reaches the test framework as a failure, and the only way to prove that is to make one happen.
    // withKnownIssue absorbs the recorded issue, and itself FAILS if no issue is recorded, so this
    // goes red if the walker ever stops refusing.
    @Test func anEmptyDirectoryRecordsAFailureFromInsideTheWalk() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("app-source-walk-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        withKnownIssue("an empty walk must refuse, even when the caller asserts nothing") {
            _ = AppSourceWalk.urls(under: empty, floor: 10)
        }
        withKnownIssue("reading contents must refuse on an empty walk too") {
            _ = AppSourceWalk.files(under: empty, floor: 10)
        }
    }

    // A directory full of files it cannot read is the same silence as an empty one: the guard gets an
    // empty list either way.
    @Test func filesThatCannotBeReadCountAgainstTheFloor() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("app-source-walk-unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<3 {
            let file = directory.appendingPathComponent("Unreadable\(index).swift")
            try Data([0xFF, 0xFE, 0xFF]).write(to: file)   // not valid UTF-8
        }

        withKnownIssue("a directory of unreadable files must refuse like an empty one") {
            _ = AppSourceWalk.files(under: directory, floor: 3)
        }
    }

    // MARK: - The real app

    @Test func theAppWalkFindsTheApp() {
        let files = AppSourceWalk.appFiles()

        #expect(files.count > AppSourceWalk.appFloor)
        #expect(files.contains { $0.name == "StageNavigation.swift" })
        #expect(files.allSatisfy { !$0.text.isEmpty })
    }

    // MARK: - Every guard inherits the refusal

    // The point of putting the refusal in the walk is that a guard written next year gets it without
    // knowing it exists. That only holds while nobody writes a private walker beside it, which is
    // exactly what the six guards this consolidated had all done independently.
    @Test func noTestFileDeclaresItsOwnAppSourceWalker() throws {
        let testFiles = try Self.testSources()
        #expect(testFiles.count > 100, "found almost no test sources, which is a broken path")

        // Matched on the directory enumerator itself rather than on any one spelling of it. The six
        // walkers this consolidated used three different spellings between them
        // (`FileManager.default.enumerator`, `fm.enumerator`, a stored `enumerator?.nextObject()`),
        // so a guard pinned to one of them would have found two of the six and reported the rest
        // clean, which is this issue's own defect wearing the guard's clothes.
        let offenders = testFiles
            .filter { $0.name != "AppSourceWalk.swift" && $0.name != "AppSourceWalkTests.swift" }
            .filter { $0.text.contains(".enumerator(at:") }
            .map(\.name)
            .sorted()

        #expect(offenders.isEmpty, """
            These walk a directory themselves instead of going through AppSourceWalk, so they do not \
            inherit its refusal and pass silently when the directory resolves to nothing: \
            \(offenders.joined(separator: ", "))
            """)
    }

    private static func testSources() throws -> [AppSourceWalk.File] {
        ["OvertureTests", "OvertureHostedTests", "TestSupport"].flatMap { directory in
            AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent(directory), floor: 5)
        }
    }
}
