import Foundation

// Where the repository is, found by looking for it (#1993).
//
// The tests used to answer this by climbing a hard-coded number of directories from `#filePath`,
// with the levels spelled out in comments (`// OvertureTests`, `// mac`, `// repo root`), in 53
// files. That count is a hand-maintained fact sitting beside its real source of truth, the actual
// directory layout, and it breaks SILENTLY when the layout moves.
//
// #1967 is the proof: moving `CopyInventory.swift` from `OvertureTests/Support/` to `TestSupport/`
// left its four-level climb pointing ABOVE the repo. Nothing failed loudly. The scan simply found
// zero files, and eleven tests reported that the app contains no user-facing copy, which reads as a
// finding about the product rather than as a broken path.
//
// So it searches for the thing it is actually looking for. Moving a file cannot break it, and when
// the layout genuinely changes so that nothing is found, it stops with a message naming the path it
// started from instead of quietly scanning nothing.
enum RepoRoot {

    // What identifies this repository, rather than any directory that happens to be above it. Both
    // components are required together: `mac` alone is a common enough name to match by accident.
    static let marker = "mac/Overture"

    // The nearest enclosing directory holding the marker, searching upward from `start`, or nil.
    //
    // NEAREST, not outermost, and that matters here specifically: this repo creates agent worktrees
    // UNDER its own checkout (`.claude/worktrees/`), so an outermost-wins search would make every
    // test in a worktree read the parent checkout's fixtures and pass against the wrong tree.
    //
    // Pure enough to test: it is handed the path to start from, so a fixture can build a throwaway
    // tree at any depth and ask the same question the real callers ask.
    static func search(from start: URL) -> URL? {
        var dir = start.deletingLastPathComponent()
        while dir.path != "/" && !dir.path.isEmpty {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(marker).path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }   // never spin on a path that cannot climb further
            dir = parent
        }
        return nil
    }

    // The repo root, for a caller that just wants it. Halts rather than returning a guess: every
    // caller uses this to read a file, and a wrong root turns "the path is broken" into "the file
    // has nothing in it", which is the #1967 failure this whole file exists to prevent.
    static var url: URL {
        let start = URL(fileURLWithPath: #filePath)
        guard let found = search(from: start) else {
            fatalError("""
                RepoRoot could not find the repository above \(start.path). It looks for a directory \
                containing \(marker). If the repository layout changed, this is the line to update, \
                and it is the ONLY place that needs to change.
                """)
        }
        return found
    }

    // The two directories callers ask for by name often enough to be worth naming here, so no caller
    // has to know how they sit relative to the root either.
    static var mac: URL { url.appendingPathComponent("mac") }
    static var app: URL { url.appendingPathComponent("mac/Overture") }
}
