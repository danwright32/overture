import Testing
import Foundation

// #3694: the auto-reply invariant was measuring from the wrong clock, so it fired on a conversation Dan
// answered himself and stayed silent on one it was written to catch.
//
// `ReplyInvariantsLiveStoreTests.noConversationWasSilencedByWhatLooksLikeAnAutomaticReply` decides its
// signature from `replyHandledAt - repliedAt`. Its own sentence says what it means to compare: "an answer
// recorded from Dan's own address within a couple of minutes of THEIRS". But `repliedAt` is not their
// message. `Recipient.swift:428` says so in as many words: "When Overture NOTICED a reply. Not when it
// was written: the watcher stamps this as it runs, so a reply that lands while the app is shut carries
// the next launch. `inboundReplySentAt` is the real thing and is preferred wherever the date is shown or
// grouped (#2113)."
//
// So it subtracts an OBSERVATION time from a MESSAGE time, and what sits between them is the watcher's
// noticing lag. Measured on the live store 2026-09-08, that lag runs from 65 seconds to 23 hours across
// the eleven answered conversations, which is far wider than the 90 second window the rule turns on
// (L589: a relative magnitude must name what it is relative to, and where the anchor can move it must
// name which anchor it used).
//
// IT FAILS IN BOTH DIRECTIONS, which is why this is a unit test over a pure rule rather than a tweak in
// the live suite. Both cases below are REAL rows, with their real instants:
//
//   - A large lag pulls `repliedAt` up towards the answer and the gap shrinks under the window with
//     nothing suspicious having happened. That is what went red today.
//   - A larger lag pushes the gap NEGATIVE, and negatives are filtered out by `gap >= 0`, so the rule
//     discards the row entirely. One live row has a genuine 82 second answer and has never once been
//     reported, because its measured gap was minus 1,622.
//
// The comment in that suite explains its negative gaps as "the ordinary 'they wrote again after he
// answered' shape". That explanation is an artefact of the same subtraction: every negative row on the
// live store has a POSITIVE gap once measured from the sender's own instant.
//
// THE RULE LIVES HERE, as a pure function over three instants, so it can be exercised without Dan's
// store. Before this it existed only inline in a live-store test, so the only way to run it was against
// his real data, which cannot hold a case on purpose and cannot be re-run against a shape nobody has yet.
enum AutomaticAnswerSignature {

    // Ninety seconds. Above the few seconds an autoresponder takes and far below anything a person does.
    static let window: TimeInterval = 90

    /// The three instants one answered conversation carries, named for which clock each comes from.
    struct Conversation {
        /// When THEY sent it, from the message itself. The anchor the signature is about.
        let theirMessageSentAt: Date?
        /// When Overture NOTICED it. A property of the watcher's schedule, never of the conversation.
        let noticedAt: Date?
        /// When the answer from Dan's address was sent, from that message. `replyHandledAt`.
        let answeredAt: Date
        /// Whether this row was written by the conversation attach in one write (#3171), where the two
        /// instants are equal for an arithmetic reason rather than because anything answered anything.
        let recordedInOneWriteWithTheAttach: Bool
    }

    /// What a conversation is, once judged. Three cases and not two, because a row that cannot be
    /// measured must not read as a row that was measured and found clean (L98, L11).
    enum Verdict: Equatable {
        case suspicious(gap: TimeInterval)
        case answeredByAPerson(gap: TimeInterval)
        case setAsideAsAnAttachWrite
        case unmeasurable(why: String)
    }

    static func judge(_ c: Conversation) -> Verdict {
        if c.recordedInOneWriteWithTheAttach { return .setAsideAsAnAttachWrite }
        // The anchor is THEIR message and nothing else. A row without one cannot be judged at all, and
        // falling back to `noticedAt` here would quietly reintroduce the whole defect for exactly the
        // rows that have no better evidence (L214: a fallback written for an absent source must not
        // silently answer a different question).
        guard let theirs = c.theirMessageSentAt else {
            return .unmeasurable(why: "no send time on their message, so there is no anchor to measure from")
        }
        let gap = c.answeredAt.timeIntervalSince(theirs)
        // An answer BEFORE their message belongs to an earlier round of the conversation and says nothing
        // about the message now waiting. That is a real shape here, unlike in the old rule where every
        // negative was the noticing lag.
        guard gap >= 0 else {
            return .unmeasurable(why: "the answer predates their message, so it answers an earlier round")
        }
        return gap <= window ? .suspicious(gap: gap) : .answeredByAPerson(gap: gap)
    }
}

@Suite("The auto-reply signature measures from their message, not from when Overture noticed (#3694)")
struct AutomaticAnswerSignatureTests {
    private static func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private static func conversation(theirs: String?, noticed: String?, answered: String,
                                     attachWrite: Bool = false) -> AutomaticAnswerSignature.Conversation {
        AutomaticAnswerSignature.Conversation(
            theirMessageSentAt: theirs.map(at),
            noticedAt: noticed.map(at),
            answeredAt: at(answered),
            recordedInOneWriteWithTheAttach: attachWrite)
    }

