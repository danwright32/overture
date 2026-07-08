import Testing
import Foundation
@testable import Overture

// Pure classification for #398: a genuine HARD (permanent) Gmail bounce is a message from a
// bounce-notification sender (mailer-daemon/postmaster) whose subject reads as a permanent
// failure, not a temporary delay. Deliberately conservative: sender AND subject must both
// match, so a still-reachable contact is never silenced by a soft bounce or an unrelated
// automated sender.
@Suite("Bounce detection")
struct BounceDetectionTests {
    @Test func recognizesMailerDaemonAndPostmasterAsBounceSenders() {
        #expect(BounceDetection.isBounceSender("mailer-daemon@googlemail.com"))
        #expect(BounceDetection.isBounceSender("MAILER-DAEMON@googlemail.com"))
        #expect(BounceDetection.isBounceSender("postmaster@example.com"))
    }

    @Test func doesNotMistakeARealAddressContainingTheWordForABounceSender() {
        // "bouncebackband" and "eleanoreply" are the ReplyDetection precedent for this same
        // substring trap; postmaster/mailer-daemon get the identical guard via matchesToken.
        #expect(!BounceDetection.isBounceSender("postmastermind@example.com"))
        #expect(!BounceDetection.isBounceSender("manager@bachsociety.org"))
    }

    @Test func recognizesAPermanentFailureSubject() {
        #expect(BounceDetection.isHardBounceSubject("Delivery Status Notification (Failure)"))
        #expect(BounceDetection.isHardBounceSubject("Undelivered Mail Returned to Sender"))
        #expect(BounceDetection.isHardBounceSubject("Mail delivery failed: returning message to sender"))
    }

    @Test func doesNotTreatATemporaryDelayAsAHardBounce() {
        #expect(!BounceDetection.isHardBounceSubject("Delivery Status Notification (Delay)"))
        #expect(!BounceDetection.isHardBounceSubject("Delayed Mail (still being retried)"))
    }

    @Test func doesNotTreatAnUnrelatedSubjectAsABounce() {
        #expect(!BounceDetection.isHardBounceSubject("Re: Carnegie Hall performance opportunity"))
    }

    private func threadJSON(from: String, subject: String, id: String = "m1") -> Data {
        let json = #"{"messages":[{"id":""# + id + #"","payload":{"headers":["#
            + #"{"name":"From","value":""# + from + #""},"#
            + #"{"name":"Subject","value":""# + subject + #""}"#
            + #"]}}]}"#
        return Data(json.utf8)
    }

    @Test func findsTheHardBounceMessageIdWhenSenderAndSubjectBothMatch() {
        let data = threadJSON(from: "Mail Delivery Subsystem <mailer-daemon@googlemail.com>",
                              subject: "Delivery Status Notification (Failure)", id: "bounce-1")
        #expect(BounceDetection.hardBounceMessageId(threadJSON: data, selfEmail: "dan@danwrightphotography.com") == "bounce-1")
    }

    @Test func ignoresASoftBounceEvenFromABounceSender() {
        let data = threadJSON(from: "mailer-daemon@googlemail.com",
                              subject: "Delivery Status Notification (Delay)")
        #expect(BounceDetection.hardBounceMessageId(threadJSON: data, selfEmail: "dan@danwrightphotography.com") == nil)
    }

    @Test func ignoresAFailureSubjectFromAnOrdinaryReplySender() {
        // A real person's "This failed to reach the venue" reply must never be misread as a bounce.
        let data = threadJSON(from: "manager@bachsociety.org", subject: "Failure to connect, sorry")
        #expect(BounceDetection.hardBounceMessageId(threadJSON: data, selfEmail: "dan@danwrightphotography.com") == nil)
    }

    @Test func returnsNilForAThreadWithNoBounceMessage() {
        let data = threadJSON(from: "manager@bachsociety.org", subject: "Re: opportunity")
        #expect(BounceDetection.hardBounceMessageId(threadJSON: data, selfEmail: "dan@danwrightphotography.com") == nil)
    }

    // #398 review finding: a dismissed bounce (bounce-1) must not silently block a genuinely
    // NEWER bounce (bounce-2) landing on the same thread later, since Gmail's threads.get array
    // order isn't guaranteed chronological (the #482 precedent for replies). Array position 0
    // here is the OLDER message, so a fix that just returns the first array match would wrongly
    // return "bounce-1" instead of the newest, "bounce-2".
    @Test func returnsTheNewestHardBounceNotArrayPosition() {
        let json = Data(#"""
        {"messages":[
          {"id":"bounce-1","internalDate":"1000","payload":{"headers":[
            {"name":"From","value":"mailer-daemon@googlemail.com"},
            {"name":"Subject","value":"Delivery Status Notification (Failure)"}
          ]}},
          {"id":"bounce-2","internalDate":"2000","payload":{"headers":[
            {"name":"From","value":"mailer-daemon@googlemail.com"},
            {"name":"Subject","value":"Delivery Status Notification (Failure)"}
          ]}}
        ]}
        """#.utf8)
        #expect(BounceDetection.hardBounceMessageId(threadJSON: json, selfEmail: "dan@danwrightphotography.com") == "bounce-2")
    }
}
