import Foundation

// The cross-run anti-repetition handoff (#730). #362 keeps a single Prep run's drafts from opening
// the same way, because the drafter has its own earlier drafts in context there; it has no memory
// across runs, so small batches drafted on different days can independently converge on the same
// handful of openers, the very templated feel #362 set out to remove. The app already stores every
// draft it produced, so it derives the recently-used opening SENTENCES here and writes them for the
// next run to steer away from. App writes, Prep workflow reads (one-sided, like the voice-feedback
// and prep-queue handoffs). Newest first, deduped, and capped, so a long history can't flood the
// drafter's context. This is shapes to AVOID, never a source of facts: the runbook forbids lifting
// any specific out of it (docs/prep-runbook.md §2).

struct RecentOpeners: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var openers: [RecentOpener]
}

struct RecentOpener: Codable, Equatable, Sendable {
    var naturalKey: String   // the opaque prospect token, for traceability (mirrors VoiceFeedbackPair)
    var discipline: String
    var opener: String       // the first sentence of a recently drafted body, whitespace-normalized
    var usedAt: String       // ISO8601, the ordering key (newest first)
}

enum RecentOpenersBuilder {
    static let version = 1
    static let maxOpeners = 15

    static func build(from prospects: [Prospect], generatedAt: String) -> RecentOpeners {
        let iso = ISO8601DateFormatter()
        struct Entry { let opener: RecentOpener; let date: Date; let key: String }
        var entries: [Entry] = []
        for p in prospects where !p.excludedFromVoiceLearning {   // #244: opted out of learning, here too
            // The AI's own first opener is the shape we want variety on; prefer it over Dan's later edit.
            guard let body = p.originalDraftBody ?? p.draftBody else { continue }
            let text = opener(from: body)
            guard !text.isEmpty else { continue }
            // Recency for ordering: when it was sent, else when its outcome landed, else when it entered
            // the queue, so an unsent draft can still be placed instead of dropped for lacking a sentAt.
            let date = p.sentAt ?? p.outcomeAt ?? p.ingestedAt
            entries.append(Entry(
                opener: RecentOpener(naturalKey: p.naturalKey, discipline: p.discipline,
                                     opener: text, usedAt: iso.string(from: date)),
                date: date, key: text.lowercased()))
        }
        // Newest first, then keep the first occurrence of each distinct opener, so a repeated shape
        // counts once and the survivor carries its most recent use.
        var seen = Set<String>()
        let deduped = entries
            .sorted { $0.date > $1.date }
            .filter { seen.insert($0.key).inserted }
            .prefix(maxOpeners)
            .map(\.opener)
        return RecentOpeners(version: version, generatedAt: generatedAt, openers: Array(deduped))
    }

    // The first sentence of a body, whitespace-normalized. The drafted body carries no greeting (the
    // app owns that at send), so the first sentence IS the opener the drafter should vary. Splits on
    // the first '.'/'!'/'?' that ends the sentence (followed by a space or the end of the text); a body
    // with no terminator is taken whole. A rare early split on an abbreviation is harmless here: this
    // feeds a "don't reuse this shape" nudge, not a correctness-critical parse.
    static func opener(from body: String) -> String {
        let norm = normalize(body)
        let chars = Array(norm)
        for (i, c) in chars.enumerated() where c == "." || c == "!" || c == "?" {
            let isEnd = i == chars.count - 1
            let nextIsSpace = !isEnd && chars[i + 1] == " "
            if isEnd || nextIsSpace {
                return String(chars[0...i])
            }
        }
        return norm
    }

    static func encode(_ recent: RecentOpeners) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(recent)
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-recent-openers.json")
    }

    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
