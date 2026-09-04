import Testing
import Foundation

// #3113: `AppSourceWalk`'s empty-walk floor could be switched off by the caller it protects.
//
// The floor exists because a guard walking a broken path passes over every file it was written to
// check: #1967 had eleven tests reporting the app contained no user-facing copy at all. #2311
// consolidated six copies of that protection into one place. But the floor is a parameter, so
// `floor: 1` turns it off, and three real guards did exactly that.
//
// They all did it for the SAME honest reason, which is what makes this fixable rather than a matter
// of discipline: each walks SEVERAL roots of very different sizes and asserts a total across them, so
// no single per-root number fits. `TestDataEmailDomainGuardTests` walks four roots at `floor: 1`,
// `WaitUntilTests` three at `floor: 1`, and `TestWindowsAreNotReleasedOnCloseGuardTests` four at
// `floor: 0`, each then checking its own total by hand.
//
// So the answer is an API for what they are actually doing, rather than a rule telling people not to
// reach for the parameter. One floor over the TOTAL, applied by the walk, and a low floor on a root
// inside the repository refused outright. A guard that can be silently disabled by its caller is the
// shape #2311 existed to remove (L1, L103).
@Suite("The empty-walk floor cannot be switched off (#3113)")
struct AppSourceWalkFloorCannotBeSwitchedOffTests {
    private func tree(_ names: [String]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("walk-floor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in names {
            try "// \(n)".write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8)
        }
        return dir
    }

    // The shape all three offenders have: several roots, one floor over the total, so a root that
    // legitimately holds two files does not force the floor down to where it protects nothing.
    @Test func severalRootsShareOneFloorOverTheirTotal() throws {
        let roots = try [tree(["a.swift", "b.swift"]), tree(["c.swift"]), tree(["d.swift", "e.swift"])]
        defer { roots.forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(AppSourceWalk.files(underAll: roots, floor: 5).count == 5)
    }

    // And it REFUSES on the total, which is the half that makes it protection rather than a helper. A
    // per-root floor of 1 would have passed every one of those roots individually.
    @Test func theTotalIsWhatTheFloorIsCheckedAgainst() throws {
        let roots = try [tree(["a.swift"]), tree(["b.swift"])]
        defer { roots.forEach { try? FileManager.default.removeItem(at: $0) } }
        withKnownIssue("two files across two roots is under a floor of 10") {
            _ = AppSourceWalk.files(underAll: roots, floor: 10)
        }
    }

    // A floor low enough to protect nothing, on a root inside the REPOSITORY, is the protection being
    // switched off and says so. Pure, so the refusal itself is exercised rather than only watched not
    // to happen, which is how `refusal` is already written.
    @Test func aFloorTooLowToProtectAnythingIsRefusedOnARepoRoot() {
        #expect(AppSourceWalk.lowFloorRefusal(root: RepoRoot.app, floor: 1) != nil)
        #expect(AppSourceWalk.lowFloorRefusal(root: RepoRoot.app, floor: 0) != nil)
        #expect(AppSourceWalk.lowFloorRefusal(root: RepoRoot.app,
                                              floor: AppSourceWalk.minimumRepoFloor) == nil)
    }

    // A tree the TEST built is its own business: it knows exactly what it put there, so a floor of one
    // is a real assertion rather than a disabled one. Without this the rule would fire on every
    // fixture in `AppSourceWalkTests` and be switched off within a day (L93).
    @Test func aLowFloorOnATreeTheTestBuiltIsNotRefused() throws {
        let dir = try tree(["only.swift"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AppSourceWalk.lowFloorRefusal(root: dir, floor: 1) == nil)
    }

    // The guard that keeps it that way, over the tree rather than a list somebody maintains (L96).
    @Test func noGuardWalksARepoRootWithADisabledFloor() {
        var offenders: [String] = []
        var scanned = 0
        for file in AppSourceWalk.files(underAll: ["OvertureTests", "OvertureHostedTests", "TestSupport"]
            .map { RepoRoot.mac.appendingPathComponent($0) }, floor: 400) {
            scanned += 1
            guard file.name != "AppSourceWalkFloorCannotBeSwitchedOffTests.swift" else { continue }
            for line in file.text.components(separatedBy: "\n") {
                guard line.contains("RepoRoot") else { continue }
                for low in ["floor: 0", "floor: 1,", "floor: 1)"] where line.contains(low) {
                    offenders.append("\(file.name): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(scanned > 400, "the scan read only \(scanned) files, so it measured nothing")
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
