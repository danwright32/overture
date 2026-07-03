import Testing
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

    // #477: a send (or reply send) can succeed at Gmail but fail to persist locally, which must
    // never look like nothing happened.
    @Test("a send-receipt save failure names the org and points at Gmail")
    func sendNotConfirmed() {
        #expect(ActionAck.sendNotConfirmed(org: "Aurora Strings")
                == "Couldn't save what happened sending to Aurora Strings: check Gmail to see if it went out.")
    }
}
