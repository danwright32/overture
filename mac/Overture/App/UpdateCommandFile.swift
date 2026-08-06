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
// #2146: every press gets its OWN filename, and that is load-bearing rather than tidiness.
//
// This used to be one fixed filename, chosen so a leftover was always the file the sweep looks for rather
// than one of a growing pile nobody counts. That choice is what broke the button. Terminal treats a
// .command as a DOCUMENT: on 2026-08-05 the previous run's window was still open at "[Process completed]"
// holding that exact path, so asking macOS to open it again ACTIVATED the finished window instead of
// running anything. Dan's copy stayed nine commits behind and he had to run the installer by hand. The
// button is the only route to new code that does not involve a terminal, and it stayed dead for as long
// as a finished window sat open, which is Terminal's default setting.
//
// The pile the fixed name was protecting against is prevented two other ways instead, so nothing is
// traded away: `write` sweeps its own family before writing the new one, and `sweep` matches the PREFIX
// rather than one known name.
enum UpdateCommandFile {
    static let prefix = "overture-update-"
    static let fileExtension = "command"

    static func filename(token: String) -> String { "\(prefix)\(token).\(fileExtension)" }

    // Whether a file in the temp directory is one of ours. Both halves are required: the prefix alone
    // would sweep a differently-suffixed neighbour, and the extension alone would sweep any .command.
    static func isOurs(_ name: String) -> Bool {
        name.hasPrefix(prefix) && name.hasSuffix(".\(fileExtension)")
    }

    // Where it goes: the per-user temp directory, which is stable across launches (so the sweep can find
    // a leftover) and is not Overture's data directory, whose contents are a published contract.
    static var directory: URL { URL(fileURLWithPath: NSTemporaryDirectory()) }

    // The script itself. `scriptPath` is passed in rather than read from `$0` so the removal names an
    // absolute path this code chose, and so the composition is testable without writing a file.
    //
    // Both paths are quoted: Dan's checkout lives under "Photography Assets/Dan Wright Photography", so a
    // path with spaces is the normal case here, not an edge one, and unquoted it would cd nowhere.
    // copy-inventory:ignore-start  a shell script for Terminal, not Overture's voice to Dan (#915)
    static func script(repoPath: String, scriptPath: String, press: String = "") -> String {
        """
        #!/bin/sh
        # Written by Overture (#1808) to update itself. It deletes itself when it finishes.
        set -e
        cd "\(repoPath)/mac"
        OVERTURE_UPDATE_PRESS="\(press)"
        export OVERTURE_UPDATE_PRESS
        ./scripts/update-overture.sh
        rm -f -- "\(scriptPath)"
        """
    }
    // copy-inventory:ignore-end

    // Writes the script executable and returns where it went, or nil if it could not be written (in which
    // case the caller must not claim it opened anything).
    // `token` is injected so a test can name the file, and defaults to a UUID rather than a timestamp:
    // uniqueness is the whole requirement, and two presses inside the same second must still differ.
    // `sweepingFirst` exists so a test can stage several leftovers; the app always sweeps.
    @discardableResult
    static func write(repoPath: String, in directory: URL = UpdateCommandFile.directory,
                      token: String = UUID().uuidString, sweepingFirst: Bool = true) -> URL? {
        // The previous press's file goes now rather than being left for the launch sweep, so a unique
        // name cannot become the growing pile the fixed name was chosen to prevent.
        if sweepingFirst { sweep(in: directory) }
        let url = directory.appendingPathComponent(filename(token: token))
        // Removed first rather than overwritten, so a second press cannot leave a half-written file with
        // the old contents' tail on the end.
        try? FileManager.default.removeItem(at: url)
        // The press id IS the filename's token (#2188). One id for the file and the run it starts, so
        // the outcome the app waits for cannot belong to a different press than the one it made.
        guard (try? script(repoPath: repoPath, scriptPath: url.path, press: token)
                .write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        // Terminal will not run a .command that is not executable, and a dead button is worse than no
        // button: it looks like the update ran.
        guard (try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path))
                != nil else { return nil }
        return url
    }

    // Removes leftovers from runs that never reached their own `rm`. Silent when there is nothing there,
    // which is the ordinary case at every launch after a clean update.
    //
    // #2146: matches the PREFIX, because there is no single name to look for any more. Everything it
    // removes is a file this type wrote, and a neighbour in the shared temp directory is never touched.
    static func sweep(in directory: URL = UpdateCommandFile.directory) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where isOurs(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // Writes it and hands it to macOS, which opens a `.command` in Terminal and runs it. Does nothing if
    // the file could not be written, rather than opening something that is not there: a button that
    // silently fails reads as an update that ran (L12).
    @MainActor
    // #2188: returns the id of the press it just made, so the caller can watch for THAT run's outcome,
    // or nil when nothing was opened. Nil is what stops the app waiting on a run that never existed.
    @discardableResult
    static func open(repoPath: String, in directory: URL = UpdateCommandFile.directory,
                     token: String = UUID().uuidString,
                     opener: (URL) -> Void = { NSWorkspace.shared.open($0) }) -> String? {
        guard let url = write(repoPath: repoPath, in: directory, token: token) else { return nil }
        opener(url)
        return token
    }
}
