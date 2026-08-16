import Foundation

// #2760, carrying #2764's requirement: the app READS the boundary violation record.
//
// #2764 gave the runner a deterministic boundary check. Each run fingerprints every OTHER slot's results
// file by content before it starts and re-checks it in the EXIT trap, so a run that followed a path it was
// not given is caught rather than trusted not to, and a violation is appended to
// `run-boundary-violation.log` (`slot_check_foreign_results`, mac/scripts/lib/run-slot.sh).
//
// Nothing in the app read that file. That was fine while two runs could not be alive, because the condition
// could not occur. This phase is what makes it possible, and from here a durable record nobody surfaces is
// a writer with no reader (L46). Worse: it is the record of one run having destroyed another's paid work,
// sitting in a file Dan has no reason to open, so the only diagnosis available to him would be noticing the
// answers are wrong (L142).
//
// It is counted, not measured. A byte length is a stand-in that a truncation or a rotation can leave
// matching, and the thing being decided about is how many violations the file records (L40). The count is
// cheap because the file is empty in every ordinary case.
enum RunBoundaryViolations {
    // The runner's own name for the file, and the phrase it writes at the head of each violation. The two
    // halves are in different languages, so a test pins them against the script rather than trusting that
    // whoever renames one will find the other.
    // copy-inventory:ignore-start  a filename and a phrase MATCHED in a log, not sentences Overture says
    static let fileName = "run-boundary-violation.log"
    static let marker = "BOUNDARY VIOLATION"
    // copy-inventory:ignore-end

    // Session-independent, because the record is: a violation written while Overture was closed still has
    // to be said the next time it opens.
    static let seenCountKey = "runBoundaryViolationsReported"

    static func url(in support: URL) -> URL {
        support.appendingPathComponent(fileName)
    }

    private static let lead = "A run wrote into another run's results file, so answers you already paid for may have been overwritten."
    private static let evidence = "The details are in run-boundary-violation.log, in the same folder as the store."

    // What Dan is told, or nil when there is nothing new to tell him.
    //
    // Reported ONCE per violation. A message that reappears on every launch and every settle is the shape
    // #884 took out of the ingest, and it would teach him to skim past the one line here that means paid
    // work was lost. The count is recorded only after the sentence is produced, so a caller that never
    // shows it is the caller's defect and not a silently swallowed record.
    static func newlyReported(in support: URL, defaults: UserDefaults = .standard) -> String? {
        let found = count(in: support)
        let seen = defaults.object(forKey: seenCountKey) as? Int ?? 0
        // NOT `found > seen`. A log the shell truncated or rotated is a CHANGE, and reading a smaller count
        // as "nothing new" is how the next violation after it would go unsaid.
        guard found != seen, found > 0 else {
            if found != seen { defaults.set(found, forKey: seenCountKey) }
            return nil
        }
        defaults.set(found, forKey: seenCountKey)
        let howMany = found == 1 ? "once" : "\(found) times"
        return "\(lead) It has happened \(howMany). \(evidence)"
    }

    // How many violations the log records. An unreadable file counts none, which is honest: nothing can be
    // shown to have happened, and this is a REPORT of somebody else's finding rather than a finding of its
    // own (L119).
    static func count(in support: URL) -> Int {
        guard let text = try? String(contentsOf: url(in: support), encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains(marker) }.count
    }
}
