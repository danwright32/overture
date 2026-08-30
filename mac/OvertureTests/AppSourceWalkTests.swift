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

// #3235: the same walk was being paid for over and over. Twelve suites are 361 of the suite's 507
// serial seconds, and most of that is one scan repeated: `CopyInventory.build()` twelve times at 5.9s
// each, `CopySurfaces.build()` four times at 12.6s, and four tests in the #2839 guard each re-walking
// `mac`, `fixtures`, `src` and `docs` at about 12s a walk.
//
// The memo is only safe because of what it refuses to keep. A memoised EMPTY scan would pass every
// guard in the suite at once, which is the exact failure #2311 exists to prevent, so the refusal is
// evaluated on EVERY call rather than once, and an empty result is never kept at all (L286, L98).
@Suite("The shared walk is paid for once per root (#3235)")
struct AppSourceWalkMemoTests {

    private func makeSources(count: Int) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("app-source-walk-memo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<count {
            try "enum Sample\(index) {}\n".write(
                to: directory.appendingPathComponent("Sample\(index).swift"),
                atomically: true, encoding: .utf8)
        }
        return directory
    }

    @Test func asecondWalkOfTheSameRootReadsNothingFromDisk() throws {
        let root = try makeSources(count: 4)
        defer { try? FileManager.default.removeItem(at: root) }

        let before = AppSourceWalk.walksPerformed(forRootAt: root)
        let first = AppSourceWalk.files(under: root, floor: 1)
        let afterFirst = AppSourceWalk.walksPerformed(forRootAt: root)
        let second = AppSourceWalk.files(under: root, floor: 1)
        let afterSecond = AppSourceWalk.walksPerformed(forRootAt: root)

        #expect(afterFirst == before + 1, "the first call has to actually walk, or this proves nothing")
        #expect(afterSecond == afterFirst, "the second call must be answered from the memo")
        #expect(first.count == 4)
        #expect(first.map(\.name) == second.map(\.name))
        #expect(first.map(\.text) == second.map(\.text))
    }

    // THE case the memo must not break. A scan that came back empty is the one result that must never
    // be kept: every guard downstream reads an empty list as "checked everything, found nothing wrong",
    // so keeping it would turn one broken path into a whole suite passing over nothing at once.
    @Test func anEmptyWalkIsNeverKept() throws {
        let empty = try makeSources(count: 0)
        defer { try? FileManager.default.removeItem(at: empty) }

        let before = AppSourceWalk.walksPerformed(forRootAt: empty)
        withKnownIssue("an empty walk refuses") { _ = AppSourceWalk.files(under: empty, floor: 10) }
        let afterFirst = AppSourceWalk.walksPerformed(forRootAt: empty)
        withKnownIssue("and refuses again, rather than being answered from a memo") {
            _ = AppSourceWalk.files(under: empty, floor: 10)
        }
        let afterSecond = AppSourceWalk.walksPerformed(forRootAt: empty)

        #expect(afterFirst == before + 1)
        #expect(afterSecond == afterFirst + 1, "an empty result must be re-walked, never remembered")
    }

    // The url-only walk is a SECOND code path with its own memo, and CopyInventory is its caller, so
    // it needs its own proof rather than inheriting the one above. Two lines that look identical are
    // exactly where a single mutation proves only one of them (this test exists because one did).
    @Test func anEmptyUrlWalkIsNeverKeptEither() throws {
        let empty = try makeSources(count: 0)
        defer { try? FileManager.default.removeItem(at: empty) }

        let before = AppSourceWalk.walksPerformed(forRootAt: empty)
        withKnownIssue("an empty walk refuses") { _ = AppSourceWalk.urls(under: empty, floor: 10) }
        let afterFirst = AppSourceWalk.walksPerformed(forRootAt: empty)
        withKnownIssue("and refuses again rather than being answered from a memo") {
            _ = AppSourceWalk.urls(under: empty, floor: 10)
        }
        #expect(afterFirst == before + 1)
        #expect(AppSourceWalk.walksPerformed(forRootAt: empty) == afterFirst + 1,
                "an empty url walk must be re-walked, never remembered")
    }

    @Test func asecondUrlWalkOfTheSameRootReadsNothingFromDisk() throws {
        let root = try makeSources(count: 4)
        defer { try? FileManager.default.removeItem(at: root) }

        let before = AppSourceWalk.walksPerformed(forRootAt: root)
        let first = AppSourceWalk.urls(under: root, floor: 1)
        let afterFirst = AppSourceWalk.walksPerformed(forRootAt: root)
        let second = AppSourceWalk.urls(under: root, floor: 1)

        #expect(afterFirst == before + 1)
        #expect(AppSourceWalk.walksPerformed(forRootAt: root) == afterFirst, "the second call must be answered from the memo")
        #expect(first == second)
    }

    // A result that is SHORT but not empty is kept, because re-walking it saves nothing, but the
    // refusal has to reach every caller rather than only the one that happened to walk first: two
    // guards standing on the same broken path must both go red.
    @Test func aShortWalkIsRefusedOnEveryCallEvenWhenItIsKept() throws {
        let root = try makeSources(count: 3)
        defer { try? FileManager.default.removeItem(at: root) }

        withKnownIssue("a short walk refuses") { _ = AppSourceWalk.files(under: root, floor: 100) }
        let afterFirst = AppSourceWalk.walksPerformed(forRootAt: root)
        withKnownIssue("and refuses for the SECOND caller too, off the memo") {
            _ = AppSourceWalk.files(under: root, floor: 100)
        }
        #expect(AppSourceWalk.walksPerformed(forRootAt: root) == afterFirst, "it was kept")
    }

    // The extensions are part of what was asked for, not a detail: a guard over test data asks for
    // json and md as well, and handing it the swift-only answer would silently narrow what it checks.
    @Test func adifferentSetOfExtensionsIsADifferentQuestion() throws {
        let root = try makeSources(count: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        try "{}\n".write(to: root.appendingPathComponent("fixture.json"), atomically: true, encoding: .utf8)

        let swiftOnly = AppSourceWalk.files(under: root, floor: 1)
        let withJSON = AppSourceWalk.files(under: root, floor: 1, extensions: ["swift", "json"])

        #expect(swiftOnly.count == 3)
        #expect(withJSON.count == 4, "the json file must not be lost to the swift-only memo")
    }
}

