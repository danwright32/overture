import Testing
import Foundation


// #2928: the one Gmail fixture builder, at file scope.
private let sharedThreadGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")
// #2032. Once one email can reach two people (#2031), a Gmail thread can carry more than one contact,
// and the two things watched on a thread stop being the same KIND of fact.
//
// A REPLY is a fact about the thread. Somebody at that organisation wrote back, the conversation is
// live, and nothing further should go out cold to anyone reading it. Marking every contact on the
// thread loses nothing, and it is also what lets the thread leave the watch set in one piece instead of
// being re-fetched forever because one member is marked and another is not.
//
// A BOUNCE is a fact about ONE address, and the app cannot tell which. `BounceDetection` classifies from
// the From and Subject headers only, and says so as a design property; the failed address lives in the
// delivery-status part of the body, which is never fetched. So a bounce on a shared thread marks NOBODY
// and reports itself instead. Marking both would set `bounced` on somebody whose mail arrived, which
// drops them out of follow-ups and the reached-out queue and closes the show: one typed address would
// silently write off the whole show.
@Suite("Replies and bounces on a thread two contacts share (#2032)")
struct SharedThreadReplyAndBounceTests {
    @MainActor
    private static func show(threadId: String = "thread-1", secondThreadId: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora", discipline: "music", venue: "V",
                         performanceDate: "2026-08-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        let a = Recipient(id: "emma@org.example", email: "emma@org.example", name: "Emma", provenance: .presenter)
        let b = Recipient(id: "noah@org.example", email: "noah@org.example", name: "Noah", provenance: .presenter)
        for r in [a, b] {
            r.sendState = .sent
            r.sentAt = Date(timeIntervalSince1970: 100)
        }
        a.gmailThreadId = threadId
        b.gmailThreadId = secondThreadId ?? threadId
        p.setRecipients([a, b])
        return p
    }

    @MainActor
    private static func oneContactShow(threadId: String = "thread-1") -> Prospect {
        let p = show(threadId: threadId)
        p.setRecipients([p.recipients[0]])
        return p
    }

    private static func replyJSON(from: String, id: String = "r-1", text: String = "Sounds good") -> Data {
        sharedThreadGmail.thread([
            .init(from: "dan@danwrightphotography.com", id: "m-0", internalDateMillis: 100),
            .init(from: from, id: id, internalDateMillis: 200, text: text),
        ])
    }

    private static func hardBounceJSON(id: String = "bounce-1") -> Data {
        sharedThreadGmail.thread([
            .init(from: "mailer-daemon@googlemail.com",
                  subject: "Delivery Status Notification (Failure)", id: id, internalDateMillis: 200),
        ])
    }

    private static let me = "dan@danwrightphotography.com"

    // MARK: - a reply belongs to the thread

    @Test @MainActor func areplyOnASharedThreadMarksEveryContactOnIt() {
        let p = Self.show()
        let json = Self.replyJSON(from: "emma@org.example")

        ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: Date(timeIntervalSince1970: 300),
                                   fetchThread: { _ in json }, fetchFullThread: { _ in json })

