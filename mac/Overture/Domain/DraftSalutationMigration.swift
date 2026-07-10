import Foundation
import SwiftData

// Phase 2.5 (#393): a one-shot, idempotent launch pass that recovers a salutation-free body from
// legacy drafts authored with an inline greeting ("Hi Emma, I photograph..."), so the app can render
// the greeting per recipient at send (Salutation.greeting(for:)). Runs in the same launch ingest path
// as the Phase 1 RecipientBackfill. It is idempotent (a salutation-free body has nothing to strip),
// so no run-once flag is needed; SalutationStrip leaves ambiguous greetings untouched and flags them.
enum DraftSalutationMigration {
    // Strip the leading greeting from every draft where it is safe; re-derive draftNeedsSalutationReview
    // from the CURRENT body every run (#407), not a one-way latch, so a draft Dan rewrites by hand or a
    // fresh Prep re-run clears the flag the next time this runs, instead of staying flagged forever.
    // Returns how many drafts were actually changed.
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var normalized = 0
        for prospect in prospects {
            guard let body = prospect.draftBody, !body.isEmpty else { continue }
            let result = SalutationStrip.strip(body)
            if result.didStrip {
                prospect.draftBody = result.body
                normalized += 1
            }
            prospect.draftNeedsSalutationReview = result.needsReview
        }
        return normalized
    }
}
