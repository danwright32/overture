import Foundation

// The anonymization guard for the voice-learning loop (#249 / #119). The #242 distiller is INSTRUCTED
// to strip every org/venue/contact/production specific out of the voice guidance, but that is only a
// prompt instruction. This guard verifies it DETERMINISTICALLY and fails CLOSED: it checks the
// auto-generated section of overture-voice-guidance.md against the real names in the store, and if any
// leak through it quarantines that section (so a contaminated guidance can never feed a future draft)
// and reports the leaked names so the app can warn Dan. Dan's own notes section is never inspected or
// touched; a name he writes there is his call, not a leak.

enum VoiceGuidanceGuard {
    // Names shorter than this are dropped: too likely to be common words that would false-positive
    // (and too weak as identifying specifics to matter).
    static let minTermLength = 4
    static let autoSectionHeadingPrefix = "## Observed tendencies"

    // The org/venue/contact/production specifics that must NEVER appear in the anonymized guidance.
    static func forbiddenTerms(from prospects: [Prospect]) -> Set<String> {
        var terms = Set<String>()
        for p in prospects {
            let candidates: [String?] = [p.groupName, p.venue, p.contactName, p.production,
                                         p.possibleMatchName, p.matchedClientName]
            for raw in candidates {
                guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { continue }
                guard t.count >= minTermLength, t.lowercased() != "self" else { continue }   // "self" = production sentinel
                terms.insert(t)
            }
        }
        return terms
    }

    // The body of the auto-generated section only (everything from its heading to the next `## `
    // heading or end of file). Empty if there is no such section.
    static func autoSectionBody(of contents: String) -> String {
        let lines = contents.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix(autoSectionHeadingPrefix) }) else { return "" }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("## ") { break }
            body.append(line)
        }
        return body.joined(separator: "\n")
    }

    // Any forbidden name that appears (case-insensitively, on word boundaries) in the auto section.
    static func findLeaks(inAutoSectionOf contents: String, forbidden: Set<String>) -> [String] {
        let hay = autoSectionBody(of: contents).lowercased()
        guard !hay.isEmpty else { return [] }
        var leaked: [String] = []
        for term in forbidden {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: term.lowercased()) + "\\b"
            if hay.range(of: pattern, options: .regularExpression) != nil { leaked.append(term) }
        }
        return leaked.sorted()
    }

    // Replace the auto section's body with a placeholder, preserving the heading and Dan's notes. The
    // next Prep run regenerates the auto section fresh, so this is a safe quarantine, not a deletion.
    static func quarantineAutoSection(in contents: String) -> String {
        let lines = contents.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix(autoSectionHeadingPrefix) }) else { return contents }
        var result = Array(lines[...start])
        result.append("")
        result.append("_(Removed: the auto-generated guidance contained a specific name and was quarantined; it will regenerate on the next Prep run.)_")
        var i = start + 1
        while i < lines.count, !lines[i].hasPrefix("## ") { i += 1 }
        if i < lines.count {
            result.append("")
            result.append(contentsOf: lines[i...])
        }
        return result.joined(separator: "\n")
    }

    // Read the guidance file, check the auto section against the store's real names, and on any leak
    // rewrite the file with that section quarantined. Returns the leaked names (empty = clean / absent).
    @discardableResult
    static func audit(fileURL: URL, prospects: [Prospect]) -> [String] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let leaks = findLeaks(inAutoSectionOf: contents, forbidden: forbiddenTerms(from: prospects))
        if !leaks.isEmpty {
            try? quarantineAutoSection(in: contents).write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return leaks
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-voice-guidance.md")
    }
}
