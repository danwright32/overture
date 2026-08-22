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
        // #2553: and a branch build is shown for a stronger version of the same reason. It is the state
        // that used to render as "up to date", and the copy saying it is running against the real store.
        case .behind, .cannotTell, .builtFromABranch: return true
        }
    }

    // Where the installer built from, or nil when there is no record of an install. The Update button is
    // offered only when this answers, because a button that cannot act is worse than no button: it reads
    // as an update that ran and did nothing (#1778).
    static func repoPath(in directory: URL) -> String? {
        BuildFreshness.installedRecord(in: directory)?.repoPath
    }
}

// #2065: WHEN the two records are read.
//
// They used to be read exactly once, in `OvertureApp.init`, and that answer was pinned for the life of
// the process. It cost Dan the whole feature on 2026-08-04: the installer bootstrapped the login agent
// (which launches Overture) BEFORE writing its record, so the app's one read landed in the same second
// the installer was still writing, saw nothing, and was still saying "This copy did not come from the
// installer... Ask Claude to reinstall Overture" two hours later with both records sitting on disk.
// The installer's order is fixed too, but a launch-pinned verdict was wrong on its own terms anyway: it
// also cannot see a merge that lands while he works.
//
// So the answer is re-read, and the rule for how often is here rather than in the view. Not on a render
// pass: the installed commit genuinely cannot change while this process runs, so paying for it per frame
// would be paying repeatedly for an answer that mostly does not move (#1916, an idle surface pays
// nothing). At most one read per `refreshInterval`, whatever asks: the window appearing, Overture coming
// to the front, or the slow tick that `watch()` runs while it sits open.
@MainActor
@Observable
final class BuildFreshnessState {
    // Dan asked for the periodic re-check, 2026-08-04. Fifteen minutes: this is a notice about work that
    // merged, which is never urgent to the minute, and every read is two small files.
    static let refreshInterval: TimeInterval = 15 * 60

    @ObservationIgnored private let read: @MainActor () -> (BuildFreshness.Verdict, String?)
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async -> Void
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private var lastReadAt: Date?

    // nil until something has actually looked. Deliberately not defaulted to `.cannotTell`, which would
    // have the panel stating the failure before any check had run, and that sentence (L11) may only claim
    // what a check measured.
    private(set) var verdict: BuildFreshness.Verdict?
    private(set) var repoPath: String?

    // What "Not now" was answering. A dismissal covers the news it was shown for, so an unchanged
    // verdict stays quiet (a panel taking most of the window, reappearing because a timer fired, would
    // be that dismissal ignored) while a merge landing AFTERWARDS is different news and is raised
    // again. Dan's call, 2026-08-04. Never persisted: a dismissal that outlived the launch would
    // quietly recreate the gap this exists to close.
    private var dismissedVerdict: BuildFreshness.Verdict?

    init(reader: @escaping @MainActor () -> (BuildFreshness.Verdict, String?),
         sleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.read = reader
        self.sleep = sleep
        self.clock = now
    }

    // The directory is passed in rather than resolved here, so a test can never read Dan's real
    // Application Support folder (L2).
    convenience init(directory: URL,
                     sleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
                     now: @escaping @MainActor () -> Date = { Date() }) {
        self.init(reader: { (BuildFreshness.verdict(in: directory), BuildFreshnessPanel.repoPath(in: directory)) },
                  sleep: sleep, now: now)
    }

    var shouldShow: Bool {
        guard let verdict else { return false }
        return BuildFreshnessPanel.shouldShow(verdict, dismissedThisLaunch: verdict == dismissedVerdict)
    }

    // "Not now", against whatever the panel is currently saying.
    func dismiss() {
        dismissedVerdict = verdict
    }

    // Reads the records if nothing has read them within the interval. Safe to call from anywhere and as
    // often as anything likes: that is the point of the rule living here rather than at each caller.
    func refreshIfStale(now: Date = Date()) {
        if let lastReadAt, now.timeIntervalSince(lastReadAt) < Self.refreshInterval { return }
        (verdict, repoPath) = read()
        lastReadAt = now
    }

    // The slow tick, for the whole point of a resident app: Overture sits open for days, and a merge
    // landing during one of them should reach the panel without Dan doing anything.
    func watch() async {
        while !Task.isCancelled {
            await sleep(Self.refreshInterval)
            if Task.isCancelled { return }
            refreshIfStale(now: clock())
        }
    }
}

