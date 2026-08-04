import Testing
import Foundation

// #2063: who a reply was addressed to, read off the message being answered.
//
// Overture used to address Dan's response to everyone who received the ORIGINAL email, which is a record
// of what Overture did rather than of what the other side chose. Dan's rule, 2026-08-04: "it should mimic
// them. if they reply all, i should reply all. if they respond directly to me I should reply directly to
// them. if they respond and remove 2 of the other 4 people and only include 3 of the original 5, I should
// do the same."
//
// The audience of a reply is its sender PLUS everyone else it names, minus Dan: on a reply-all the sender
// sits in From and the rest in To/Cc, so taking only To/Cc would answer everybody except the person who
// actually wrote.
@Suite("The audience of the reply being answered")
struct ReplyAudienceTests {
    private let me = "dan@danwrightphotography.com"

    // A Gmail threads.get (format=full) response, which is the shape the reply checker already fetches for
    // any thread carrying a reply.
    private func thread(_ messages: [(from: String, to: String?, cc: String?, date: String)]) -> Data {
        let msgs: [[String: Any]] = messages.enumerated().map { i, m in
            var headers: [[String: Any]] = [["name": "From", "value": m.from]]
            if let to = m.to { headers.append(["name": "To", "value": to]) }
            if let cc = m.cc { headers.append(["name": "Cc", "value": cc]) }
            return ["id": "m\(i)", "internalDate": m.date, "payload": ["headers": headers]]
        }
        return try! JSONSerialization.data(withJSONObject: ["messages": msgs])
    }

    @Test func aDirectReplyReachesOnlyThePersonWhoWroteIt() {
        let data = thread([
            (from: me, to: "a@org.example, b@org.example", cc: nil, date: "1000"),
            (from: "Ann <a@org.example>", to: me, cc: nil, date: "2000"),
        ])

        #expect(ReplyDetection.latestReplyAudience(threadJSON: data, selfEmail: me) == ["a@org.example"])
    }

    @Test func aReplyAllReachesTheWriterAndEveryoneElseOnIt() {
        let data = thread([
            (from: me, to: "a@org.example, b@org.example", cc: nil, date: "1000"),
            (from: "Ann <a@org.example>", to: "\(me), b@org.example", cc: nil, date: "2000"),
        ])

        #expect(ReplyDetection.latestReplyAudience(threadJSON: data, selfEmail: me)
                == ["a@org.example", "b@org.example"])
    }

    // Dan's own worked example: five on the original, the reply keeps three of them.
    @Test func aReplyThatDropsPeopleReachesOnlyTheOnesItKept() {
        let five = "a@org.example, b@org.example, c@org.example, d@org.example, e@org.example"
        let data = thread([
            (from: me, to: five, cc: nil, date: "1000"),
            (from: "Ann <a@org.example>", to: "\(me), b@org.example", cc: "c@org.example", date: "2000"),
        ])

        #expect(ReplyDetection.latestReplyAudience(threadJSON: data, selfEmail: me)
                == ["a@org.example", "b@org.example", "c@org.example"])
    }

    // Somebody the writer brought in is on the conversation, which is what reply-all means.
    @Test func anAddressTheWriterAddedIsIncluded() {
        let data = thread([
            (from: me, to: "a@org.example", cc: nil, date: "1000"),
            (from: "Ann <a@org.example>", to: me, cc: "newcomer@other.example", date: "2000"),
        ])

        #expect(ReplyDetection.latestReplyAudience(threadJSON: data, selfEmail: me)
                == ["a@org.example", "newcomer@other.example"])
    }

    @Test func danIsNeverInTheAudienceOfHisOwnReply() {
        let data = thread([
            (from: me, to: "a@org.example", cc: nil, date: "1000"),
            (from: "Ann <a@org.example>", to: "Dan Wright <\(me)>", cc: nil, date: "2000"),
        ])
        let audience = ReplyDetection.latestReplyAudience(threadJSON: data, selfEmail: me)

        #expect(audience?.contains(me) == false)
    }

    // The newest inbound message decides, matching every other latestReply helper: an older reply-all must
    // not set the audience for a newer private one.
    @Test func theNewestReplyDecidesNotAnOlderOne() {
        let data = thread([
            (from: me, to: "a@org.example, b@org.example", cc: nil, date: "1000"),
            (from: "Ann <a@org.example>", to: "\(me), b@org.example", cc: nil, date: "2000"),
            (from: "Ann <a@org.example>", to: me, cc: nil, date: "3000"),
        ])

        #expect(ReplyDetection.latestReplyAudience(threadJSON: data, selfEmail: me) == ["a@org.example"])
    }

    // Nothing to mirror is reported as nothing, never as an empty audience: the caller has to be able to
    // tell "he replied to nobody" (impossible) from "this was never captured", which decides whether the
    // send falls back.
    @Test func aThreadWithNoReplyReportsNothing() {
        let data = thread([(from: me, to: "a@org.example", cc: nil, date: "1000")])

        #expect(ReplyDetection.latestReplyAudience(threadJSON: data, selfEmail: me) == nil)
    }

    @Test func anAutomatedSenderIsNotAReplyToMirror() {
        let data = thread([
            (from: me, to: "a@org.example", cc: nil, date: "1000"),
            (from: "noreply@org.example", to: me, cc: nil, date: "2000"),
        ])

        #expect(ReplyDetection.latestReplyAudience(threadJSON: data, selfEmail: me) == nil)
    }

    // A duplicate across From, To and Cc must not send the same person two copies.
    @Test func anAddressNamedTwiceAppearsOnce() {
        let data = thread([
            (from: me, to: "a@org.example", cc: nil, date: "1000"),
            (from: "Ann <a@org.example>", to: "\(me), A@Org.Example", cc: "a@org.example", date: "2000"),
        ])

        #expect(ReplyDetection.latestReplyAudience(threadJSON: data, selfEmail: me) == ["a@org.example"])
    }
}