// #3235: the same three whole-tree documents were being built over and over from an unchanged tree.
// Written order-independently, by comparing the count either side of a SECOND call rather than
// asserting it is one: another suite may legitimately have built it first, and a test that only passes
// when it runs first is a test about the run order.
@Suite("The generated copy documents are built once per process (#3235)")
struct CopyDocumentMemoTests {

    @Test func theInventoryIsBuiltOncePerProcess() throws {
        _ = try CopyInventory.build()
        let afterFirst = CopyInventory.buildsPerformed
        _ = try CopyInventory.build()
        #expect(CopyInventory.buildsPerformed == afterFirst, "the second call must be answered from the memo")
    }

    @Test func thesurfacesReportIsBuiltOncePerProcess() throws {
        _ = try CopySurfaces.build()
        let afterFirst = CopySurfaces.buildsPerformed
        _ = try CopySurfaces.build()
        #expect(CopySurfaces.buildsPerformed == afterFirst)
    }

    @Test func theOutboundDocumentIsBuiltOncePerProcess() throws {
        _ = try OutboundCopy.build()
        let afterFirst = OutboundCopy.buildsPerformed
        _ = try OutboundCopy.build()
        #expect(OutboundCopy.buildsPerformed == afterFirst)
    }

    // The memo must not reach the tests OF the builder. Those inject a two-file tree on purpose, and
    // handing them a remembered answer about the real app would make every one of them assert nothing.
    @Test func aninjectedRootKeepsBuilding() throws {
        let tree = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("copy-memo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tree) }
        try "enum A { static let line = \"Hello there.\" }\n"
            .write(to: tree.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)

        // Asserted on the ANSWER rather than on a global counter. The counter is shared with every other
        // test in the process, so reading it either side of this call measures whatever else happened to
        // be building at that moment, which is a test about the run order (this is the shape that failed
        // the first parallel run, #3234). What the defect would actually look like is unmistakable here:
        // the real app has hundreds of files and this tree has one.
        let first = try CopyInventory.build(root: tree, floor: 1)
        let second = try CopyInventory.build(root: tree, floor: 1)
        #expect(first.filesScanned == 1, "an injected root must be scanned, not answered from the memo")
        #expect(second.filesScanned == 1, "and again on the second call")
        #expect(first.occurrences.keys.contains("Hello there."))
    }

    // The one result that must never be kept. A scan that read nothing is indistinguishable downstream
    // from a tree with no copy in it, so remembering it would let one broken path pass every copy guard
    // in the suite at once.
    @Test func ascanThatReadNothingIsNeverKept() {
        let memo = BuildMemo<Int>()
        var builds = 0
        let first = memo.value(keepIf: { $0 > 0 }) { builds += 1; return 0 }
        let second = memo.value(keepIf: { $0 > 0 }) { builds += 1; return 0 }
        #expect(first == 0 && second == 0)
        #expect(builds == 2, "an empty scan must be built again, never remembered")

        var laterBuilds = 0
        let kept = BuildMemo<Int>()
        _ = kept.value(keepIf: { $0 > 0 }) { laterBuilds += 1; return 5 }
        _ = kept.value(keepIf: { $0 > 0 }) { laterBuilds += 1; return 5 }
        #expect(laterBuilds == 1, "and a real one IS remembered, or the memo saves nothing")
    }
}
