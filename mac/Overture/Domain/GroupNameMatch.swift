import Foundation

// Name matching for repeat-client detection, ported from groupNameMatch.ts. Calendar
// names are messy (presenter + program title, often multi-line); these normalize them
// and decide confident vs merely-possible matches. Precision first: only confident
// matches drive scoring; possibles are flagged for review.

enum GroupNameMatch {
    static func normalize(_ name: String) -> String {
        var s = orgLine(name).lowercased()
        s = s.replacingOccurrences(of: #"^\s*presented by\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // Isolate the org/presenter line from a messy, often multi-line history entry. A
    // "Presented by X" line names the org and can sit on any line (program title first or
    // presenter first), so prefer it; otherwise fall back to the first line (#18).
    private static func orgLine(_ name: String) -> String {
        let lines = name.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if let presenter = lines.first(where: {
            $0.range(of: #"^(?i)presented by\s+"#, options: .regularExpression) != nil
        }) {
            return presenter
        }
        return lines.first ?? ""
    }

    static func tokens(_ name: String) -> [String] {
        normalize(name).split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    // True when `short` appears as a contiguous run of whole tokens inside `long`.
    private static func containsTokenRun(_ long: [String], _ short: [String]) -> Bool {
        guard short.count <= long.count else { return false }
        var i = 0
        while i + short.count <= long.count {
            if Array(long[i..<i + short.count]) == short { return true }
            i += 1
        }
        return false
    }

    // The fraction guard stops a short name ("New York") confidently matching an
    // unrelated larger one ("New York Theatre Ballet").
    private static let minContainmentFraction = 0.6

    static func isConfident(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a)
        let tb = tokens(b)
        if ta.isEmpty || tb.isEmpty { return false }
        if ta.joined(separator: " ") == tb.joined(separator: " ") { return true }

        let (short, long) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        if short.count < 2 { return false }
        if Double(short.count) / Double(long.count) < minContainmentFraction { return false }
        return containsTokenRun(long, short)
    }

    static func isPossible(_ a: String, _ b: String) -> Bool {
        if isConfident(a, b) { return false }
        let ta = Set(tokens(a))
        let tb = Set(tokens(b))
        if ta.isEmpty || tb.isEmpty { return false }
        let shared = ta.intersection(tb).count
        let union = ta.union(tb).count
        return Double(shared) / Double(union) >= 0.5
    }
}
