import Foundation
import Observation
import SwiftData

// #285: a single app-wide "this ran" acknowledgment. Controls whose effect isn't otherwise visible
// (a context-menu toggle, a restore that lands offscreen behind a sheet, an async send) call
// acknowledge(...) and a shared bottom banner shows the message briefly. One object so the main
// window and every sheet share the same surface rather than each reinventing feedback.
@MainActor
@Observable
final class ActionFeedback {
    enum Tone { case info, warning }

    // #845: an acknowledgment that can be TAKEN BACK. "Stopped watching Bargemusic. [Undo]".
    //
    // Optional and defaulted, so every existing call site is unchanged: almost nothing needs this, and a
    // banner that offered an action on every message would train Dan to ignore the one that matters.
    struct Action {
        let label: String
        let perform: () -> Void
    }

    private(set) var message: String?
    private(set) var tone: Tone = .info
    private(set) var action: Action?
    // Bumped on every acknowledge (even a repeat of the same text) so the banner can restart its
    // auto-dismiss timer by keying a .task on it.
    private(set) var revision = 0

    // The action is REPLACED on every acknowledgment, never merely overwritten when a new one supplies
    // its own. An Undo that outlived its own message would be inherited by the next one, and a button
    // labelled "Undo" sitting under "Follow-up sent to Aurora Strings" would silently resume a source Dan
    // stopped ten minutes ago. It belongs to the sentence it came with, and dies with it.
    func acknowledge(_ message: String, tone: Tone = .info, action: Action? = nil) {
        QueueWriteTrace.note(QueueWriteTrace.feedback)
        self.message = message
        self.tone = tone
        self.action = action
        revision += 1
    }

    func clear() {
        QueueWriteTrace.note(QueueWriteTrace.feedback)
        message = nil
        action = nil
    }

    // #924: the banner is attached to the main window AND to each sheet, since a macOS sheet is a separate
    // window an overlay on the main view can't cover. All of them read this one object, so without a rule
    // they all draw the same message at once: the double banner Dan saw removing a day off, one over the
    // sheet and one on the window behind it. Each mounted banner registers here; only the most recently
    // mounted surface (the topmost: an open sheet, or the window when none is open) draws.
    private var activeBanners: Set<Int> = []
    private var nextBannerToken = 0

    var topBanner: Int { activeBanners.max() ?? 0 }

    func registerBanner() -> Int {
        QueueWriteTrace.note(QueueWriteTrace.feedback)
        nextBannerToken += 1
        activeBanners.insert(nextBannerToken)
        return nextBannerToken
    }

    func releaseBanner(_ token: Int) {
        QueueWriteTrace.note(QueueWriteTrace.feedback)
        activeBanners.remove(token)
    }

    // How long the banner stays up. A message offering Dan a DECISION has to outlast a glance: 3.2
    // seconds is right for "Sent" (which asks nothing of him) and useless for an Undo he has to notice,
    // read, and reach for. Here rather than in the banner view, where no test could reach it (#863/#885).
    static func dismissAfter(hasAction: Bool) -> TimeInterval {
        hasAction ? 10 : 3.2
    }
}

// The exact wording, in one place so it's testable and consistent. Each helper names the org so an
// acknowledgment reads on its own, and the send helpers carry an honest failure line (a swallowed
// send failure was one of the silent no-ops this sweep fixes).
enum ActionAck {
    static func voiceLearning(excluded: Bool, org: String) -> String {
        excluded ? "Won't learn from \(org)'s email" : "Learning from \(org)'s email again"
    }

    // #1630. A clipboard write is invisible, so without this the button reads as dead. It says ONLY that,
    // deliberately: the row it fires beside has already changed to ask whether he sent it, and repeating
    // the instruction here would be the same sentence twice on one screen (#843).
    static func formPitchCopied(org: String) -> String {
        "Pitch copied for \(org)"
    }

    static func formPitchRecorded(org: String) -> String {
        "Recorded. \(org) is now in Reached out."
    }

