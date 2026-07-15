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
        self.message = message
        self.tone = tone
        self.action = action
        revision += 1
    }

    func clear() {
        message = nil
        action = nil
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

    // #924: dismissing a show for a date clash offers to capture that as a day off, so Dan does not have to
    // say "not this day" twice. The offer, never the act (his standing "ask me" preference): a single night
    // blocks in one tap, a run opens a picker. Deliberately a question, so the banner is plainly an offer.
    static func dismissedWithDayOffOffer(org: String, multiNight: Bool) -> String {
        "Dismissed \(org). " + (multiNight ? "Block those days?" : "Block that day?")
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

    // #487: the unsure-call chip clears itself, so confirming or correcting it needs its own ack.
    static func confidenceConfirmed(org: String) -> String {
        "Confirmed \(org)'s classification"
    }

    static func classificationCorrected(org: String) -> String {
        "Updated \(org)'s classification"
    }

    // #367: the per-prospect re-prep confirmation. draftGranted false for a requested draft-
    // affecting mode means the show had already been sent to, so only the contacts half applied;
    // Dan needs to see that narrowing, not just "queued".
    static func reprepQueued(mode: ReprepMode, draftGranted: Bool, org: String) -> String {
        switch mode {
        case .contactsOnly:
            return "Queued \(org) to find new contacts"
        case .draftOnly:
            return draftGranted ? "Queued \(org) to redraft"
                                : "\(org) has already been sent to, so nothing was queued"
        case .both:
            return draftGranted ? "Queued \(org) to redraft and find new contacts"
                                : "\(org) has already been sent to; queued to find new contacts only"
        }
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
