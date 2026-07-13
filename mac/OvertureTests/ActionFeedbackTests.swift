import Testing
import Foundation
@testable import Overture

// #285: the no-silent-no-op sweep. Controls whose effect isn't otherwise visible (the voice-learning
// toggle, restore-from-dismissed, the follow-up sends that fire async in a sheet) push a short
// acknowledgment through a shared ActionFeedback object. These tests pin the state machine and the
// exact copy, including the failure path, so a control never completes with nothing to show.

@MainActor
@Suite("Action feedback (#285)")
struct ActionFeedbackTests {
    @Test("acknowledge surfaces the message and bumps the revision")
    func acknowledgeSetsMessage() {
        let f = ActionFeedback()
        #expect(f.message == nil)
        f.acknowledge("Done")
        #expect(f.message == "Done")
        #expect(f.revision == 1)
    }

    @Test("a repeated identical message still bumps the revision so the banner restarts")
    func repeatStillBumps() {
        let f = ActionFeedback()
        f.acknowledge("Same")
        f.acknowledge("Same")
        #expect(f.revision == 2)
    }

    @Test("a failure carries the warning tone; info is the default")
    func tones() {
        let f = ActionFeedback()
        f.acknowledge("Sent")
        #expect(f.tone == .info)
        f.acknowledge("Failed", tone: .warning)
        #expect(f.tone == .warning)
    }

    @Test("clear removes the message")
    func clearResets() {
        let f = ActionFeedback()
        f.acknowledge("Done")
        f.clear()
        #expect(f.message == nil)
    }

    // MARK: - An acknowledgment that can be taken back (#845)

    @Test("an acknowledgment can carry an action, and running it does what it says")
    func actionRuns() {
        let f = ActionFeedback()
        var undone = false
        f.acknowledge("Stopped watching Bargemusic",
                      action: .init(label: "Undo") { undone = true })

        #expect(f.action?.label == "Undo")
        f.action?.perform()
        #expect(undone)
    }

    // THE STALE UNDO, which is the way this goes wrong and quietly does real damage.
    //
    // The banner is one shared surface. If an Undo outlived the message it belonged to, the next
    // acknowledgment (a send, a save failure) would inherit it, and a button labelled "Undo" sitting under
    // "Follow-up sent to Bargemusic" would silently resume a source Dan stopped ten minutes ago. Every
    // acknowledgment replaces the action, and an acknowledgment with no action HAS no action.
    @Test("a later acknowledgment never inherits the previous one's action")
    func actionNeverOutlivesItsMessage() {
        let f = ActionFeedback()
        f.acknowledge("Stopped watching Bargemusic", action: .init(label: "Undo") {})
        f.acknowledge("Follow-up sent to Aurora Strings")

        #expect(f.action == nil)
    }

    @Test("clear removes the action too")
    func clearResetsTheAction() {
        let f = ActionFeedback()
        f.acknowledge("Stopped watching Bargemusic", action: .init(label: "Undo") {})
        f.clear()

        #expect(f.action == nil)
    }

    // An undoable message has to outlast a glance. The banner's normal life is 3.2 seconds, which is fine
    // for "Sent" (which asks nothing of Dan) and far too short for one offering him a decision. The rule
    // lives here rather than in the banner view, where no test could reach it (#863/#885).
    @Test("a message offering an action stays up long enough to use it")
    func anUndoableMessageStaysLonger() {
        #expect(ActionFeedback.dismissAfter(hasAction: true)
                > ActionFeedback.dismissAfter(hasAction: false))
        #expect(ActionFeedback.dismissAfter(hasAction: true) >= 8)
    }
}

