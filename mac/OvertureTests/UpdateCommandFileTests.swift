import Testing
import Foundation

// #1808: the update itself is a terminal command, and Dan does not work in a terminal. The panel's
// button writes a small executable script and asks macOS to open it, which lands in a new Terminal
// window with the command already running. Opening a document needs no automation permission, unlike
// driving Terminal by AppleScript.
//
// Dan's rule for it, 2026-08-03: "If it creates a temp file it should delete it when we're done." It is
// cleaned up TWICE, because the update quits Overture partway through and so the app cannot be the one
// to tidy up afterwards: the script removes itself as its last act, and any leftover from a run that
// died before reaching that line is swept at the next launch. One fixed filename, so a leftover is
// always the file the sweep looks for rather than one of a growing pile.
@Suite("The update command file (#1808)")
struct UpdateCommandFileTests {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("update-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - What the script says

    // Update means "get me the code that has shipped", so it runs the update path, which brings the
    // checkout up to date and only then installs. Running the installer directly builds whatever commit
    // happens to be checked out, which is what put Dan in a loop on 2026-08-04: he pressed Update, the
    // same commit was rebuilt, and the panel went on being right that his copy was behind.
    @Test func itRunsTheUpdateInTheRepoTheInstallerRecorded() {
        let script = UpdateCommandFile.script(repoPath: "/code/overture", scriptPath: "/tmp/x.command")

        #expect(script.contains("/code/overture/mac"))
        #expect(script.contains("scripts/update-overture.sh"))
        #expect(script.contains("./build-install.sh") == false,
                "Installing directly builds whatever is checked out, which cannot resolve a copy that is behind.")
    }

    // The cleanup Dan asked for, as the script's own last act, because by then Overture has been quit
    // and relaunched by the installer and cannot tidy up after itself.
    @Test func itRemovesItselfWhenItIsDone() {
        let script = UpdateCommandFile.script(repoPath: "/code/overture", scriptPath: "/tmp/x.command")

        #expect(script.contains("rm -f -- \"/tmp/x.command\""))
        let lines = script.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        #expect(lines.last?.contains("rm -f --") == true,
                "the removal is the last thing it does, so a failed install still cleans up")
    }

    // A repo path with a space in it is the normal case here, not an edge one: Dan's checkout lives
    // under "Photography Assets/Dan Wright Photography". Unquoted, the script would cd nowhere.
    @Test func aPathWithSpacesIsQuoted() {
        let script = UpdateCommandFile.script(repoPath: "/Users/dan/Photography Assets/Overture",
                                              scriptPath: "/tmp/my temp/x.command")

        #expect(script.contains("\"/Users/dan/Photography Assets/Overture/mac\""))
        #expect(script.contains("\"/tmp/my temp/x.command\""))
    }

    // MARK: - Writing it

    @Test func itIsWrittenExecutableSoTerminalCanRunIt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try #require(UpdateCommandFile.write(repoPath: "/code/overture", in: dir))

        #expect(FileManager.default.fileExists(atPath: url.path))
        let perms = try #require(try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        #expect(perms.int16Value & 0o100 != 0, "a .command Terminal will not run is a dead button")
    }

    // Written twice, one file: a second press must not leave the first one behind.
    @Test func writingTwiceLeavesOneFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = UpdateCommandFile.write(repoPath: "/code/overture", in: dir)
        _ = UpdateCommandFile.write(repoPath: "/code/overture", in: dir)

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents.filter { $0.hasSuffix(".command") }.count == 1)
    }

    // MARK: - The sweep

    // The crash path: the update died before the script reached its own removal, so the file is still
    // there at the next launch. Nothing else in the folder may be touched.
    @Test func aLeftoverFromADeadRunIsSweptAtLaunch() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let leftover = try #require(UpdateCommandFile.write(repoPath: "/code/overture", in: dir))
        let bystander = dir.appendingPathComponent("something-else.json")
        try "{}".write(to: bystander, atomically: true, encoding: .utf8)

        UpdateCommandFile.sweep(in: dir)

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: bystander.path))
    }

    // Sweeping when there is nothing to sweep is the ordinary case (every launch after a clean update),
    // so it must be silent rather than an error.
    @Test func sweepingAnEmptyDirectoryDoesNothing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        UpdateCommandFile.sweep(in: dir)

        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
