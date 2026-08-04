import Foundation

// #1808: when Overture tells Dan the copy he is looking at is behind, and what it says.
//
// Dan chose the shape, 2026-08-03: "a pop up window that takes up most of the app screen. It can be
// dismissed." A quiet line was the other option and he did not want it, for a good reason: the whole
// failure is that he does not notice the gap, and a line he can miss is a line he will miss.
//
// The decision and the words live here, outside the view, so a wording rule cannot drift under a green
// suite and every sentence lands in `docs/copy-inventory.md` as words rather than as Swift.
enum BuildFreshnessPanel {
    // Dismissal lasts for THIS LAUNCH only, deliberately. A permanent dismissal would recreate exactly
    // the invisible gap this exists to close, and it would do it silently, which is worse than never
    // having built it: Dan would then be certain the app tells him, and it would not.
    static func shouldShow(_ verdict: BuildFreshness.Verdict, dismissedThisLaunch: Bool) -> Bool {
        guard !dismissedThisLaunch else { return false }
        switch verdict {
        case .upToDate: return false
        // Not knowing is shown, not swallowed. It means the mechanism itself is broken, and that is the
        // one state where saying nothing is indistinguishable from saying "you are up to date" (L11).
        case .behind, .cannotTell: return true
        }
    }

    // Where the installer built from, or nil when there is no record of an install. The Update button is
    // offered only when this answers, because a button that cannot act is worse than no button: it reads
    // as an update that ran and did nothing (#1778).
    static func repoPath(in directory: URL) -> String? {
        BuildFreshness.installedRecord(in: directory)?.repoPath
    }
}

enum BuildFreshnessCopy {
    static let title = "Overture is out of date"
    static let cannotTellTitle = "Overture cannot tell how old this copy is"

    static func body(_ verdict: BuildFreshness.Verdict) -> String {
        switch verdict {
        case .upToDate:
            // Nothing, because there is no panel: `shouldShow` refuses this case, so the only way to
            // reach this line is a caller that ignored it. Deliberately not a cheerful "you are up to
            // date" sentence, which would appear in `docs/copy-inventory.md` as something Overture can
            // say to Dan while being unreachable by construction.
            return ""
        case .behind(let installedAt, let shippedAt):
            let gap = PrepStatus.gap(from: installedAt, to: shippedAt)
            return "This copy is \(gap) behind what has shipped, so anything fixed since then is not in front of you."
        case .cannotTell(.noInstalledRecord):
            return "This copy did not come from the installer, so there is no record of what went into it."
        case .cannotTell(.noShippedRecord):
            return "Nothing has recorded a merge on this Mac, so there is nothing to compare this copy against."
        }
    }

    static func title(_ verdict: BuildFreshness.Verdict) -> String {
        if case .cannotTell = verdict { return cannotTellTitle }
        return title
    }

    static let update = "Update Overture"
    // What the button actually does, said before he presses it: the installer quits Overture partway
    // through and relaunches it, so the app vanishing mid-update is the update working, not a crash.
    static let updateNote = "This opens Terminal and runs the install. Overture quits partway through and comes back on its own."
    static let dismiss = "Not now"
    // Shown in place of the button when there is no record of where the code lives, so the panel never
    // offers an action it cannot carry out.
    static let cannotUpdate = "Ask Claude to reinstall Overture."
}
