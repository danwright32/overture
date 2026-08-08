import Testing
import Foundation

// #1993: the tests find the repository by SEARCHING for it, not by counting directories.
//
// 53 test files climbed a hard-coded number of levels from their own path, with the levels spelled
// out in comments. The count is a hand-maintained fact sitting beside its source of truth, the
// actual directory layout, and it breaks SILENTLY. #1967 hit exactly this: moving CopyInventory.swift
// one directory shallower left its four-level climb pointing ABOVE the repo, the scan found zero
// files, and eleven tests reported that the app contains no user-facing copy rather than reporting
// that the path was wrong. A wrong path presented itself as a finding about the product.
//
// None of the 53 was broken, only because the files #1967 moved happened to sit at the same depth as
// the ones that stayed. That is luck, and the next reorganisation spends it.
@Suite("Finding the repo root by search (#1993)")
struct RepoRootTests {

    // A throwaway tree shaped like this repo: a root holding the marker, and a file some way down.
    private func tree(depth: Int) throws -> (root: URL, leaf: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("mac/Overture"), withIntermediateDirectories: true)

        var leaf = root
        for i in 0..<depth { leaf = leaf.appendingPathComponent("level\(i)") }
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        return (root, leaf.appendingPathComponent("SomeTests.swift"))
    }

    private func sameFile(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // THE property, and the only one that actually matters: the answer does not depend on how deep
    // the asking file sits. A climb of N is correct at exactly one depth; a search is correct at all
    // of them, which is what makes a file safe to move.
    @Test func theSameRootIsFoundFromEveryDepth() throws {
        for depth in 1...6 {
            let (root, leaf) = try tree(depth: depth)
            defer { try? FileManager.default.removeItem(at: root) }
            let found = try #require(RepoRoot.search(from: leaf))
            #expect(sameFile(found, root), "depth \(depth) found \(found.path), expected \(root.path)")
        }
    }

    // A file sitting directly in the root is still inside it. An off-by-one that started the search
    // one level up would pass every deeper case and fail only this one.
    @Test func aFileInTheRootItselfFindsTheRoot() throws {
        let (root, _) = try tree(depth: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let found = try #require(RepoRoot.search(from: root.appendingPathComponent("Package.swift")))
        #expect(sameFile(found, root))
    }

    // The failure that has to be LOUD. A search that finds nothing must say so, never hand back a
    // plausible-looking path, because a wrong root does not fail: it silently scans an empty
    // directory and every guard standing on it reports that the app contains nothing (#1967).
    @Test func nothingIsFoundWhenTheMarkerIsAbsent() throws {
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-repo-\(UUID().uuidString)/a/b/c")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }

        #expect(RepoRoot.search(from: bare.appendingPathComponent("Stray.swift")) == nil)
    }

    // The nearest enclosing repo wins, not the outermost. A checkout inside a checkout (a worktree
    // under .claude/worktrees, which this repo really does create) must resolve to its OWN root, or
    // an agent's test would read the parent checkout's fixtures and pass against the wrong tree.
    @Test func theNearestEnclosingRootWinsOverAnOuterOne() throws {
        let (outer, _) = try tree(depth: 0)
        defer { try? FileManager.default.removeItem(at: outer) }
        let inner = outer.appendingPathComponent("worktrees/agent-1")
        try FileManager.default.createDirectory(
            at: inner.appendingPathComponent("mac/Overture"), withIntermediateDirectories: true)
        let leaf = inner.appendingPathComponent("mac/OvertureTests/SomeTests.swift")

        let found = try #require(RepoRoot.search(from: leaf))
        #expect(sameFile(found, inner), "found \(found.path), expected the inner checkout \(inner.path)")
    }

    // The one place a wrong root would NOT fail loudly, and therefore the one worth pinning.
    // `SourceGuardHelper.source` returns "" when it cannot read the file, so a bad path leaves every
    // `!source.contains(...)` guard standing on it passing vacuously. Dozens of guards read through
    // it, and not one of them would go red; they would simply stop protecting anything.
    @Test func theSharedSourceReaderReturnsRealFileContents() {
        let real = SourceGuardHelper.source("Overture/App/OvertureApp.swift")
        #expect(!real.isEmpty)
        #expect(real.contains("struct OvertureApp"))
    }

    // And the negative control, so the assertion above is known to be capable of failing: an unknown
    // path really does come back empty, which is what makes the emptiness above meaningful.
    //
    // The path is assembled at runtime rather than written as one literal, deliberately.
    // `SourceGuardCoverageGuardTests.everyReferencedSourcePathExists` scans this suite's SOURCE for
    // `SourceGuardHelper.source("...")` and fails on any path that does not exist, which is right and
    // which a literal here would trip: a test that needs a missing path and a guard that forbids
    // naming one are both correct, and the way to satisfy both is not to name it.
    @Test func theSharedSourceReaderIsEmptyForAPathThatIsNotThere() {
        let absent = ["Overture", "NoSuchDirectory-\(UUID().uuidString)", "NoSuchFile.swift"]
            .joined(separator: "/")
        #expect(SourceGuardHelper.source(absent).isEmpty)
    }

    // And against the real repository, which is the case every caller actually uses. Asserted by
    // what is THERE rather than by a path string, so it cannot pass by agreeing with its own idea
    // of the layout.
    @Test func theRealRepoRootHoldsWhatItShould() {
        let root = RepoRoot.url
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("fixtures").path))
        #expect(FileManager.default.fileExists(atPath: RepoRoot.mac.appendingPathComponent("project.yml").path))
        #expect(FileManager.default.fileExists(atPath: RepoRoot.app.appendingPathComponent("App/OvertureApp.swift").path))
    }
}