    // #925: the no-upcoming-shoots warning, put away for a week. It deliberately does NOT say "done" or
    // "fixed": nothing was fixed, and the second sentence is the whole reason the button is allowed to
    // exist. Hiding a warning he cannot act on is fine. Letting him forget what it meant is not.
    static func daysOffSnoozed() -> String {
        "Hidden for a week. Overture still can't keep clear of shoots it doesn't know about."
    }

    // #901: a stretch of days off, removed. Reversible from the banner, because the row he just deleted is
    // the one place the range was written down.
    static func dayOffRemoved(range: String) -> String {
        "\(range) is no longer blocked"
    }

    // #901: he has overruled a date clash. Deliberately does NOT claim the clash is gone (it isn't: the
    // row still says he is booked or away that night); it says what actually changed, which is that the
    // show can now be drafted and sent.
    static func conflictCleared(org: String) -> String {
        "\(org) can be drafted despite the clash"
    }

    static func restored(org: String) -> String {
        "Restored \(org) to the queue"
    }

    // #1415: an undo (Cmd+Z) restores a row into a stage Dan is usually not looking at (the queue is
    // stage-only since #1134), so the store changes and the screen does not, and a working undo looked
    // identical to a dead shortcut. Name what came back and the STAGE PILL Dan taps to find it, not the raw
    // status, which is a label on no pill.
    static func undoRestored(org: String, priorStatus: ReviewStatus) -> String {
        "\(org) is back in \(undoStageWord(for: priorStatus))"
    }

    // The stage pill's own name, in Dan's vocabulary (Scout/Prep/Review/Reached out), so the sentence
    // points at the pill he would click. Approve and Send are two buttons on the same Review card
    // (#1146 still open), so an approved show is seen in Review. `.dismissed` cannot be a PRIOR status an
    // undo restores to a visible stage; it maps to the archive defensively rather than naming a pill.
    private static func undoStageWord(for status: ReviewStatus) -> String {
        switch status {
        case .new: return "Scout"
        case .queued: return "Prep"
        case .drafted, .approved: return "Review"
        case .contacted: return "Reached out"
        case .dismissed: return "the archive"
        }
    }

    // #1500: a whole night, dismissed in one action, for the one reason Dan picked. Names the count and
    // the reason, because a bulk dismiss is exactly where a wrong reason gets written to many rows at once
    // and this line is his only chance to notice it.
    static func nightDismissed(count: Int, reason: DismissReason, dateLabel: String) -> String {
        count == 1
            ? "The show on \(dateLabel) is dismissed as \(reason.label)"
            : "\(Plural.count(count, "show")) on \(dateLabel) are dismissed as \(reason.label)"
    }

    // #1500: the same night, back in one press. Names the stage pill to go and look at, for the #1415
    // reason: since #1134 an undo restores rows into a stage Dan is usually not looking at, so the store
    // changes and the screen does not.
    static func undoRestoredNight(count: Int, priorStatuses: [ReviewStatus]) -> String {
        "\(Plural.count(count, "show")) \(Plural.word(count, "is", "are")) back in \(undoStageWord(for: priorStatuses))"
    }

    // The honest partial, and the case this wording exists for: the shows that had moved on are STILL
    // dismissed, and nothing else on screen would tell him that some of the night stayed behind.
    static func undoRestoredPartOfNight(restored: Int, missed: Int, priorStatuses: [ReviewStatus]) -> String {
        let others = missed == 1 ? "The other one had" : "The other \(missed) had"
        return "\(undoRestoredNight(count: restored, priorStatuses: priorStatuses)). \(others) already moved on."
    }

    // Rows restored from one action can have come from different stages, and there is no one pill to point
    // at then. It stops naming a stage rather than naming the wrong one.
    private static func undoStageWord(for statuses: [ReviewStatus]) -> String {
        let words = Set(statuses.map(undoStageWord))
        guard words.count == 1, let only = words.first else { return "your queue" }
        return only
    }

    // #1500: the batch version of undoSkipped. Counts rather than names orgs: a night is not one show, and
    // listing five org names in a banner is not something Dan reads.
    static func undoSkippedNight(count: Int) -> String {
        count == 1
            ? "That show had already moved on, so there was nothing to undo"
            : "Those \(count) shows had already moved on, so there was nothing to undo"
    }

