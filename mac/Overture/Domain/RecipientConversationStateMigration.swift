import Foundation
import SwiftData

// #650: seeds any existing show-level conversation state onto the recipient who actually replied
// (the most recent one, if more than one), so an in-flight conversation started before per-recipient
// state existed does not silently stop generating reminders the moment this ships. One-time,
// idempotent: guarded by the lead still carrying a conversationState AND no recipient of that
// prospect already carrying one, so it never re-seeds or clobbers a recipient Dan (or a prior
// migration run) already set directly.
enum RecipientConversationStateMigration {
    static func run(in context: ModelContext) {
        let descriptor = FetchDescriptor<Prospect>(predicate: #Predicate { $0.conversationStateRaw != nil })
        guard let matches = try? context.fetch(descriptor), !matches.isEmpty else { return }
        for p in matches {
            guard !p.recipients.contains(where: { $0.conversationStateRaw != nil }) else { continue }
            let repliers = p.recipients.filter { $0.replied }
            guard let target = repliers.max(by: { ($0.repliedAt ?? .distantPast) < ($1.repliedAt ?? .distantPast) })
            else { continue }
            target.conversationStateRaw = p.conversationStateRaw
            target.conversationStateSetAt = p.conversationStateSetAt
            target.conversationRemindedAt = p.conversationRemindedAt
            target.conversationStateSourceRaw = p.conversationStateSourceRaw
        }
    }
}
