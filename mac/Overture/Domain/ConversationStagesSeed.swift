import Foundation
import SwiftData

// #16: give the contacts already in the store the one stage we can prove they reached.
//
// No stage history was ever recorded, so anywhere a conversation has BEEN before its current stage is
// genuinely gone and is not guessed at here. But a contact sitting at a stage demonstrably reached that
// stage, so recording it is a fact rather than an estimate, and it means the funnel's middle band is not
// empty for every conversation that predates the field.
//
// Seeds ONLY a stage Dan asserted (`conversationStateSource == .manual`), matching the live rule exactly:
// an AI suggestion he never confirmed is not his call, and promoting it here would launder a guess into
// the permanent record by the back door (his decision, 2026-07-23).
//
// Idempotent, which matters because this runs on every launch: markStageReached already refuses a
// duplicate, and the count below reports only rows it actually changed, so a contact whose stage has
// since moved on is not re-seeded with its newer stage on top.
enum ConversationStagesSeed {
    // Returns how many contacts it stamped, so a caller can report what it actually did.
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        guard let all = try? context.fetch(FetchDescriptor<Recipient>()) else { return 0 }
        var changed = 0
        for r in all {
            guard let state = r.conversationState,
                  r.conversationStateSource == .manual,
                  !r.conversationStagesReached.contains(state.rawValue) else { continue }
            r.conversationStagesReached.append(state.rawValue)
            changed += 1
        }
        return changed
    }
}
