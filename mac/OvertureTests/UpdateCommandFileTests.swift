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

    // #2188: the script tells the run which press it belongs to, and the press hands that same id back
    // to whoever is watching. Both halves are needed for the app to learn how the update went: without
    // the id in the script the run has nothing to stamp its record with, and without it coming back the
    // app cannot tell its own press's outcome from a record left by an earlier one.
    @Test func theScriptTellsTheRunWhichPressItBelongsTo() {
        let script = UpdateCommandFile.script(repoPath: "/code/overture", scriptPath: "/tmp/x.command",
                                              press: "press-1")

        #expect(script.contains("OVERTURE_UPDATE_PRESS=\"press-1\""))
        // Exported before the update is invoked, or the run cannot see it at all.
        let lines = script.split(separator: "\n").map(String.init)
        let pressLine = try? #require(lines.firstIndex { $0.contains("OVERTURE_UPDATE_PRESS") })
        let runLine = try? #require(lines.firstIndex { $0.contains("update-overture.sh") })
        #expect((pressLine ?? 0) < (runLine ?? 0))
    }

    @MainActor @Test func openingHandsBackTheIdTheScriptCarries() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var opened: URL?
        let press = UpdateCommandFile.open(repoPath: "/code/overture", in: dir, token: "tok-9") { opened = $0 }

        #expect(press == "tok-9")
        let written = try String(contentsOf: try #require(opened), encoding: .utf8)
        #expect(written.contains("OVERTURE_UPDATE_PRESS=\"tok-9\""),
                "the id handed back has to be the one the run will stamp its record with, or the app watches for an outcome nothing will ever write")
    }

    // A press that could not be written reports nothing rather than an id, so nothing goes off waiting
    // for the outcome of a run that was never started.
    @MainActor @Test func aPressThatCouldNotBeWrittenHandsBackNothing() {
        let missing = URL(fileURLWithPath: "/nowhere/at/all/\(UUID().uuidString)")
        var opened = false
        let press = UpdateCommandFile.open(repoPath: "/code/overture", in: missing) { _ in opened = true }

        #expect(press == nil)
        #expect(opened == false)
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

    // #2146, the defect this file exists to prevent now.
    //
    // Dan pressed Update and nothing installed. His copy stayed nine commits behind and he had to run the
    // installer by hand. Terminal treats a .command as a DOCUMENT, and the previous run's window was still
    // sitting open at "[Process completed]" holding that exact path, so asking macOS to open the same path
    // again ACTIVATED that finished window instead of running anything. The button read as an update that
    // ran (L12), and it stays broken for as long as a finished window is open, which is Terminal's default.
    //
    // So every press gets a path macOS has never seen. This is the assertion that fails if the fixed
    // filename ever comes back.
    @Test func eachPressGetsAPathMacOSHasNotSeenBefore() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try #require(UpdateCommandFile.write(repoPath: "/code/overture", in: dir))
        let second = try #require(UpdateCommandFile.write(repoPath: "/code/overture", in: dir))

        #expect(first != second, "a second press on the same path reopens the old window instead of running")
    }

    // Ten presses, ten distinct paths, so this cannot pass by two names happening to differ once.
    @Test func repeatedPressesNeverRepeatAPath() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var seen = Set<String>()
        for _ in 0..<10 {
            let url = try #require(UpdateCommandFile.write(repoPath: "/code/overture", in: dir))
            #expect(!seen.contains(url.path))
            seen.insert(url.path)
        }
        #expect(seen.count == 10)
    }

    // The script still names ITSELF for removal, whatever it is called this time, or a unique name would
    // trade one leftover for a growing pile.
    @Test func eachScriptRemovesItsOwnUniqueSelf() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try #require(UpdateCommandFile.write(repoPath: "/code/overture", in: dir))
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("rm -f -- \"\(url.path)\""))
    }

    // And the sweep clears a FAMILY of them, not one known name, since there is no longer a single name to
    // look for. This is the property the fixed filename was originally chosen to guarantee.
    @Test func theSweepClearsEveryLeftoverNotJustOneName() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Three dead runs, as if the machine slept mid-update three times.
        var leftovers: [URL] = []
        for _ in 0..<3 {
            let url = try #require(UpdateCommandFile.write(repoPath: "/code/overture", in: dir,
                                                           sweepingFirst: false))
            leftovers.append(url)
        }
        #expect(Set(leftovers.map(\.path)).count == 3)
        let bystander = dir.appendingPathComponent("something-else.command-ish.json")
        try "{}".write(to: bystander, atomically: true, encoding: .utf8)

        UpdateCommandFile.sweep(in: dir)

        for url in leftovers {
            #expect(!FileManager.default.fileExists(atPath: url.path), "left behind: \(url.lastPathComponent)")
        }
        #expect(FileManager.default.fileExists(atPath: bystander.path),
                "the sweep must not reach beyond its own files")
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
