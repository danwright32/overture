import Foundation
import SwiftData

// #479: the launch-time backfills below used to run inline in AppDelegate against mainContext with no
// save after them, so their durability depended on an autosave tick landing before quit. Consolidating
// them here, in call order, keeps that one savepoint in one place instead of three separate sites.
enum LaunchMigrations {
    // Returns whether the explicit save landed. A failure here is not fatal: every migration above
    // guards itself on its own idempotency check (recipients.isEmpty, a thread still missing, a body
    // still carrying a greeting), so an unsaved write is simply retried whole on the next launch rather
    // than left half-applied.
    @discardableResult
    static func run(in context: ModelContext) -> Bool {
        // #418 A1 / #416: copy the lead thread down to act recipients contacted via the old lead-level
        // send path, so per-recipient reply detection has a thread to watch. Idempotent; no-op once
        // every contacted recipient carries its own thread.
        RecipientBackfill.repairThreadDown(in: context)
        // Recover salutation-free bodies from legacy inline-greeting drafts (#393), so the app can
        // render the greeting per recipient at send. Idempotent (a stripped body has nothing to strip).
        DraftSalutationMigration.run(in: context)
        // Choral folded into Music (#350), an editorial taxonomy decision. Idempotent: guarded by
        // "any prospect still stored as choral". Does not touch fitScore/tier (Dan's call).
        DisciplineMigration.run(in: context)
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }
}
