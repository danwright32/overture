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
        // #800/#771: Carnegie becomes row one of the watchlist, inheriting its own feed-health history,
        // and every prospect already in the store is stamped with the source it actually came from.
        // Idempotent: guarded by "is there a Carnegie row yet", and it never drops a source id a
        // prospect already carries.
        WatchedSourceBackfill.run(in: context)
        // #940: 'Day doesn't work' folded into 'Date conflict'. Idempotent: guarded by "still carries the
        // old day_doesnt_work raw value", so it rewrites each once and no-ops thereafter.
        DismissReasonMigration.run(in: context)
        // #1064: re-key existing prospects with the new venue normalization so a bare venue name and the
        // same venue with its street address appended stop keying as two separate rows for one show.
        // Idempotent (a re-keyed row already equals its folded key); merges only provably-empty duplicates
        // and defers any collision where two rows both carry outreach history. Can delete a row, so the
        // launch backup (#601/#602) taken just before this matters here most.
        NaturalKeyVenueMigration.run(in: context)
        // #864: retire an untriaged show whose last night has passed, so `new` genuinely means "waiting
        // on Dan" rather than accumulating rows in a state that can never be resolved. Unlike the
        // backfills above, this one is not a one-time migration: it runs every launch, because a show
        // goes by every day. Idempotent for the same reason they are (a retired show is no longer `new`,
        // so a second pass cannot see it). It returns how many it touched, for a caller that wants to say.
        WentByRetirement.run(in: context)
        // #1238: retire shows in a town Dan has blocked (or a built-in seed far-town), so a blocked town's
        // shows stay gone across launches. Mirrors WentByRetirement: Overture's own cut, its own reason.
        ExcludedTownRetirement.run(in: context)
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }
}
