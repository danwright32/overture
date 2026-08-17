import Foundation

// #2838: where the three detached runner scripts are, derived from ONE place rather than kept current in
// six.
//
// The app stores the ABSOLUTE path of each runner script in UserDefaults, one key per script per domain,
// six entries in all. Every one of them holds the same checkout path with a different filename on the end,
// and the value lives OUTSIDE the repo, so no code change, test or guard in this repository can notice one
// has gone stale. Moving the checkout invalidates all six at once, and Dan wants to move it (out of
// `Photography Assets`, alongside the four other projects that left iCloud Drive on 2026-08-16). This is
// L153: a path recording where something HAPPENED to be, rather than what it is.
//
// The root is derived from the thing that already knows: `installed-build.json` carries `repoPath`, the
// checkout `mac/build-install.sh` built the bundle from, written afresh at every install. So a move plus a
// reinstall corrects all three scripts with nobody typing a path, and the installer writes the defaults
// too, so a fresh Mac needs no manual step at all.
//
// The stored per-script default still WINS while it names a runnable script, deliberately: pointing the
// app at a script in another checkout is a real thing to do, and this must not quietly override it. What
// it no longer does is win while pointing at nothing, which is exactly the state a move produces.
//
// Pure, given the two inputs, so every branch is reachable from a test without touching UserDefaults or
// Dan's Application Support folder (L2).
enum RunnerScripts {
    // The three detached runs, each naming the script it launches and the legacy default it reads.
    enum Runner: String, CaseIterable, Sendable {
        case prep
        case replyClassify
        case scoutExtract

        var scriptName: String {
            switch self {
            case .prep: return "prep-run.sh"
            case .replyClassify: return "reply-classify-run.sh"
            case .scoutExtract: return "scout-extract-run.sh"
            }
        }

        // The per-script UserDefaults key, unchanged from before #2838 so nothing in Dan's defaults, in
        // the runbooks or in a running app has to be migrated for this to ship.
        var defaultsKey: String {
            switch self {
            case .prep: return "prepRunnerScriptPath"
            case .replyClassify: return "replyClassifyRunnerScriptPath"
            case .scoutExtract: return "scoutExtractRunnerScriptPath"
            }
        }

        // What the runbooks call this run, for a message naming what is wrong.
        var displayName: String {
            switch self {
            case .prep: return "Prep"
            case .replyClassify: return "reply-classify"
            case .scoutExtract: return "scout-extract"
            }
        }
    }

    // Where a runner script was looked for and why that answer was chosen. Kept apart rather than folded
    // into an optional path, because "nobody has configured this" and "the configured path points at
    // nothing" are different facts and only the second one names a value to correct (L11).
    enum Resolution: Equatable, Sendable {
        // The stored per-script default names a runnable script. It wins.
        case configured(URL)
        // The stored default is unusable (unset, empty, or naming nothing runnable) and the root the
        // installer recorded gives a runnable script.
        case derivedFromInstalledRepo(URL)
        // Both routes were tried and neither produced a runnable script. Carries what each one was, so
        // the message can name the setting AND what it points at.
        case unavailable(configuredPath: String?, derivedPath: String?)
    }

    // The rule. `isRunnable` is injected so a test drives every branch without a file system.
    static func resolve(_ runner: Runner,
                        configuredPath: String?,
                        installedRepoPath: String?,
                        isRunnable: (String) -> Bool) -> Resolution {
        let configured = (configuredPath?.isEmpty == false) ? configuredPath : nil
        if let configured, isRunnable(configured) {
            return .configured(URL(fileURLWithPath: configured))
        }
        let derived = installedRepoPath.map { derivedPath(for: runner, repoPath: $0) }
        if let derived, isRunnable(derived) {
            return .derivedFromInstalledRepo(URL(fileURLWithPath: derived))
        }
        return .unavailable(configuredPath: configured, derivedPath: derived)
    }

    // The one place the layout of the checkout is written down.
    static func derivedPath(for runner: Runner, repoPath: String) -> String {
        URL(fileURLWithPath: repoPath)
            .appendingPathComponent("mac")
            .appendingPathComponent("scripts")
            .appendingPathComponent(runner.scriptName)
            .path
    }

    // What to say when neither route worked. It names the SETTING and WHAT IT POINTS AT, rather than a
    // generic "the runner is unavailable", because the two ways to end up here need different actions and
    // a message that cannot tell them apart sends Dan to the wrong one (#2838, L11, L80).
    static func unavailableMessage(_ runner: Runner,
                                   configuredPath: String?,
                                   derivedPath: String?) -> String {
        let name = runner.displayName
        if let configuredPath {
            return "Couldn't find the \(name) runner. \(runner.defaultsKey) points at "
                + "\(configuredPath), and there is no runnable script there. If the checkout moved, "
                + "reinstall Overture from it (cd mac && ./build-install.sh) and that setting is "
                + "rewritten for you."
        }
        if let derivedPath {
            return "Couldn't find the \(name) runner. \(runner.defaultsKey) is not set, and the "
                + "checkout the installed build came from has no runnable script at \(derivedPath). "
                + "Reinstall Overture from the checkout (cd mac && ./build-install.sh)."
        }
        return "Couldn't find the \(name) runner. \(runner.defaultsKey) is not set and this copy of "
            + "Overture has no record of which checkout it was built from, so there is nowhere to look. "
            + "Install it with cd mac && ./build-install.sh."
    }
}
