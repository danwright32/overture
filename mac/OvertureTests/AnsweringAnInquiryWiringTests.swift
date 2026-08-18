import Testing
import Foundation

// #2943, the half a behavioural test cannot hold on its own: the answer must never again be SAID by
// clearing `replied`.
//
// Two paths did exactly that, and each looked reasonable in isolation, because with no field for the fact
// there was nothing else to write. Both are one line, both sit in files nobody opens often, and a future
// edit that reaches for the old idiom would pass every behavioural test that happens not to look at
// `replied` afterwards. So the shape itself is refused, in the two places it lived (L30: the class, not
// the instance).
//
// Its own file rather than a suite beside the behaviour, for the reason #2816 and #2919 both recorded:
// #629's meta-guard sweeps a test file's array literals for the function names a `named:` loop stands
// for, so the helper below takes its function name under that label deliberately.
@Suite("An inquiry's answer is never recorded by taking the reply back (#2943)")
struct AnsweringAnInquiryWiringTests {

    private func body(named name: String, in path: String) throws -> String {
        let source = SourceGuardHelper.source(path)
        #expect(!source.isEmpty)
        return try #require(SourceGuardHelper.bodyOfFunction(named: name, in: source),
                            "\(name) was not found in \(path)")
    }

    // The reply sender: the path #2943 was filed from.
    @Test func theSenderStampsTheAnswerRatherThanClearingTheReply() throws {
        let sendReply = try body(named: "sendReply", in: "Overture/Integration/InquiryReplySender.swift")
        #expect(!SourceGuardHelper.containsCode("inquiry.replied = false", in: sendReply),
                "answering an inquiry erases the evidence a reply ever arrived again (#2943, L163)")
        #expect(SourceGuardHelper.containsCode("inquiry.markReplyAnswered(now: now)", in: sendReply),
                "the sender no longer records that Dan answered")
    }

    // The sibling, one file away: linking a conversation he had already answered in Gmail (#2868). Scoped
    // to the inquiry half of `AttachConversation`, since the pitch half above it is a different entity
    // with its own fields.
    @Test func theAttachStampsTheAnswerRatherThanClearingTheReply() throws {
        let source = SourceGuardHelper.source("Overture/Domain/AttachConversation.swift")
        let inquiryHalf = try #require(
            SourceGuardHelper.between("to inquiry: Inquiry,", and: "return .attached(", in: source),
            "the inquiry attach was not found where this guard expects it")
        #expect(!SourceGuardHelper.containsCode("inquiry.replied = false", in: inquiryHalf),
                "linking an answered conversation erases the reply it found again (#2943, #2868)")
        #expect(inquiryHalf.contains("inquiry.replyHandledAt = now"),
                "the attach no longer records that Dan had already answered")
    }

    // Built is not wired (L3). The sentence exists only if the row asks for it, and the row is a snapshot
    // built in one place, so that is where the ask has to be.
    @Test func theInquiryRowAsksForTheAnsweredSentence() throws {
        let rows = try body(named: "inquiryRows", in: "Overture/UI/QueueView+Model.swift")
        #expect(rows.contains("AnsweredReplyNote.line("),
                "the inquiry row no longer says that a reply arrived and was answered (#2943)")
    }

    // The predicate is shared, not re-derived, which is the rule #2919 pinned on the contact side and the
    // same reason it matters here: two definitions of "has this been dealt with" is how a row asserts
    // somebody is waiting hours after Dan wrote back.
    @Test func theAnsweredPredicateIsWrittenOverTheUnhandledOne() throws {
        let source = SourceGuardHelper.source("Overture/Domain/Inquiry.swift")
        let body = try #require(SourceGuardHelper.propertyBody("var replyIsAnswered: Bool {", in: source),
                                "replyIsAnswered was not found on Inquiry")
        #expect(body.contains("hasUnhandledReply"),
                "replyIsAnswered no longer shares hasUnhandledReply, so the two can now disagree (#2921)")
    }
}