    // #1415: the other half of "nothing is silent". When the row moved on since the action (a scout
    // re-scored it, a sweep took it, a send made it contacted) or is gone, the undo cannot apply. Said,
    // not swallowed, or a live undo and a dead one look the same from the keyboard.
    static func undoSkipped(org: String) -> String {
        "\(org) already moved on, so there was nothing to undo"
    }

    // #924: the day(s) off just captured from a dismissal. Reversible from the banner, the way removing a
    // range is (#845): the show it came from is now off the queue, so this banner is the one place the
    // range Dan just blocked is written down.
    static func dayOffBlocked(range: String) -> String {
        "\(range) is now blocked"
    }

    static func followUpSent(org: String, success: Bool) -> String {
        success ? "Follow-up sent to \(org)" : "Couldn't send the follow-up to \(org)"
    }

    static func conversationNudge(org: String, closing: Bool, success: Bool) -> String {
        if success { return closing ? "Closing note sent to \(org)" : "Nudge sent to \(org)" }
        return closing ? "Couldn't send the closing note to \(org)" : "Couldn't send the nudge to \(org)"
    }

    static func remindLater(org: String) -> String {
        "Snoozed \(org). I'll remind you later."
    }

    // #477: the Gmail send can succeed while the local save of that fact fails; this must never
    // look like nothing happened, so it always points Dan at Gmail to verify.
    static func sendNotConfirmed(org: String) -> String {
        "Couldn't save what happened sending to \(org): check Gmail to see if it went out."
    }

    // #487: a genre correction changes nothing else visible on the row, so it needs its own ack to
    // show it landed. (#1533 retired its sibling, the "Confirmed" ack: there is no longer anything to
    // confirm, only a genre to correct.)
    static func classificationCorrected(org: String) -> String {
        "Updated \(org)'s classification"
    }

    // #1274: Dan renamed a scout-generated show name. The scout will no longer overwrite it.
    static func groupRenamed(to name: String) -> String {
        "Renamed to \(name)"
    }

    // #1274: Dan reset a renamed show back to the scout's own name.
    static func groupNameReset(to name: String) -> String {
        "Restored the scout's name: \(name)"
    }

    // #367/#1143: the per-prospect re-prep confirmation. Re-prep now LAUNCHES a run for just this show,
    // so it says the run is under way, not merely "queued". draftGranted false for the `both` mode means
    // the show had already been sent to, so only the contacts half runs; Dan needs to see that narrowing.
    static func reprepStarted(mode: ReprepMode, draftGranted: Bool, org: String) -> String {
        switch mode {
        case .contactsOnly:
            return "Re-prepping \(org) to find new contacts"
        case .draftOnly:
            return "Re-prepping \(org) to redraft"
        case .both:
            return draftGranted ? "Re-prepping \(org) to redraft and find new contacts"
                                : "\(org) has already been sent to; re-prepping to find new contacts only"
        }
    }

    // #1143: a draft-only re-prep of a show already emailed has nothing to redraft, so no run starts.
    static func reprepNothingToRedraft(org: String) -> String {
        "\(org) has already been sent to, so there's nothing to redraft"
    }

    // #1740: Dan declined a nudge he was never going to send. Two sentences because they are two
    // different futures and the row vanishes either way: one says nothing more will be asked about this
    // contact, the other says it will come back. Neither may read as "sent", which is what a row
    // disappearing with no word looks like (#285, the same reason remindLater says anything at all).
    static func outreachStoodDown(org: String, scope: StandDownScope) -> String {
        switch scope {
        case .contact: return "Nothing more will be sent to this contact at \(org). No email went out"
        case .show: return "Nothing more will be sent about this \(org) show. No email went out"
        }
    }

    // The closing note closed out by hand. It has to say both halves, because "done" and "sent" are
    // exactly the two things it must not be confused between (Dan, 2026-07-30).
    static func closingNoteClosedOut(org: String) -> String {
        "\(org) is closed out. No closing note was sent"
    }