    // THE FALSE POSITIVE, with the live row's real instants (Z_PK 435, 2026-09-08). Their message went at
    // 14:11:11, Overture noticed it at 14:20:57, and the answer went at 14:22:08. Measured from the
    // noticing that is 71 seconds and reads as an autoresponder; measured from their message it is 657
    // seconds, which is a person answering in eleven minutes. This is the row that turned the suite red.
    @Test func aLateNoticingDoesNotMakeAPersonsAnswerLookAutomatic() {
        let verdict = AutomaticAnswerSignature.judge(
            Self.conversation(theirs: "2026-09-08T14:11:11Z",
                              noticed: "2026-09-08T14:20:57Z",
                              answered: "2026-09-08T14:22:08Z"))
        #expect(verdict == .answeredByAPerson(gap: 657),
                Comment(rawValue: "judged \(verdict). Measured from when Overture noticed, this gap is 71 "
                        + "seconds and reads as an autoresponder. The noticing lag was 586 seconds and is "
                        + "a property of the watcher's schedule, not of the conversation."))
    }

    // THE FALSE NEGATIVE, and it is the one that matters more. Live row Z_PK 105, 2026-08-31: their
    // message at 16:37:55, the answer at 16:39:17, and Overture did not notice the reply until 17:06:19,
    // twenty-seven minutes after it had already been answered. The old rule measured minus 1,622 seconds
    // and threw the row away as negative, so a genuine 82 second answer has never once been reported by
    // the guard written to find exactly that.
    @Test func aRowNoticedAfterItWasAnsweredIsStillJudgedOnItsRealGap() {
        let verdict = AutomaticAnswerSignature.judge(
            Self.conversation(theirs: "2026-08-31T16:37:55Z",
                              noticed: "2026-08-31T17:06:19Z",
                              answered: "2026-08-31T16:39:17Z"))
        #expect(verdict == .suspicious(gap: 82),
                Comment(rawValue: "judged \(verdict). This is the shape the old rule could never see: the "
                        + "noticing came after the answer, so its gap went negative and the `gap >= 0` "
                        + "filter discarded the row before the window was ever applied."))
    }

    // The #3171 exclusion survives the change, and is asked BEFORE the anchor, because an attach write
    // has nothing to measure whatever its instants say.
    @Test func anAttachWriteIsStillSetAsideRatherThanJudged() {
        let verdict = AutomaticAnswerSignature.judge(
            Self.conversation(theirs: "2026-09-08T14:11:11Z",
                              noticed: "2026-09-08T14:11:11Z",
                              answered: "2026-09-08T14:11:11Z",
                              attachWrite: true))
        #expect(verdict == .setAsideAsAnAttachWrite)
    }

    // A row with no anchor is UNMEASURABLE and says so, rather than falling back to the noticing, which
    // would reintroduce the defect for precisely the rows carrying the least evidence (L214).
    @Test func aRowWithNoSendTimeOnTheirMessageIsUnmeasurableRatherThanClean() {
        let verdict = AutomaticAnswerSignature.judge(
            Self.conversation(theirs: nil,
                              noticed: "2026-09-08T14:20:57Z",
                              answered: "2026-09-08T14:22:08Z"))
        guard case .unmeasurable = verdict else {
            Issue.record(Comment(rawValue: "judged \(verdict), but with no anchor there is nothing to "
                                 + "measure. Falling back to the noticing here is the whole #3694 defect, "
                                 + "kept alive for the rows least able to survive it."))
            return
        }
    }

    // An answer genuinely belonging to an earlier round is still separated, and it is a DIFFERENT case
    // from having no anchor: one is a fact about the conversation, the other about the record (L11).
    @Test func anAnswerPredatingTheirMessageIsItsOwnCaseAndNotSuspicious() {
        let verdict = AutomaticAnswerSignature.judge(
            Self.conversation(theirs: "2026-09-08T14:11:11Z",
                              noticed: "2026-09-08T14:20:57Z",
                              answered: "2026-09-08T09:00:00Z"))
        guard case .unmeasurable = verdict else {
            Issue.record(Comment(rawValue: "judged \(verdict); an answer sent before their message "
                                 + "answers an earlier round"))
            return
        }
        #expect(verdict != .unmeasurable(why: "no send time on their message, so there is no anchor to measure from"),
                "the two unmeasurable cases must not share a wording, or one answers for the other")
    }

    // And the window itself still has teeth on the anchor that now feeds it.
    @Test func anAnswerInsideTheWindowFromTheirOwnMessageIsSuspicious() {
        let verdict = AutomaticAnswerSignature.judge(
            Self.conversation(theirs: "2026-09-08T14:11:11Z",
                              noticed: "2026-09-08T14:11:20Z",
                              answered: "2026-09-08T14:11:15Z"))
        #expect(verdict == .suspicious(gap: 4))
    }
}
