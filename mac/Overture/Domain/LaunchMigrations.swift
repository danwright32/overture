import Foundation
import SwiftData
import UserNotifications

// #479: the launch-time backfills below used to run inline in AppDelegate against mainContext with no
// save after them, so their durability depended on an autosave tick landing before quit. Consolidating
// them here, in call order, keeps that one savepoint in one place instead of three separate sites.
enum LaunchMigrations {
    // Returns whether the explicit save landed. A failure here is not fatal: every migration above
    // guards itself on its own idempotency check (recipients.isEmpty, a thread still missing, a body
    // still carrying a greeting), so an unsaved write is simply retried whole on the next launch rather
    // than left half-applied.
    // #1693: `possibleMatchInputs` is a seam, not a knob. The recheck judges against two files that a
    // test process does not have (a Debug or test run reads its own handoff directory, which holds no
    // Downbeat export), so with the real loader that pass silently no-ops under test and a wiring test
    // written against it asserts nothing at all. Found the only way that is ever found: by deleting the
    // call below and watching the suite stay green.
    @discardableResult
    static func run(in context: ModelContext,
                    possibleMatchInputs: ([Prospect]) -> PossibleMatchRecheck.Inputs? = {
                        PossibleMatchRecheck.load(prospects: $0)
                    }) -> Bool {
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
        // #16: stamp a first-sighting date on every prospect predating the field, so the funnel report has
        // a start node for the shows already in the store. Idempotent, and that matters more here than
        // usual: it runs every launch while `ingestedAt` keeps moving, so a re-stamp would walk the first
        // sighting forward launch by launch. Guarded by "firstSeenAt is still nil".
        FirstSeenBackfill.run(in: context)
        // #16: record the one conversation stage each existing contact can be proven to have reached
        // (the one it is sitting at, and only where Dan set it himself). Idempotent; earlier stages were
        // never recorded and are not guessed at.
        ConversationStagesSeed.run(in: context)
        // #940: 'Day doesn't work' folded into 'Date conflict'. Idempotent: guarded by "still carries the
        // old day_doesnt_work raw value", so it rewrites each once and no-ops thereafter.
        DismissReasonMigration.run(in: context)
        // #1626: a show already checked before "contact form only" existed reads as a dead end while
        // holding a usable form link. Upgrades that one verdict and nothing else. Idempotent.
        ContactFormResultMigration.run(in: context)
        // LIVE-STORE-CLAIM verified=2026-07-26 measure="rows carrying the classifier catch-all fit reason when Phase 7 shipped the clearing migration"
        // #1600: clear the classifier's retired catch-all fit reason from the rows that already carry it
        // (499 on the live store). Idempotent: guarded by "still carries the retired string". Without it
        // the sentence would linger for weeks on whichever rows the hash-gated scout has not re-emitted.
        CatchAllFitReasonMigration.run(in: context)
        // #1064: re-key existing prospects with the new venue normalization so a bare venue name and the
        // same venue with its street address appended stop keying as two separate rows for one show.
        // Idempotent (a re-keyed row already equals its folded key); merges only provably-empty duplicates
        // and defers any collision where two rows both carry outreach history. Can delete a row, so the
        // launch backup (#601/#602) taken just before this matters here most.
        NaturalKeyVenueMigration.run(in: context)
        // #1559: collapse the duplicate rows a drifting opening night left behind before #1528 stopped
        // them appearing. Idempotent (a collapsed group is a singleton, which it skips). Deletes rows, so
        // like the migration above it leans on the launch backup taken just before this, and it refuses
        // to touch any group where two rows carry outreach history. Deliberately does NOT rewrite a key
        // or a date: the next scout re-keys the survivor through #1528's own match, and a key rewrite is
        // the only step here that could throw against the unique index and take the shared save below
        // down with it.
        DriftedRunMerge.run(in: context)
        // #1590: collapse one show BILLED two ways on the same night in the same room, which the natural
        // key cannot reach (its title fold is a canonical function, and these titles differ by real
        // words). Runs after the re-key above so it sees the folded keys, and deliberately every launch
        // rather than once: a source keeps republishing its variants. Deletes rows, so like the two passes
        // above it leans on the launch backup, refuses any group where two rows carry outreach history,
        // and keeps the row holding a paid reachability answer over one that was never checked.
        SameNightTitleVariantMerge.run(in: context)
        // LIVE-STORE-CLAIM verified=2026-07-28 measure="prospect rows carrying a possible-match flag, and how many of those name one record"
        // #1693: re-run the possible-match verdict over the rows that already carry one (21 on the live
        // store, 18 of them naming the same wrong record). The flag is STORED and only rewritten when the
        // hash-gated scout re-emits that row, so tightening the matcher alone would leave the wrong
        // question sitting on Dan's screen for as long as that source happened not to be re-scouted.
        // Runs after the merges above so it judges the surviving rows, and every launch rather than once,
        // because the answer depends on files (the Downbeat export, the booking history) that keep
        // changing under it. It can only clear or replace a flag on a row that already has one, never
        // invent one, and it touches nothing at all when either of those files is missing or corrupt.
        PossibleMatchRecheck.run(in: context, loadInputs: possibleMatchInputs)
        // LIVE-STORE-CLAIM verified=2026-07-29 measure="untriaged prospects with a blank `location`, run through the real fill and the real geography gate"
        // #1744: place the rows already in the store (341 of 342 blank untriaged rows on the live store),
        // so #970's geography gate stops being a no-op on two thirds of the queue and the town refusal is
        // offered on rows that were withholding it. Deliberately BEFORE the town retirement below, so a
        // show this pass places in a town Dan has already refused is cut in the same launch rather than
        // sitting in the queue until the next one. Idempotent and additive: it fills blanks only.
        LocationBackfill.run(in: context)
        // #864: retire an untriaged show whose last night has passed, so `new` genuinely means "waiting
        // on Dan" rather than accumulating rows in a state that can never be resolved. Unlike the
        // backfills above, this one is not a one-time migration: it runs every launch, because a show
        // goes by every day. Idempotent for the same reason they are (a retired show is no longer `new`,
        // so a second pass cannot see it). It returns how many it touched, for a caller that wants to say.
        WentByRetirement.run(in: context)
        // #1238: retire shows in a town Dan has blocked (or a built-in seed far-town), so a blocked town's
        // shows stay gone across launches. Mirrors WentByRetirement: Overture's own cut, its own reason.
        ExcludedTownRetirement.run(in: context)
        return persist(context.save, report: { reportSaveFailure($0) })
    }

