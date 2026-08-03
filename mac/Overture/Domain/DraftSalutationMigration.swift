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
    // #2010: IT NO LONGER TOUCHES A DRAFT BODY. Dan's rule (2026-08-03): "I want whatever is in the text
    // box that I see to be what's sent. There should never be any hidden addition that I cannot see in
    // the app." Rewriting a stored body at launch is the same overreach from the other side, and it made
    // the result of typing a greeting depend on whether he had restarted the app.
    //
    // LIVE-STORE-CLAIM verified=2026-08-03 measure="stored drafts whose body opens with a greeting, and which of them this strip matched"
    // Removing the rewrite costs nothing that was working. Measured on the live store first: of 9 stored
    // drafts, 4 open with a greeting and this pass matched NONE of them (all four are a bare "Hello," with
    // no name, and the pattern required a name after the opener), and 0 drafts carried the review flag. It
    // was inert on exactly the drafts that would double.
    //
    // What replaces it is visibility, not another rule: the opening is now a field on screen directly
    // above the body (`Recipient.outgoingOpening`), and `DraftOpeningNotice` says plainly when the body
    // greets as well. Kept as a pass rather than deleted because the flag it clears is still stored on
    // rows written before this, and leaving those latched would keep them unsendable forever.
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var cleared = 0
        for prospect in prospects where prospect.draftNeedsSalutationReview {
            prospect.draftNeedsSalutationReview = false
            cleared += 1
        }
        return cleared
    }
}