    static func nudgePushedOut(org: String, days: Int) -> String {
        "You'll see \(org) again in \(days) days. No email went out"
    }

    // #1828: the show sits on a night Dan is booked or away for. PrepQueueBuilder.needsPrep refuses a
    // clashed show before it reads the re-prep flags, so a run started here would find nothing to do; the
    // honest answer is that nothing runs until the clash is cleared, not a confirmation that it started.
    static func reprepBlockedByClash(org: String) -> String {
        "\(org) is on a night you're already booked, so nothing will re-prep until you clear the clash"
    }

    // #2007: prepping a show by hand. Its own sentence rather than the re-prep one above, because
    // nothing is going to run: the refusal is about the email he is writing NOW.
    static func manualPrepBlockedByClash(org: String) -> String {
        "\(org) is on a night you're already booked, so it can't be pitched until you clear the clash"
    }

    static let manualPrepNeedsRecipient = "Add an address to send to. Nothing was saved"
    static let manualPrepNeedsBody = "Write the email before saving it. Nothing was saved"

    static func manualPrepSaved(org: String) -> String {
        "\(org) is drafted and ready for you to review"
    }

    // #1143: a Prep run was already in progress when Dan clicked Re-prep. The flag is saved, so the show
    // is queued to re-prep on the next run rather than launching a second run over the one in flight.
    static func reprepRunInFlight(org: String) -> String {
        "A Prep run is already in progress. \(org) is queued to re-prep on the next run"
    }

    static let bulkReprepNothingEligible = "No drafted or approved prospects to re-prep"

    // #733: everything that has a draft and isn't contacted/dismissed is already pending or was
    // re-prepped too recently, so nothing new got queued. Distinct from bulkReprepNothingEligible
    // (which means nothing has a draft at all), so Dan isn't told "nothing to re-prep" when there
    // genuinely was something, just not right now.
    static func bulkReprepAllSkipped(count: Int) -> String {
        let prospectWord = count == 1 ? "prospect" : "prospects"
        return "\(count) \(prospectWord) already pending or re-prepped recently; nothing new queued"
    }

    // #367: the bulk confirmation must say when the batch was narrowed (some prospects already
    // sent, so they only got the contacts half) rather than silently applying less than asked.
    // #733: skippedCount folds in anything already pending or in the re-prep cooldown, so a
    // partial batch never reads as if everything asked for was queued.
    static func bulkReprepQueued(mode: ReprepMode, total: Int, draftGrantedCount: Int, skippedCount: Int = 0) -> String {
        let prospectWord = total == 1 ? "prospect" : "prospects"
        let skippedSuffix = skippedCount > 0
            ? " (\(skippedCount) skipped: already pending or re-prepped recently)" : ""
        guard mode != .contactsOnly else {
            return "Queued \(total) \(prospectWord) to find new contacts" + skippedSuffix
        }
        let narrowedCount = total - draftGrantedCount
        guard narrowedCount > 0 else {
            return "Queued \(total) \(prospectWord) to redraft"
                 + (mode == .both ? " and find new contacts" : "") + skippedSuffix
        }
        let base = mode == .both ? "redraft and find new contacts" : "redraft"
        return "Queued \(draftGrantedCount) of \(total) \(prospectWord) to \(base); "
             + "\(narrowedCount) already sent, so \(narrowedCount == 1 ? "it" : "they") only got new contacts"
             + skippedSuffix
    }

    // #499: a non-send mutation (keep/dismiss, draft edit, manual outcome, booking confirm, ...)
    // whose local save fails must say so instead of looking like nothing happened.
    static func saveFailed(org: String) -> String {
        "Couldn't save the change for \(org)"
    }

    // #399: the manual add/remove confirmations. Never blocking, matches the ActionFeedback banner
    // firing after the change already happened.
    static func recipientAdded(name: String?, org: String, totalCount: Int, warnings: [String]) -> String {
        let who = (name?.isEmpty == false) ? name! : "the contact"
        let base = "Added \(who). \(totalCount) recipient\(totalCount == 1 ? "" : "s") on \(org) now."
        guard !warnings.isEmpty else { return base }
        return base + " " + warnings.joined(separator: " ")
    }

