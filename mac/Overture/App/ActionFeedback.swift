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

    private(set) var message: String?
    private(set) var tone: Tone = .info
    // Bumped on every acknowledge (even a repeat of the same text) so the banner can restart its
    // auto-dismiss timer by keying a .task on it.
    private(set) var revision = 0

    func acknowledge(_ message: String, tone: Tone = .info) {
        self.message = message
        self.tone = tone
        revision += 1
    }

    func clear() {
        message = nil
    }
}

// The exact wording, in one place so it's testable and consistent. Each helper names the org so an
// acknowledgment reads on its own, and the send helpers carry an honest failure line (a swallowed
// send failure was one of the silent no-ops this sweep fixes).
enum ActionAck {
    static func voiceLearning(excluded: Bool, org: String) -> String {
        excluded ? "Won't learn from \(org)'s email" : "Learning from \(org)'s email again"
    }

    static func restored(org: String) -> String {
        "Restored \(org) to the queue"
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

    // #499: a non-send mutation (keep/dismiss, draft edit, manual outcome, booking confirm, ...)
    // whose local save fails must say so instead of looking like nothing happened.
    static func saveFailed(org: String) -> String {
        "Couldn't save the change for \(org)"
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
