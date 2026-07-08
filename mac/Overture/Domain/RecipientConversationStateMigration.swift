import Foundation
import SwiftData

// #650/#652: seeds any existing show-level conversation state onto the recipient it belongs to, so
// an in-flight conversation started before per-recipient state existed does not silently stop
// generating reminders once the UI stops reading the lead-level field. Widened in #652 past the
// original "most recent replier" rule to also cover a single-contact show whose state was set by
// hand with no auto-detected reply to attribute it to, and to self-correct if the lead-level state
// genuinely changed again after the first seed. Never guesses across multiple untouched contacts,
// and never overrides a state a DIFFERENT recipient already carries independently.
enum RecipientConversationStateMigration {
    static func run(in context: ModelContext) {
        let descriptor = FetchDescriptor<Prospect>(predicate: #Predicate { $0.conversationStateRaw != nil })
        guard let matches = try? context.fetch(descriptor), !matches.isEmpty else { return }
        for p in matches {
            guard let target = seedTarget(for: p) else { continue }
            guard !p.recipients.contains(where: { $0 !== target && $0.conversationStateRaw != nil }) else { continue }
            guard shouldSeed(target, from: p) else { continue }
            target.conversationStateRaw = p.conversationStateRaw
            target.conversationStateSetAt = p.conversationStateSetAt
            target.conversationRemindedAt = p.conversationRemindedAt
            target.conversationStateSourceRaw = p.conversationStateSourceRaw
        }
    }

    // The recipient a lead-level state belongs to: the most recent replier when more than one
    // replied, or the lone recipient on a single-contact show that never triggered an auto-detected
    // reply. A silent multi-contact show is ambiguous and is never guessed.
    private static func seedTarget(for p: Prospect) -> Recipient? {
        let repliers = p.recipients.filter { $0.replied }
        if let mostRecentReplier = repliers.max(by: { ($0.repliedAt ?? .distantPast) < ($1.repliedAt ?? .distantPast) }) {
            return mostRecentReplier
        }
        return p.recipients.count == 1 ? p.recipients.first : nil
    }

    // True for a fresh target (no state yet), or a previously-seeded target ONLY when the lead-level
    // state carries a real timestamp genuinely newer than what the target already has, meaning Dan
    // changed the lead-level state again after the first seed ran. Never re-seeds from an untimestamped
    // lead state (nothing proves it's newer), matching the original idempotent guard.
    private static func shouldSeed(_ target: Recipient, from p: Prospect) -> Bool {
        guard target.conversationStateRaw != nil else { return true }
        guard let leadSetAt = p.conversationStateSetAt else { return false }
        guard let targetSetAt = target.conversationStateSetAt else { return true }
        return leadSetAt > targetSetAt
    }
}
