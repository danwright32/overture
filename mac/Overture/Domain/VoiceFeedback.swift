import Foundation

// The voice-learning handoff (#241 / #119): the app's record of how Dan revised AI drafts, written
// for the Prep drafter workflow to learn from (#242). App writes, Prep workflow reads (one-sided,
// like the prep-queue). Only HIGH-SIGNAL pairs are included: an AI draft Dan substantively edited
// (#240) AND sent, where the sent copy genuinely differs from the AI original. Newest first, capped,
// so a few trivial or stale edits can't dominate the drafter's context. `naturalKey` is the opaque
// prospect token; the bodies are the lesson.

struct VoiceFeedback: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var pairs: [VoiceFeedbackPair]
}

struct VoiceFeedbackPair: Codable, Equatable, Sendable {
    var naturalKey: String
    var discipline: String
    var originalSubject: String?   // the AI's draft, before Dan's edits
    var originalBody: String?
    var sentSubject: String?       // the exact text Dan sent
    var sentBody: String?
    var sentAt: String             // ISO8601, the ordering key (newest first)
    var outcome: String            // the prospect's outcome (#245): "booked"/"replied"/etc., so the
                                   // distiller can lean on the edits that actually landed
}

enum VoiceFeedbackBuilder {
    static let version = 1
    static let maxPairs = 20
    // Below this normalized edit distance the AI draft and the sent copy are effectively the same
    // (a typo fix or a near-revert): no voice lesson, so the pair is dropped. The capture step
    // already excludes pure whitespace / no-op saves (#240); this is the stronger min-delta gate the
    // export owns, comparing the AI ORIGINAL against the SENT copy (not any intermediate draft).
    static let minEditDistance = 3

    static func build(from prospects: [Prospect], generatedAt: String) -> VoiceFeedback {
        let iso = ISO8601DateFormatter()
        let pairs = prospects
            .compactMap { p -> (Prospect, Date)? in
                guard !p.excludedFromVoiceLearning,        // #244: Dan opted this send out of learning
                      let sentAt = p.sentAt,
                      let original = p.originalDraftBody,
                      let sent = p.sentBody,
                      isHighSignal(originalBody: original, sentBody: sent) else { return nil }
                return (p, sentAt)
            }
            // Winners first (#245), then newest first within a tier — so an email that landed a reply
            // or booking survives the cap even when older than recent no-response edits.
            .sorted { a, b in
                let ra = outcomeRank(a.0.outcome), rb = outcomeRank(b.0.outcome)
                return ra != rb ? ra > rb : a.1 > b.1
            }
            .prefix(maxPairs)
            .map { (p, sentAt) in
                VoiceFeedbackPair(
                    naturalKey: p.naturalKey,
                    discipline: p.discipline,
                    originalSubject: p.originalDraftSubject,
                    originalBody: p.originalDraftBody,
                    sentSubject: p.sentSubject,
                    sentBody: p.sentBody,
                    sentAt: iso.string(from: sentAt),
                    outcome: p.outcome.rawValue
                )
            }
        return VoiceFeedback(version: version, generatedAt: generatedAt, pairs: Array(pairs))
    }

    // How strongly to favor an edit by what it earned (#245). Booked beats replied beats the rest, so
    // proven-effective edits lead and survive the cap.
    static func outcomeRank(_ outcome: Outcome) -> Int {
        switch outcome {
        case .booked: return 2
        case .replied: return 1
        default: return 0
        }
    }

    static func isHighSignal(originalBody: String, sentBody: String) -> Bool {
        editDistance(normalize(originalBody), normalize(sentBody)) >= minEditDistance
    }

    static func encode(_ feedback: VoiceFeedback) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(feedback)
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overture", isDirectory: true)
            .appendingPathComponent("overture-voice-feedback.json")
    }

    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Plain Levenshtein. Email bodies are short and there are at most `maxPairs` of them, so the
    // O(n*m) cost is negligible; this just measures "how different is the sent copy from the AI draft".
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
