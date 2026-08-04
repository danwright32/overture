import Foundation
import AppKit

// #1808: the button that actually updates Overture.
//
// Updating is `mac/scripts/update-overture.sh`, a terminal command, and Dan does not work in a terminal.
// So the panel writes a small executable script and asks macOS to open it, which lands in a NEW Terminal
// window with the command already running.
//
// It runs the UPDATE path, not the installer directly. Pressing Update means "get me the code that has
// shipped"; running the installer means "build what is here". On 2026-08-04 those were the same command,
// so pressing Update on a checkout parked on an already-merged branch rebuilt the same commit, and the
// panel went on correctly reporting the copy as behind: a loop with no way out from inside the app. Opening a document is all that needs (no automation permission),
// unlike driving Terminal through AppleScript, which would put a TCC prompt in front of somebody who just
// wanted a newer app.
//
// Cleanup is Dan's requirement, 2026-08-03: "If it creates a temp file it should delete it when we're
// done." It happens TWICE, because the installer QUITS Overture partway through (build-install.sh
// osascript-quits a running copy before replacing the bundle) and relaunches it, so the app that wrote
// the file is not around to tidy up afterwards:
//
//  1. the script removes itself as its own last act, so an ordinary run leaves nothing behind;
//  2. `sweep` runs at launch, so a run that DIED before reaching that line (the machine slept, the build
//     failed hard, Terminal was closed mid-run) still leaves nothing sitting there.
//
// One fixed filename, never a unique temp name, so a leftover is always the file the sweep looks for
// rather than one of a growing pile nobody is counting.
enum UpdateCommandFile {
    static let filename = "overture-update.command"

    // Where it goes: the per-user temp directory, which is stable across launches (so the sweep can find
    // a leftover) and is not Overture's data directory, whose contents are a published contract.
    static var directory: URL { URL(fileURLWithPath: NSTemporaryDirectory()) }

    // The script itself. `scriptPath` is passed in rather than read from `$0` so the removal names an
    // absolute path this code chose, and so the composition is testable without writing a file.
    //
    // Both paths are quoted: Dan's checkout lives under "Photography Assets/Dan Wright Photography", so a
    // path with spaces is the normal case here, not an edge one, and unquoted it would cd nowhere.
    // copy-inventory:ignore-start  a shell script for Terminal, not Overture's voice to Dan (#915)
    static func script(repoPath: String, scriptPath: String) -> String {
        """
        #!/bin/sh
        # Written by Overture (#1808) to update itself. It deletes itself when it finishes.
        set -e
        cd "\(repoPath)/mac"
        ./scripts/update-overture.sh
        rm -f -- "\(scriptPath)"
        """
    }
    // copy-inventory:ignore-end

    // Writes the script executable and returns where it went, or nil if it could not be written (in which
    // case the caller must not claim it opened anything).
    @discardableResult
    static func write(repoPath: String, in directory: URL = UpdateCommandFile.directory) -> URL? {
        let url = directory.appendingPathComponent(filename)
        // Removed first rather than overwritten, so a second press cannot leave a half-written file with
        // the old contents' tail on the end.
        try? FileManager.default.removeItem(at: url)
        guard (try? script(repoPath: repoPath, scriptPath: url.path)
                .write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        // Terminal will not run a .command that is not executable, and a dead button is worse than no
        // button: it looks like the update ran.
        guard (try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path))
                != nil else { return nil }
        return url
    }

    // Removes a leftover from a run that never reached its own `rm`. Silent when there is nothing there,
    // which is the ordinary case at every launch after a clean update.
    static func sweep(in directory: URL = UpdateCommandFile.directory) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }

    // Writes it and hands it to macOS, which opens a `.command` in Terminal and runs it. Does nothing if
    // the file could not be written, rather than opening something that is not there: a button that
    // silently fails reads as an update that ran (L12).
    @MainActor
    static func open(repoPath: String, in directory: URL = UpdateCommandFile.directory,
                     opener: (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        guard let url = write(repoPath: repoPath, in: directory) else { return }
        opener(url)
    }
}
