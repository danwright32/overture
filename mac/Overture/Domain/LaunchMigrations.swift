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
        // #393's salutation pass is GONE (#2545). It stripped a greeting out of a stored body so the app
        // could compose its own per recipient at send; #2010 stopped it rewriting bodies, leaving it only
        // clearing a flag nothing set any more, and #2545 inverted the rule it served (a body must now
        // open with a greeting, held by Recipient.isBlockedByGreeting).
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
        // #940: 'Day doesn't work' folded into 'Date conflict'. Idempotent: guarded by "still carries the
        // old day_doesnt_work raw value", so it rewrites each once and no-ops thereafter.
        DismissReasonMigration.run(in: context)
        // #2394: carry every ending already recorded onto the one show-level field. Deliberately AFTER
        // DismissReasonMigration above, which folds the retired `day_doesnt_work` spelling: running it
        // first would count that value as unrecognised and leave those rows with no outcome at all.
        // Idempotent, guarded by "this row has no outcome yet", so it fills each once and no-ops after.
        ShowOutcomeBackfill.run(in: context)
        ShowOutcomeBackfill.runForInquiries(in: context)
        // #1626: a show already checked before "contact form only" existed reads as a dead end while
        // holding a usable form link. Upgrades that one verdict and nothing else. Idempotent.
        ContactFormResultMigration.run(in: context)
        // LIVE-STORE-CLAIM verified=2026-07-26 measure="rows carrying the classifier catch-all fit reason when Phase 7 shipped the clearing migration"
        // #1600: clear the classifier's retired catch-all fit reason from the rows that already carry it
        // (499 on the live store). Idempotent: guarded by "still carries the retired string". Without it
        // the sentence would linger for weeks on whichever rows the hash-gated scout has not re-emitted.
        CatchAllFitReasonMigration.run(in: context)
        // #1657: put each stored fit reason back in step with the axes on its own row. `fitReason` is a
        // snapshot and a hash-gated scout may not re-emit a given row for weeks, so changing the sentence
        // in the classifier alone would leave the old wording on an arbitrary subset of the queue: 21 rows
        // reading "Self-produced other group" (a raw enum value, not a genre) and one still naming the
        // "choral" genre #350 folded into music. Recomputed through EventClassifier.derived rather than
        // matched against known strings, so this pass cannot become a second copy of the templates.
        // Idempotent by construction: it writes the sentence its own condition compares against, and it
        // never touches a row whose reason is deliberately empty (#1600).
        FitReasonRealignment.run(in: context)
        // #1064: re-key existing prospects with the new venue normalization so a bare venue name and the
        // same venue with its street address appended stop keying as two separate rows for one show.
        // Idempotent (a re-keyed row already equals its folded key); merges only provably-empty duplicates
        // and defers any collision where two rows both carry outreach history. Can delete a row, so the
        // launch backup (#601/#602) taken just before this matters here most.
        NaturalKeyVenueMigration.run(in: context)
        // #2422: one person found through two handles is one contact. Deliberately AFTER the natural-key
        // merge above, which can itself move recipients between rows: reconciling first would leave the
        // pairs that arrive from that merge for another launch. It DELETES a recipient, so it refuses any
        // group holding a sent or manual row and never lets a blank overwrite a value; the launch backup
        // (#601/#602) taken just before this is the net under it. Idempotent: a show with one row per
        // person has no group of two to reconcile.
        DuplicateContactMerge.run(in: context)
        // #2421's dead-end sweep is GONE (#2612). It deleted every contact whose only route was a
        // social profile, and Dan reversed that call on 2026-08-13: an Instagram is a route he works by
        // hand. With the ingest deliberately keeping those contacts, a pass that deleted them would be
        // undoing the fix on every launch, so it is removed rather than left standing (L116: a rule that
        // only encodes a preference must never be enforced by deleting the data it filters). The 45
        // contacts it already deleted cannot be recovered here; only a fresh check on each show can.
        // #1784: move each stored organisation answer onto the key today's shared fold computes, so an
        // answer written under the old spelling of a bracketed name is still found rather than paid for
        // again. Idempotent (a row already on its computed key is skipped). Can delete a row, but only a
        // provably redundant one: two answers that DISAGREE are left exactly as they are.
        OrgKeyRealignmentMigration.run(in: context)
        // #1802: the same problem for ROOMS. One venue identity now answers for every spelling of a room
        // (a leading article dropped, an unlisted room folded the way a listed one is), which changes the
        // key an answer Dan typed should be filed under. Without this his sentence about where a room is
        // would sit under a key nothing computes any more, and the room would go back on his unplaced list
        // asking the same question. Idempotent (a row already on its computed key is skipped); it can
        // delete a row, but only one provably redundant, and two answers that DISAGREE are left alone.
        VenueKeyRealignmentMigration.run(in: context)
        // #2451: Dan's own producer/house corrections, onto the key the gate's fold computes today.
        // Those rows keep no raw name, so this one re-folds the stored key itself. Idempotent (a row
        // already on its computed key is skipped). It can delete a row, but only a correction written
        // twice; a promotion and a demotion landing on ONE key is a contradiction and both are left
        // alone.
        ProducerOverrideKeyRealignment.run(in: context)
        // #2451: and the REFUSALS, which get the other behaviour deliberately. `OrgKey.of` now drops a
        // leading article, so an organisation-scoped strike filed under the old spelling would be looked
        // up by a key nothing computes any more: the address quietly back on the card, and the next prep
        // run paying to rediscover it. This pass NEVER deletes. On a key collision it keeps both rows
        // under both keys and counts it, because two refusals can only ever mean refuse and a refusal
        // ledger one row shorter is indistinguishable from no refusal at all (#2392, #2421).
        RefusedOrgKeyRealignment.run(in: context)
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
        // LIVE-STORE-CLAIM verified=2026-08-02 measure="stored rows whose presenter reduces to their own venue under ProducerGate.key, and what they score"
        // #1845: strip a room standing in as its own show's presenter from the rows already in the store
        // (101 of 723 on the live store, among them one scoring 28 as a "self-produced, strong profile"
        // organisation that is really the building). The boundary guard has caught this since #1766, but
        // only as a show is READ, so it never reached a row written before it and a hash-gated scout may
        // not re-read that show for weeks. Runs AFTER the merges above so it judges surviving rows, and
        // every launch rather than once, since a later scout can write the name back. Idempotent by
        // construction: it clears the field its own condition tests. Re-derives the axes the presenter
        // fed, so a swept row is scored on what is left rather than keeping the 8 points the name earned.
        RoomPresenterSweep.run(in: context)
        // LIVE-STORE-CLAIM verified=2026-08-11 measure="rows naming no presenting organisation, and their mean fit score against the rest"
        // #2504: put the producer axes of an already-stored act-named row in step with what they now
        // mean. 439 of 877 live rows name no presenting organisation and average a fit score of 0.4
        // against 3.2 for the rest, because production, profile and coverage were all drawn from the
        // presenter string and so were structurally stuck at their "we know nothing" value, which scores
        // zero. The classifier now reads the ACT as the party (Dan's call, 2026-08-11), and this reaches
        // the rows already stored, which a hash-gated scout would otherwise leave for weeks.
        //
        // Deliberately AFTER RoomPresenterSweep: that pass can itself make a row act-named by clearing a
        // room standing in as the presenter, and running first would leave every row it creates for
        // another launch. Only ever lifts (an agency row keeps its penalty), never touches the genre or
        // the fit reason, and is idempotent by construction.
        ActIsThePartyRealignment.run(in: context)
        // LIVE-STORE-CLAIM verified=2026-08-16 measure="prospect rows whose stored producer axes the pre-#2508 fragment match explains and the current classifier refuses"
        // #2565: take back what the OLD fragment-matching classifier gave a row. #2508 stopped the signal
        // lists firing inside longer words ("opera" inside Operation Mincemeat, "band" inside Sam Gelband,
        // "school" inside Let's Get Schooled!), and that reaches a row only when the scout next re-reads
        // its page, which for an unchanged page can be weeks. Two of those rows were competing for Dan's
        // attention at a fit score of 6 on a signal that was never real.
        //
        // Deliberately AFTER the pass above, which is the one that only ever LIFTS. This is the opposite
        // direction and the two can never fight over one row: this lowers only a value the CURRENT rules
        // refuse, and that pass lifts only to a value they produce. It is narrower than a re-read on
        // purpose (a stored row's axes can come from inputs the row no longer holds), never touches an
        // agency verdict, the genre or the fit reason, and is idempotent by construction. It moved 0 rows
        // when rehearsed on 2026-08-16; see FragmentMatchCorrection's own note for why it ships anyway.
        FragmentMatchCorrection.run(in: context)
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
        // LIVE-STORE-CLAIM verified=2026-08-06 measure="recipients that are replied, unresolved, unbounced and carry no answered stamp, where an answer was demonstrably sent on the same conversation after the reply arrived"
        // #2190: stamp the replies Dan answered BEFORE #2170 added the field that means "Dan answered".
        // Two rows on the live store, both on The Pumpkin Singalong, which had gone on asking him to
        // answer an email he answered on 2026-08-05. Selected by the defect's signature rather than by the
        // stamp being empty, since an empty stamp is the ordinary state of every reply still waiting.
        AnsweredReplyBackfill.run(in: context)
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
        // #1689: a PROBLEM. Nothing this launch migrated was kept, so the next launch does it all again.
        AgentLog.problem("#1601 LaunchMigrations: the launch save failed, so no migration was persisted: \(String(describing: error))")
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