    static func recipientAlreadyExists(name: String?, org: String) -> String {
        let who = (name?.isEmpty == false) ? name! : "That contact"
        return "\(who) is already a recipient on \(org)."
    }

    static func recipientResumed(name: String?, org: String) -> String {
        let who = (name?.isEmpty == false) ? name! : "the contact"
        return "Resumed pursuing \(who) on \(org)."
    }

    static func recipientRemoved(name: String?, org: String) -> String {
        let who = (name?.isEmpty == false) ? name! : "the contact"
        return "Removed \(who) from \(org)."
    }

    // #845: stopping a source is fully reversible, and the button gave no sign of it. Says what was kept,
    // because that is the part that makes the click safe to make: nothing is destroyed, the row and its
    // feed history stay, and it can be watched again whenever Dan likes. The Undo beside this sentence is
    // the immediate way back; the "Watch again" button on the row is the one that never expires.
    static func stoppedWatching(org: String) -> String {
        "Stopped watching \(org). Overture keeps what it found, and you can watch them again any time."
    }

    static func resumedWatching(org: String) -> String {
        "Watching \(org) again."
    }

    // #991: Dan refused a town from a row. Reversible from the banner (the #845 principle): the skip list
    // is the one place that refusal is written down, so a mis-click has to be undoable from where it
    // happened. "again" is honest, the town will not reappear in the queue.
    // #1719: the producer/house correction, said as what it changes rather than as a rule name. Each
    // states the standing that is now in force, so the line Dan reads back is the state, not the verb.
    static func treatingAsVenue(organisation: String) -> String {
        "Treating \(organisation) as the venue, so its address won't answer for other people's shows"
    }

    static func treatingAsProducer(organisation: String) -> String {
        "Treating \(organisation) as the presenter, so one contact can answer for all its shows"
    }

    static func producerCorrectionCleared(organisation: String) -> String {
        "Back to deciding \(organisation) automatically"
    }

    static func townExcluded(town: String) -> String {
        "Won't show you shows in \(town) again"
    }

    // The idempotent no-op said plainly: the town was already covered (by the seed or an earlier
    // refusal), so nothing changed and nothing needs undoing.
    static func townAlreadyExcluded(town: String) -> String {
        "\(town) is already on your skip list"
    }

    // #1118: Dan took a town back off his skip list from the management sheet, the reverse of townExcluded
    // and worded as its mirror (the consequence he cares about, not the mechanism). Reversible from the
    // banner (#845): the Undo re-excludes it, so a mis-clicked Remove costs nothing.
    static func townUnexcluded(town: String) -> String {
        "Shows in \(town) can appear again"
    }
}

extension ModelContext {
    // #618: roughly two dozen call sites in QueueView, FollowUpsView, and DismissedView each
    // hand-rolled this same do/catch (#499) to warn Dan when a non-send mutation's save failed.
    // Collapses every one of those to a single call; the caller only needs its own follow-up
    // logic on success, gated on the returned Bool.
    @MainActor
    @discardableResult
    func saveOrWarn(org: String, feedback: ActionFeedback) -> Bool {
        do {
            try save()
            return true
        } catch {
            feedback.acknowledge(ActionAck.saveFailed(org: org), tone: .warning)
            return false
        }
    }

    // #623: the sendNotConfirmed sibling of saveOrWarn. Four call sites in QueueView (sendReply,
    // performSend) and FollowUpsView (the follow-up send and conversation nudge) each hand-rolled
    // this same do/catch (#477/#499) to warn Dan when a Gmail send succeeded but the local record
    // of it failed to save. The caller still owns any success-path follow-up, gated on the
    // returned Bool, same as saveOrWarn.
    @MainActor
    @discardableResult
    func saveOrWarnSendNotConfirmed(org: String, feedback: ActionFeedback) -> Bool {
        do {
            try save()
            return true
        } catch {
            feedback.acknowledge(ActionAck.sendNotConfirmed(org: org), tone: .warning)
            return false
        }
    }
}