    // #1601: this used to be an inline `catch { return false }`, and AppDelegate discarded the false, so
    // a failed launch save was invisible TWICE: the error never logged, the outcome never read.
    //
    // LIVE-STORE-CLAIM verified=2026-07-27 measure="duplicate title-variant rows the #1590 pass deleted on its first run"
    // That was survivable while the launch pass only backfilled fields. #1590 ended it by adding a pass
    // that DELETES rows (17 of them on the live store's first run). If the save fails, those deletes
    // evaporate, the duplicates return, and the only symptom is a feature that looks like it was never
    // built. Nothing is LOST either way, since every pass here is idempotent and simply runs again next
    // launch, but silence turns a transient failure into a mystery.
    //
    // Extracted so the error path can actually be tested: SwiftData's save cannot be made to fail on
    // demand from a test, so the decision ABOUT the outcome is what gets the seam, rather than the error
    // path going untested because it is awkward to reach.
    static func persist(_ save: () throws -> Void, report: (Error) -> Void) -> Bool {
        do {
            try save()
            return true
        } catch {
            report(error)
            return false
        }
    }

    // Logged AND surfaced. The log is for whoever is diagnosing it; the notification is because a
    // masthead key needs the window open to be seen, and a resident launch may have no window at all.
    // Same first-party channel the OmniFocus failures use (#268), never an OS dialog.
    static func reportSaveFailure(_ error: Error,
                                  deliver: (UNNotificationRequest) -> Void =
                                      { UNUserNotificationCenter.current().add($0) }) {
        // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
        NSLog("#1601 LaunchMigrations: the launch save failed, so no migration was persisted: %@",
              String(describing: error))
        // copy-inventory:ignore-end
        NotificationService.post(.launchFailed,
                                 title: LaunchMigrationsCopy.saveFailedTitle,
                                 body: LaunchMigrationsCopy.saveFailedBody,
                                 deliver: deliver)
    }
}

// #1601: kept out of the view and named, so the copy inventory shows the whole sentence Dan reads (#915).
enum LaunchMigrationsCopy {
    static let saveFailedTitle = "Overture couldn't finish starting up"
    // Says what did not happen, what he may therefore see, and the one thing that retries it. It does
    // NOT claim anything was lost, because nothing is: every launch pass is idempotent and runs again.
    static let saveFailedBody =
        "Its start-up tidy-up didn't save, so the queue may still be showing duplicates it meant to merge, or shows that have already gone by. Quit and reopen Overture to try again."
}
