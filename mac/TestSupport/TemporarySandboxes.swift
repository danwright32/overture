import Foundation

/// Throwaway directories that do not outlive the test run that made them.
///
/// Hold one as a property of a suite. Swift Testing builds a fresh instance of a `final class` suite for
/// every test and releases it when that test ends, pass or fail, so `deinit` here is real per-test
/// teardown and every directory handed out during that test goes with it.
///
/// #3065. Measured on this Mac 2026-08-22, on an uptime of 8 days and counting only the shapes this
/// repo's tests create: 952 `debug-seed-test`, 560 `census`, 336 `prep-results`, 224 `prep-reply-cancel`,
/// 224 `performer-failure`, 112 each of `scout-snapshot`, `scout-extract-cancel` and `overture-test`,
/// and 56 each of `venue-identity`, `no-repo`, `debug-seed-missing` and `debug-seed-gmail-missing`. Every
/// count is a multiple of 56, which is how many times the suite had run, so the per-run leak is about 52
/// directories. `venue-identity` sandboxes ran to roughly 4 MB each. macOS clears the per-user temp
/// folder only at boot, so nothing else was ever going to remove them, and this repo amplifies it by
/// running its suite from worktrees, many copies against the one shared folder.
///
/// WHY THE CLEANUP LIVES HERE rather than in a `defer` at each call site. Downbeat had the identical bug
/// and the static read was actively misleading there: 96 `createDirectory` calls against 95 `defer`
/// cleanups, which reads as balanced, while the suite leaked 52 directories per run. One private helper
/// called by many tests had left 7,616 directories on its own. Overture has 166 `createDirectory` call
/// sites across 136 files, so counting them would say just as little here. A `defer` beside each call is
/// a rule every future test has to remember, which is a rule living in a prompt (L27). This one cannot be
/// forgotten: a suite that takes a sandbox from here has already opted in to losing it.
///
/// WHAT THIS RESTS ON, and it is worth knowing because nothing announces it: `deinit` is real teardown
/// only if the suite instance is actually RELEASED. A suite that leaves a retain cycle behind, or parks
/// one of its objects in a singleton, is never released, so this cleanup never runs and the sandbox stays
/// for ever. It fails silently and it fails per test rather than per suite, so most of a suite can clean
/// up perfectly while a few instances leak, which is exactly what makes it invisible. Downbeat measured
/// that: five of eighteen `CommitInFlightStatusTests` instances were held by a cycle and the other
/// thirteen were fine. `scripts/check-temp-dir-leaks.sh` is what catches it, and it can only catch it
/// because every sandbox carries a prefix naming what made it.
///
/// The names are deliberately `<prefix>-<uuid>`. That is what makes a stray directory attributable to
/// this repo at all, and it is the shape `scripts/check-temp-dir-leaks.sh` judges by. A sandbox built as
/// a bare UUID cannot be told apart from any other application's scratch, so it would be exempt from the
/// very check meant to catch it (L96).
final class TemporarySandboxes {

    private var created: [URL] = []
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// A new empty directory under the per-user temp folder, owned by this instance.
    ///
    /// - Parameter name: the prefix the directory carries, so a leak can be traced back to the suite
    ///   that made it. A UUID is appended.
    @discardableResult
    func make(named name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        created.append(url)
        return url
    }

    /// A path under the temp folder that is RECORDED for cleanup but deliberately NOT created.
    ///
    /// For the tests whose subject is code that has to create a directory itself: several suites here
    /// assert that seeding, or a store move, creates its destination when absent, so handing them an
    /// already-created sandbox would remove the very condition under test. The path is still owned, so
    /// whatever the code under test creates there is still removed afterwards.
    func reserve(named name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        created.append(url)
        return url
    }

    /// A path INSIDE a fresh sandbox, for the tests whose subject is a single file rather than a
    /// directory. The file itself need never exist; the directory holding it is what gets cleaned up.
    ///
    /// This exists because several of the measured shapes are files, not directories
    /// (`prep-results-<uuid>.json`, `overture-test-<uuid>.store` and the `-wal`/`-shm` SQLite leaves
    /// beside it). Handing those a bare temp path is what left the `-wal` and `-shm` files behind after
    /// the `.store` itself had been removed: a cleanup naming ONE file cannot know about the two the
    /// database engine created next to it, while a cleanup of the directory around it does not have to.
    func makeFile(named name: String, inSandboxNamed sandboxName: String) throws -> URL {
        try make(named: sandboxName).appendingPathComponent(name)
    }

    /// Every directory this instance handed out, not merely the last one. A cleanup that kept a single
    /// URL would pass a one-sandbox test and leak all the rest, which is the failure being fixed here.
    ///
    /// `try?` per entry rather than around the loop: one directory that cannot be removed (a test that
    /// already removed it itself, a permission the test changed) must not abandon the ones after it. A
    /// `deinit` has nowhere to throw to in any case.
    deinit {
        for url in created {
            try? fileManager.removeItem(at: url)
        }
    }
}
