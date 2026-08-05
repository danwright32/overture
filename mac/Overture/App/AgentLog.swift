import Foundation

// #1689: the one place the app writes a line about itself, and the place it says what KIND of line it is.
//
// The menu bar used to say "Agent logged an error" whenever the resident agent's stderr file had grown
// by 8 KB. It never read a line. Everything the app deliberately logs lands in that same file, and the
// three history-preserving migrations report the same two untouched rows on every single launch, so the
// file crossed the threshold on a schedule with nothing wrong. Dan asked what the error was; there
// wasn't one.
//
// Reading the text back would not have fixed it. The single line in that log he genuinely needed said
// "reachability probe settled with 1 of 5 shows answered; 4 were never reached and stay unchecked": a
// paid check that came home short, carrying no word like error, failed or crash. A classifier scanning
// for those words would have gone on ignoring the only line that mattered.
//
// Only the code writing a line knows what it is, so that is where it says so:
//
//   - a NOTE is the app working correctly and saying so, and no volume of notes ever means trouble;
//   - a PROBLEM is something Dan may need to do something about, and ONE is enough to raise the nudge.
//
// Both still go to NSLog, so the system log and launchd's own capture keep everything they had for
// diagnosis. A problem is additionally appended to a small ledger, and that ledger is the only thing
// the menu bar reads.
enum AgentLog {
    enum Kind: Equatable {
        case note
        case problem
    }

    static func note(_ message: String) { write(.note, message) }
    static func problem(_ message: String) { write(.problem, message) }

    static func write(_ kind: Kind, _ message: String,
                      ledger: URL = AgentLogLocation.problemsURL,
                      now: Date = Date(),
                      fileManager: FileManager = .default) {
        // `%@` with the message as an ARGUMENT, never as the format itself: a message carrying a stray
        // percent sign would otherwise be read as a format specifier and print garbage or worse.
        NSLog("%@", message)
        guard kind == .problem else { return }
        // #2003: app code exercised BY a test calls this with no ledger argument, takes the live
        // default, and writes into the file the menu bar reads, so the running app tells Dan it had a
        // problem it never had. Resolved here rather than in the default argument, so a caller naming
        // the live path outright is redirected too and the guard cannot be walked around.
        record(message, in: AgentLogLocation.writableLedger(ledger), at: now, fileManager: fileManager)
    }

    // Appends one line, creating the file and its directory if this is the first problem ever recorded.
    // Best-effort: a problem that cannot be written is still in the system log, so the diagnosis never
    // depends on this succeeding. What it must not do is throw out of a caller that was in the middle
    // of reporting something going wrong.
    private static func record(_ message: String, in ledger: URL, at now: Date,
                               fileManager: FileManager) {
        let line = "\(stamp(now)) \(message)\n"
        guard let bytes = line.data(using: .utf8) else { return }
        let directory = ledger.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
        }
        if let handle = try? FileHandle(forWritingTo: ledger) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: ledger)
        }
    }

    // A log timestamp, not a business date: it records when this machine wrote the line, so it reads in
    // the zone of whoever is reading the file. EasternDate deliberately does not come near it (L39 is
    // about the dates Overture reasons with, and nothing reasons with this one).
    private static func stamp(_ now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        formatter.timeZone = .current
        return formatter.string(from: now)
    }
}