enum BuildFreshnessCopy {
    static let title = "Overture is out of date"
    static let cannotTellTitle = "Overture cannot tell how old this copy is"
    // #2553: its own title, because a branch build is not merely old. Old is fixed by catching up; this
    // copy was never what shipped.
    static let branchBuildTitle = "This copy was built from unmerged code"
    // And a third title, because the two new reasons are about WHERE this copy came from, not how old it
    // is. Reusing the age title over a sentence about provenance would have the two halves of the panel
    // answering different questions.
    static let cannotTellProvenanceTitle = "Overture cannot tell where this copy came from"

    // #2187: how far behind the copy is, which is time from the SHIPPED commit to now.
    //
    // It used to be the span between the two commit dates, and that is a different question wearing the
    // same word. On 2026-08-06 Dan's copy was built at 9:52pm and main's tip had landed at 12:46am, so at
    // 9:56am the panel said "2h behind" about code that had shipped nine hours earlier, and he read it as
    // something having shipped that morning. Worse than the wrong number is that it could not move: both
    // its ends were in the past, so it would still have said "2h" a week later while the copy fell
    // further and further behind, and nothing about a frozen number looks broken.
    //
    // The fallback is for a clock that disagrees with the commit it is reading (a skewed Mac, a commit
    // dated ahead). Then the span between the commits is used instead: it is the one thing still known
    // to be true without a clock, and it is never negative, because `.behind` exists only when the
    // installed commit is older. Naively subtracting would floor at "0m behind", which reads as up to
    // date on the single screen whose whole job is to say otherwise.
    static func behindBy(installedAt: Date, shippedAt: Date, now: Date) -> String {
        guard now > shippedAt else { return PrepStatus.gap(from: installedAt, to: shippedAt) }
        return PrepStatus.gap(from: shippedAt, to: now)
    }

    static func body(_ verdict: BuildFreshness.Verdict, now: Date = Date()) -> String {
        switch verdict {
        case .upToDate:
            // Nothing, because there is no panel: `shouldShow` refuses this case, so the only way to
            // reach this line is a caller that ignored it. Deliberately not a cheerful "you are up to
            // date" sentence, which would appear in `docs/copy-inventory.md` as something Overture can
            // say to Dan while being unreachable by construction.
            return ""
        case .behind(let installedAt, let shippedAt):
            return "This copy is \(behindBy(installedAt: installedAt, shippedAt: shippedAt, now: now)) behind what has shipped, so anything fixed since then is not in front of you."
        case .cannotTell(.noInstalledRecord):
            return "This copy did not come from the installer, so there is no record of what went into it."
        case .cannotTell(.noShippedRecord):
            return "Nothing has recorded a merge on this Mac, so there is nothing to compare this copy against."
        // The three below each say what their TITLE does not. A body that restates its own heading is
        // the #843 defect, and it is easiest to write here, where every one of these is a sentence about
        // the same small fact.
        case .cannotTell(.provenanceNotRecorded):
            return "It was installed before Overture started recording which code went into a build. The next install will settle it."
        case .cannotTell(.provenanceUnknown):
            return "The installer could not reach GitHub to check whether this build's code had been merged."
        case .builtFromABranch:
            return "It is not what has shipped, and it is working on your real data."
        }
    }

    static func title(_ verdict: BuildFreshness.Verdict) -> String {
        switch verdict {
        case .builtFromABranch: return branchBuildTitle
        case .cannotTell(.provenanceNotRecorded), .cannotTell(.provenanceUnknown):
            return cannotTellProvenanceTitle
        case .cannotTell: return cannotTellTitle
        // `upToDate` never reaches a panel, since `shouldShow` refuses it, and it is not given a
        // cheerful title of its own for the same reason `body` gives it no sentence: it would land in
        // `docs/copy-inventory.md` as something Overture can say while being unreachable.
        case .behind, .upToDate: return title
        }
    }

    static let update = "Update Overture"
    // What the button actually does, said before he presses it: the installer quits Overture partway
    // through and relaunches it, so the app vanishing mid-update is the update working, not a crash.
    // Deliberately unchanged when the button moved to the update path (2026-08-04): "brings the code up
    // to what has shipped" only repeats the sentence above it, which already says the copy is behind what
    // has shipped. What this line is FOR is the surprise, that Overture disappears mid-update.
    static let updateNote = "This opens Terminal and runs the install. Overture quits partway through and comes back on its own."
    static let dismiss = "Not now"
    // Shown in place of the button when there is no record of where the code lives, so the panel never
    // offers an action it cannot carry out.
    static let cannotUpdate = "Ask Claude to reinstall Overture."
}