@Suite("Action acknowledgment copy (#285)")
struct ActionAckTests {
    @Test("voice-learning toggle names the org and both directions")
    func voiceLearning() {
        #expect(ActionAck.voiceLearning(excluded: true, org: "Aurora Strings")
                == "Won't learn from Aurora Strings's email")
        #expect(ActionAck.voiceLearning(excluded: false, org: "Aurora Strings")
                == "Learning from Aurora Strings's email again")
    }

    @Test("restore confirms where the prospect went, since the queue is offscreen behind the sheet")
    func restored() {
        #expect(ActionAck.restored(org: "Lumen Dance") == "Restored Lumen Dance to the queue")
    }

    @Test("a follow-up send acknowledges both success and failure")
    func followUpSent() {
        #expect(ActionAck.followUpSent(org: "City Brass", success: true)
                == "Follow-up sent to City Brass")
        #expect(ActionAck.followUpSent(org: "City Brass", success: false)
                == "Couldn't send the follow-up to City Brass")
    }

    @Test("a conversation nudge distinguishes a closing note and a plain nudge, success or not")
    func conversationNudge() {
        #expect(ActionAck.conversationNudge(org: "Old Town Opera", closing: false, success: true)
                == "Nudge sent to Old Town Opera")
        #expect(ActionAck.conversationNudge(org: "Old Town Opera", closing: true, success: true)
                == "Closing note sent to Old Town Opera")
        #expect(ActionAck.conversationNudge(org: "Old Town Opera", closing: false, success: false)
                == "Couldn't send the nudge to Old Town Opera")
        #expect(ActionAck.conversationNudge(org: "Old Town Opera", closing: true, success: false)
                == "Couldn't send the closing note to Old Town Opera")
    }

    @Test("remind-me-later disambiguates a snooze from a send")
    func remindLater() {
        #expect(ActionAck.remindLater(org: "Aurora Strings")
                == "Snoozed Aurora Strings. I'll remind you later.")
    }

    @Test("recipientAdded reports the total count and any warnings")
    func recipientAddedMessage() {
        #expect(ActionAck.recipientAdded(name: "Jane Doe", org: "Aurora Strings", totalCount: 3, warnings: [])
                == "Added Jane Doe. 3 recipients on Aurora Strings now.")
        #expect(ActionAck.recipientAdded(name: nil, org: "Aurora Strings", totalCount: 1, warnings: [])
                == "Added the contact. 1 recipient on Aurora Strings now.")
        #expect(ActionAck.recipientAdded(name: "Jane Doe", org: "Aurora Strings", totalCount: 2,
                                         warnings: ["Heads up: looks like the venue's own domain."])
                == "Added Jane Doe. 2 recipients on Aurora Strings now. Heads up: looks like the venue's own domain.")
    }

    @Test("recipientAlreadyExists names who and the show")
    func recipientAlreadyExistsMessage() {
        #expect(ActionAck.recipientAlreadyExists(name: "Jane Doe", org: "Aurora Strings")
                == "Jane Doe is already a recipient on Aurora Strings.")
        #expect(ActionAck.recipientAlreadyExists(name: nil, org: "Aurora Strings")
                == "That contact is already a recipient on Aurora Strings.")
    }

    @Test("recipientResumed and recipientRemoved name who and the show")
    func recipientResumedAndRemovedMessages() {
        #expect(ActionAck.recipientResumed(name: "Jane Doe", org: "Aurora Strings")
                == "Resumed pursuing Jane Doe on Aurora Strings.")
        #expect(ActionAck.recipientRemoved(name: "Jane Doe", org: "Aurora Strings")
                == "Removed Jane Doe from Aurora Strings.")
    }

    // #477: a send (or reply send) can succeed at Gmail but fail to persist locally, which must
    // never look like nothing happened.
    @Test("a send-receipt save failure names the org and points at Gmail")
    func sendNotConfirmed() {
        #expect(ActionAck.sendNotConfirmed(org: "Aurora Strings")
                == "Couldn't save what happened sending to Aurora Strings: check Gmail to see if it went out.")
    }

    // #487: confirming or correcting an unsure classification changes nothing else visible on
    // the row once the chip clears, so both need their own acknowledgment copy.
    @Test("confirming an unsure classification names the org")
    func confidenceConfirmed() {
        #expect(ActionAck.confidenceConfirmed(org: "Aurora Strings")
                == "Confirmed Aurora Strings's classification")
    }

    @Test("correcting a classification names the org")
    func classificationCorrected() {
        #expect(ActionAck.classificationCorrected(org: "Aurora Strings")
                == "Updated Aurora Strings's classification")
    }
}

// #487: markConfidenceReviewed and correctClassification handle the "Unsure call" menu's
// confirm/correct actions but didn't route through ActionFeedback like snooze/restore/voice
// already do, so tapping "This looks right" on a lead whose score doesn't move gave no signal
// it registered. Both live on QueueView, a SwiftUI View backed by @Environment/@Query, so they
// can't be invoked directly in a unit test; scan their source bodies instead, the same guard
// technique SendReceiptSaveGuardTests uses for #477.
@Suite("Confidence-flag actions acknowledge (#487)")
struct ConfidenceFeedbackGuardTests {
    private func queueViewSource() throws -> String {
        let queueView = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("Overture/UI/ProspectMutations.swift")
        return try String(contentsOf: queueView, encoding: .utf8)
    }

    @Test func markConfidenceReviewedAcknowledges() throws {
        let body = try SourceGuard.functionBody(named: "markConfidenceReviewed", in: try queueViewSource())
        #expect(body.contains("feedback.acknowledge("),
                "markConfidenceReviewed must acknowledge via ActionFeedback so confirming a classification is never a silent no-op (#487).")
    }

    @Test func correctClassificationAcknowledges() throws {
        let body = try SourceGuard.functionBody(named: "correctClassification", in: try queueViewSource())
        #expect(body.contains("feedback.acknowledge("),
                "correctClassification must acknowledge via ActionFeedback so correcting a classification is never a silent no-op (#487).")
    }
}
