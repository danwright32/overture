import Foundation

// #875: the run's own explanation of what happened to a source, which until now was decoded and thrown
// away. `ScoutExtractResult.note` is even commented "for Dan to read", and nothing read it.
//
// So a failing source showed him the GENERIC sentence for its verdict ("The run ended before reading
// this page") while the specific reason, the one thing that would tell him WHY, sat in a file he would
// have had to open by hand. The failing list only earns its place if every row is actionable, and the
// note was the most actionable thing in the whole results file.
//
// The note arrives as one blob: a human sentence, and then (from #856, for a source the run never
// reached) up to six lines of raw run log. Dan's call, 2026-07-13: the sentence belongs in the row, the
// log belongs on hover. A row that unrolled a paragraph of shell output would make the sheet unreadable,
// and a sheet nobody can scan is a sheet nobody checks.
//
// That split is a decision about what Dan reads, so it is decided HERE, beside the data, and never in a
// SwiftUI body: a rule computed inside a view is a rule no test can reach, and this app has already
// watched one drift twice under a green suite (#863/#885).
enum SourceNote {
    // The marker `results-guard.sh` uses when it attaches the log tail. Matched, not parsed: everything
    // before it is for Dan, everything after it is for whoever is debugging.
    static let logMarker = "Last lines of the run log:"

    // What the row says. The reason, in words.
    static func summary(_ note: String?) -> String? {
        guard let parts = split(note) else { return nil }
        // A note that is ONLY a log tail must not render as a blank line with a silent tooltip. If the
        // log is all we have, the log IS the message, however ugly: saying nothing would be worse.
        return parts.sentence ?? parts.log
    }

    // What the hover says: the raw tail, and only when there is a sentence carrying the row already.
    static func detail(_ note: String?) -> String? {
        guard let parts = split(note), parts.sentence != nil else { return nil }
        return parts.log
    }

    private static func split(_ note: String?) -> (sentence: String?, log: String?)? {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        guard let marker = note.range(of: logMarker) else {
            return (clean(String(note)), nil)
        }
        return (clean(String(note[note.startIndex..<marker.lowerBound])),
                clean(String(note[marker.upperBound...])))
    }

    private static func clean(_ s: String) -> String? {
        let trimmed = s
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
