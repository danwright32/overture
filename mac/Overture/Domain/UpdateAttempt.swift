import Foundation

// #2188: what Overture makes of a press of the Update button.
//
// The button writes a small script, hands it to macOS, and forgets it. There was no channel back, so a
// refusal and a success were the same thing from inside the app: nothing. On 2026-08-06 Dan pressed
// Update, the run refused (another session had work in progress in the checkout, and disturbing it would
// have been the wrong thing to do), the reason went into a Terminal window, and Overture said nothing
// for the rest of the launch, having dismissed its own out of date panel on the press. He read the whole
// episode as "it said nothing to update", and the one surface built to make being behind impossible to
// miss went quiet exactly when the fix had not happened.
//
// So `mac/scripts/lib/update-result.sh` leaves a record and this decides what it means. Everything here
// is pure or takes its directory as an argument, so every state is reachable from a test without a
// Terminal window, a build, or a ninety second wait (L2).
struct UpdateAttemptRecord: Codable, Equatable, Sendable {
    // The id of the button press this run belongs to. Load-bearing: without it a refusal from an earlier
    // press answers for the current one, and nothing on screen could tell the two apart.
    let press: String
    // Kept as a string rather than an enum so an outcome this build does not recognise still DECODES.
    // A record it cannot read at all would land as "no record", which is the one reading that is
    // definitely wrong: the file being there proves a run got as far as writing it.
    let outcome: String
    let reason: String?
}

enum UpdateAttempt {
    static let recordFilename = "update-result.json"

    // How long an absence stays ambiguous. The record is written before anything else the run does, so
    // it appears within a second or so; after that, nothing at all means nothing ever ran (the script
    // was never opened, Terminal never started it). Generous on purpose, because the cost of being early
    // is telling him an update failed while it is quietly working.
    static let graceSeconds: TimeInterval = 30

    enum Progress: Equatable, Sendable {
        // No record yet, still inside the grace period.
        case waiting
        case running
        case failed(reason: String)
        // Nothing ever appeared. Different from a failure, and a different thing to fix: this one says
        // the run never began, not that it began and could not finish.
        case neverStarted
    }

    static func progress(record: UpdateAttemptRecord?, press: String, elapsed: TimeInterval) -> Progress {
        // A record belonging to another press says nothing about this one. Treated as absent rather than
        // as an outcome, so an old refusal can never be shown over a working update.
        guard let record, record.press == press else {
            return elapsed >= graceSeconds ? .neverStarted : .waiting
        }
        switch record.outcome {
        case "running":
            return .running
        case "failed":
            // A failure that did not say why is still a failure. Letting it decay into silence or into
            // "running" would leave Dan with a copy that did not update and nothing on screen, and the
            // sentence claims only what was measured (L11).
            let reason = record.reason ?? ""
            return .failed(reason: reason.isEmpty ? UpdateAttemptCopy.unexplained : reason)
        default:
            // The two halves disagree about their own contract. Success is expressed by REMOVING the
            // record, so a record that is present and unreadable can never mean the update worked.
            return .failed(reason: UpdateAttemptCopy.unexplained)
        }
    }

    // The directory is passed in, never resolved here, so a test cannot read Dan's Application Support
    // folder. A file that is present but undecodable comes back nil for the same reason the freshness
    // records do: treating it as an outcome would be inventing one.
    static func record(in directory: URL) -> UpdateAttemptRecord? {
        let url = directory.appendingPathComponent(recordFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UpdateAttemptRecord.self, from: data)
    }

    // Only the two states worth interrupting him for. While the run is going the Terminal window is on
    // screen carrying its own progress, so a panel saying "it is running" would interrupt him to report
    // the thing he just asked for.
    static func shouldShow(_ progress: Progress) -> Bool {
        switch progress {
        case .failed, .neverStarted: return true
        case .waiting, .running: return false
        }
    }
}

// The press, and the waiting that follows it.
//
// One press is outstanding at a time and it belongs to this launch only: an outcome is news about
// something Dan just did, and a record surviving a restart would be news about a press he has forgotten
// making. Everything is injected (the read, the wait, the clock) so a thirty second grace period and a
// run that never starts both take no real time in a test.
@MainActor
@Observable
final class UpdateAttemptState {
    // Often enough to feel immediate on a refusal, which happens in about a second, while costing two
    // small file reads in the ninety seconds a real install takes.
    static let pollInterval: TimeInterval = 5

    @ObservationIgnored private let read: @MainActor () -> UpdateAttemptRecord?
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async -> Void
    @ObservationIgnored private let clock: @MainActor () -> Date

    // nil until something has actually been pressed. Deliberately not `.waiting`, which is a statement
    // about a run in flight and would be a claim about a press that never happened.
    private(set) var progress: UpdateAttempt.Progress?

    // Observed, not ignored: it is what the view starts a fresh watch on, so a second press has to be a
    // change the view can see.
    private(set) var press: String?
    @ObservationIgnored private var pressedAt: Date?

    init(reader: @escaping @MainActor () -> UpdateAttemptRecord?,
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
        self.init(reader: { UpdateAttempt.record(in: directory) }, sleep: sleep, now: now)
    }

    var shouldShow: Bool {
        guard let progress else { return false }
        return UpdateAttempt.shouldShow(progress)
    }

    // Whether the current press has an answer. Once it does there is nothing left to look at, which is
    // what stops the loop and what makes every later tick free.
    private var resolved: Bool {
        switch progress {
        case .failed, .neverStarted: return true
        case .waiting, .running, nil: return false
        }
    }

    // A press replaces whatever came before it, including a failure still on screen: Try again is a new
    // run, and leaving the old outcome up would report the previous attempt's refusal about this one.
    func pressed(_ press: String, at: Date) {
        self.press = press
        self.pressedAt = at
        self.progress = .waiting
    }

    // Reads only while a press is outstanding. Before the first press, and after its outcome is known,
    // this costs nothing at all (#1916, an idle surface pays nothing).
    func check(now: Date) {
        guard let press, let pressedAt, !resolved else { return }
        progress = UpdateAttempt.progress(record: read(), press: press,
                                          elapsed: now.timeIntervalSince(pressedAt))
    }

    // "Not now", against the outcome currently on screen. It clears the press rather than remembering a
    // dismissal, because the next press is a different question and has to be able to speak.
    func dismiss() {
        press = nil
        pressedAt = nil
        progress = nil
    }

    // Waits on the current press until it has an answer, then returns. Returns at once when nothing is
    // outstanding, so starting it with no press cannot spin. It always terminates: an absence becomes
    // `.neverStarted` once the grace period is up, which is an answer.
    func watch() async {
        while !Task.isCancelled {
            guard press != nil, !resolved else { return }
            await sleep(Self.pollInterval)
            if Task.isCancelled { return }
            check(now: clock())
        }
    }
}

enum UpdateAttemptCopy {
    static let title = "Overture could not update"

    // What a failure with no reason in it says. It states the two things actually known and nothing else.
    static let unexplained = "Overture did not update, and the update did not say why. Ask Claude to look."

    static func body(_ progress: UpdateAttempt.Progress) -> String {
        switch progress {
        case .failed(let reason):
            // The run's own sentence, carried through rather than restated, so what he reads here is
            // word for word what the Terminal window printed.
            return reason
        case .neverStarted:
            return "The update never started, so nothing was installed and Overture is unchanged."
        case .waiting, .running:
            // No panel, so no sentence. Deliberately not a reassuring one, which would sit in
            // docs/copy-inventory.md as something Overture can say while being unreachable.
            return ""
        }
    }

    static let tryAgain = "Try again"
    static let dismiss = "Not now"
}
