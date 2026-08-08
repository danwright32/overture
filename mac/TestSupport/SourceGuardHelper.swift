import Foundation

// Shared by view-only guard-test suites (MastheadGuardTests, ProspectRowGuardTests, …) that
// assert on the raw source text of a SwiftUI view rather than runtime behavior, for changes
// with no behavioral surface to exercise.
enum SourceGuardHelper {
    // #1993: `mac/` is SEARCHED for, not counted to. This used to climb two levels from the CALLER's
    // own path, which quietly required every caller to sit exactly at `mac/<Target>/File.swift`. The
    // first caller in a subdirectory would have got a wrong path, and a wrong path here does not
    // fail: it returns "" and every `!source.contains(...)` guard standing on it passes, which is
    // dozens of guards silently protecting nothing.
    //
    // `file` is kept because callers pass it through and it is the right thing to name in a failure,
    // but it no longer decides WHERE the source is read from.
    static func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        let url = RepoRoot.mac.appendingPathComponent(relativeFromMac)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // #2106: the text between two markers, for scoping a guard to a region that is not brace-delimited.
    // The runners' heartbeat is `( while :; do … done ) &`, so its body runs from the loop header to the
    // loop's own terminator, and that is the region a guard about "what the heartbeat does each tick"
    // actually means. The alternative in use was a fixed character count after the header, which is a
    // proxy for the region rather than the region: it left 34 characters of headroom in prep-run.sh, so
    // the next edit inside the loop failed the guard while the wiring it protects was untouched (L63).
    // Returns nil if either marker is missing or they appear in the wrong order.
    static func between(_ start: String, and end: String, in source: String) -> String? {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
        else { return nil }
        return String(source[startRange.upperBound..<endRange.lowerBound])
    }

    // Returns the balanced-brace body of the property/computed-var declaration whose header line
    // ends in the given open-brace marker (e.g. "private var masthead: some View {"), scanning
    // character-by-character from the marker's own opening brace until depth returns to zero
    // (#569). Lets a guard scope its check to ONE view's own body instead of the whole file, so a
    // coincidental match elsewhere in a large file (QueueView.swift is 700+ lines) can't produce a
    // false positive, and a change hidden inside that one property can't slip past undetected.
    // Returns nil if the marker isn't found or its close brace is unbalanced.
    static func propertyBody(_ marker: String, in source: String) -> String? {
        guard let markerRange = source.range(of: marker) else { return nil }
        var depth = 1
        let bodyStart = markerRange.upperBound
        var index = bodyStart
        while index < source.endIndex {
            let char = source[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 { return String(source[bodyStart..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