        #expect(p.recipients.allSatisfy { $0.replied },
                "both people are reading this conversation, so neither should be written to cold again")
    }

    // The text is evidence of who said it. It goes to the person whose address it came from, and to
    // nobody else, or the conversation surface would attribute one person's words to another.
    @Test @MainActor func thereplyTextIsCreditedOnlyToTheAddressItCameFrom() {
        let p = Self.show()
        let json = Self.replyJSON(from: "Noah <noah@org.example>", text: "Yes please")

        ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: Date(timeIntervalSince1970: 300),
                                   fetchThread: { _ in json }, fetchFullThread: { _ in json })

        let noah = p.recipients.first { $0.email == "noah@org.example" }
        let emma = p.recipients.first { $0.email == "emma@org.example" }
        #expect(noah?.lastReplyText?.contains("Yes please") == true)
        #expect(emma?.lastReplyText == nil, "Emma did not write this, so it must not be filed under her name")
    }

    // A reply from an address nobody was written to (a colleague brought in, somebody answering from
    // their own account rather than the shared inbox) is still a reply. It must never vanish because the
    // app could not name the author (L10): the conversation shows as live.
    //
    // #2147 changed what happens to the WORDS. Filing them under nobody discarded them, and the reply
    // panel then told Dan "Overture didn't capture what they wrote" about a message it had just read.
    // Measured on the live store: he pitched nbecker@ and Nicole answered from nicolebecker@, so this is
    // the ordinary case and not an exotic one. The words belong to the CONVERSATION, so every contact on
    // the thread keeps them, and replyFromAddress names who actually wrote so nothing is misattributed.
    @Test @MainActor func areplyFromAnAddressNobodyWasWrittenToKeepsItsWords() {
        let p = Self.show()
        let json = Self.replyJSON(from: "assistant@org.example", text: "Passing this to Emma")

        ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: Date(timeIntervalSince1970: 300),
                                   fetchThread: { _ in json }, fetchFullThread: { _ in json })

        #expect(p.recipients.allSatisfy { $0.replied }, "a reply the app cannot attribute is still a reply")
        #expect(p.recipients.allSatisfy { $0.lastReplyText == "Passing this to Emma" },
                "the conversation's words must survive a sender who is none of its contacts")
        #expect(p.recipients.allSatisfy { $0.replyFromAddress == "assistant@org.example" },
                "and the writer is named, which is what keeps the words honest")
    }

    // Every thread in the live store today carries exactly one contact, so this is the case that must not
    // move at all.
    @Test @MainActor func athreadWithOneContactBehavesExactlyAsBefore() {
        let p = Self.oneContactShow()
        let json = Self.replyJSON(from: "emma@org.example", text: "Sounds good")

        ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: Date(timeIntervalSince1970: 300),
                                   fetchThread: { _ in json }, fetchFullThread: { _ in json })

        let only = p.recipients[0]
        #expect(only.replied)
        #expect(only.lastReplyText?.contains("Sounds good") == true)
        #expect(only.repliedAt == Date(timeIntervalSince1970: 300))
    }

    // Two contacts on the SAME show but their OWN threads is the ordinary multi-contact case, and it is
    // not a group: each thread still answers only for its own contact.
    @Test @MainActor func twoContactsOnSeparateThreadsAreStillJudgedSeparately() {
        let p = Self.show(threadId: "thread-emma", secondThreadId: "thread-noah")
        let json = Self.replyJSON(from: "emma@org.example")

        ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: Date(timeIntervalSince1970: 300),
                                   fetchThread: { id in id == "thread-emma" ? json : nil },
                                   fetchFullThread: { id in id == "thread-emma" ? json : nil })

        #expect(p.recipients.first { $0.email == "emma@org.example" }?.replied == true)
        #expect(p.recipients.first { $0.email == "noah@org.example" }?.replied == false)
    }

    // MARK: - a bounce belongs to one address the app cannot name

    @Test @MainActor func abounceOnASharedThreadMarksNobody() {
        let p = Self.show()

        BounceService.detectBounces(in: [p], selfEmail: Self.me, now: Date(timeIntervalSince1970: 300),
                                    fetchThread: { _ in Self.hardBounceJSON() })

        #expect(p.recipients.allSatisfy { $0.bounced == false },
                "one dead address must never write off the contact whose mail arrived")
    }

    // Not marking is only half of it. Failing silently would leave a bounce nobody ever hears about, so
    // it reports itself, naming the show and both addresses (L13).
    @Test @MainActor func abounceOnASharedThreadIsReported() {
        let p = Self.show()
        var reported: [String] = []

        BounceService.detectBounces(in: [p], selfEmail: Self.me, now: Date(timeIntervalSince1970: 300),
                                    fetchThread: { _ in Self.hardBounceJSON() },
                                    reportProblem: { reported.append($0) })

        #expect(reported.count == 1)
        #expect(reported.first?.contains("emma@org.example") == true)
        #expect(reported.first?.contains("noah@org.example") == true)
        #expect(reported.first?.contains("Aurora") == true)
    }

    // The reply watcher runs on a timer, so a report that fires on every pass is a report Dan learns to
    // ignore (L36). The same bounce notice is announced once.
    @Test @MainActor func thesameSharedBounceIsReportedOnlyOnce() {
        let p = Self.show()
        var reported: [String] = []
        let report: (String) -> Void = { reported.append($0) }

        for _ in 0..<3 {
            BounceService.detectBounces(in: [p], selfEmail: Self.me, now: Date(timeIntervalSince1970: 300),
                                        fetchThread: { _ in Self.hardBounceJSON() },
                                        reportProblem: report)
        }

        #expect(reported.count == 1)
    }

    // A NEWER bounce notice on the same thread is a new fact and is reported again.
    @Test @MainActor func alaterBounceOnTheSameSharedThreadIsReportedAgain() {
        let p = Self.show()
        var reported: [String] = []
        let report: (String) -> Void = { reported.append($0) }

        BounceService.detectBounces(in: [p], selfEmail: Self.me, now: Date(timeIntervalSince1970: 300),
                                    fetchThread: { _ in Self.hardBounceJSON(id: "bounce-1") },
                                    reportProblem: report)
        BounceService.detectBounces(in: [p], selfEmail: Self.me, now: Date(timeIntervalSince1970: 400),
                                    fetchThread: { _ in Self.hardBounceJSON(id: "bounce-2") },
                                    reportProblem: report)

        #expect(reported.count == 2)
    }

    // The single-contact case, which is every thread in the live store today: unchanged, still marked.
    @Test @MainActor func abounceOnAOneContactThreadStillMarksThatContact() {
        let p = Self.oneContactShow()
        var reported: [String] = []

        BounceService.detectBounces(in: [p], selfEmail: Self.me, now: Date(timeIntervalSince1970: 300),
                                    fetchThread: { _ in Self.hardBounceJSON() },
                                    reportProblem: { reported.append($0) })

        #expect(p.recipients[0].bounced)
        #expect(reported.isEmpty, "there is nothing ambiguous to report when one contact is on the thread")
    }
}
