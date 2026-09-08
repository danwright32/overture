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
        /// Somebody read this conversation and settled it. Its own case rather than a silent exclusion,
        /// because an exclusion nobody can see the size of grows to cover the corpus (L182).
        case judgedByHand(reason: String)
        case answeredByAPerson(gap: TimeInterval)
        case setAsideAsAnAttachWrite
        case unmeasurable(why: String)
    }

    static func judge(_ c: Conversation, judged: [JudgedFastAnswers.Entry] = []) -> Verdict {
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
        guard gap <= window else { return .answeredByAPerson(gap: gap) }
        // Asked LAST, and only of a conversation that really is inside the window, so an entry can only
        // ever settle a row the signature actually flagged. Asked earlier it would also swallow rows the
        // rule was never going to raise, and the log would stop being a record of judgements made.
        //
        // BOTH instants have to match. Keyed on the answer alone it would silence every future
        // conversation answered at the same second, which is how an exclusion grows past what anybody
        // agreed to (L182, L100).
        if let entry = judged.first(where: {
            $0.theirMessageSentAt == theirs && $0.answeredAt == c.answeredAt
        }) {
            return .judgedByHand(reason: entry.reason)
        }
        return .suspicious(gap: gap)
    }
}

// The triage log itself: parsing only, so it can be exercised without a file.
enum JudgedFastAnswers {
    struct Entry: Equatable {
        let theirMessageSentAt: Date
        let answeredAt: Date
        let reason: String
    }

    enum Refusal: Error, CustomStringConvertible {
        case malformed(line: String, why: String)
        var description: String {
            switch self {
            case .malformed(let line, let why):
                return "fixtures/answered-fast-by-hand.txt has a line this cannot read (\(why)): \(line)"
            }
        }
    }

    // COMPUTED, not stored. A stored static is one variable per process, so two tests parsing at once
    // would share this formatter's mutable state, and `ISO8601DateFormatter` is not `Sendable` for
    // exactly that reason. A computed one derives its value on every read and holds nothing, which is
    // what `scripts/check-test-shared-state.sh` is looking for (#3270).
    private static var formatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    /// One entry per line: `<their message, ISO8601> <the answer, ISO8601> <why it was settled>`.
    ///
    /// A malformed line is REFUSED rather than skipped. A skipped line reads exactly like a conversation
    /// nobody has judged, so a typo would quietly un-settle a row somebody had settled and the invariant
    /// would go red naming a conversation already dealt with (L100, L11).
    static func parse(_ text: String) throws -> [Entry] {
        var entries: [Entry] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else {
                throw Refusal.malformed(line: line,
                                        why: "expected their instant, the answer instant and a reason")
            }
            guard let theirs = formatter.date(from: String(parts[0])) else {
                throw Refusal.malformed(line: line, why: "the first instant is not ISO8601")
            }
            guard let answered = formatter.date(from: String(parts[1])) else {
                throw Refusal.malformed(line: line, why: "the second instant is not ISO8601")
            }
            entries.append(Entry(theirMessageSentAt: theirs, answeredAt: answered,
                                 reason: String(parts[2]).trimmingCharacters(in: .whitespaces)))
        }
        return entries
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

// #3694: where a judgement about one conversation LIVES.
//
// The signature is a signature and not a proof, which its own message says. A fast answer that really
// was Dan is therefore an ordinary outcome, not a defect, and before this there was nowhere to record
// that: the invariant would go red on it, somebody would look, and the next run would ask again. A
// finding the system cannot see was acted on teaches people to ignore the panel it lives on (L269), and
// a standing red makes every other failure in the list unreadable (L538).
//
// So this is a TRIAGE LOG that GROWS, on `fixtures/test-identity-provenance.txt`'s precedent rather than
// `fixtures/test-data-email-domains.txt`'s: it is a record of conversations somebody has read, not a
// ratchet over a defect being paid off, and new fast answers legitimately arrive as Dan keeps working.
//
// KEYED ON THE TWO INSTANTS, deliberately, and this is the part to keep. Not a name, not an address, not
// a show, not even a Gmail message id: two timestamps identify the conversation for this purpose and
// identify no person, and this is a public repository (L155, L222).
@Suite("Where a judgement about a fast answer lives (#3694)")
struct JudgedFastAnswersTests {
    private static func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private static let log = """
        # a comment, and the blank line below it, are both ignored

        2026-08-31T16:37:55Z 2026-08-31T16:39:17Z Dan answered this himself, confirmed 2026-09-08
        """

    @Test func aJudgedConversationIsNamedAsJudgedRatherThanSuspicious() throws {
        let judged = try JudgedFastAnswers.parse(Self.log)
        let verdict = AutomaticAnswerSignature.judge(
            .init(theirMessageSentAt: Self.at("2026-08-31T16:37:55Z"),
                  noticedAt: Self.at("2026-08-31T17:06:19Z"),
                  answeredAt: Self.at("2026-08-31T16:39:17Z"),
                  recordedInOneWriteWithTheAttach: false),
            judged: judged)
        #expect(verdict == .judgedByHand(reason: "Dan answered this himself, confirmed 2026-09-08"),
                Comment(rawValue: "judged \(verdict). A conversation somebody has read must say so rather "
                        + "than vanish from the count, or the exclusion grows unseen (L182)."))
    }

    @Test func anUnjudgedConversationIsStillSuspicious() throws {
        let judged = try JudgedFastAnswers.parse(Self.log)
        let verdict = AutomaticAnswerSignature.judge(
            .init(theirMessageSentAt: Self.at("2026-09-01T10:00:00Z"),
                  noticedAt: Self.at("2026-09-01T10:30:00Z"),
                  answeredAt: Self.at("2026-09-01T10:00:30Z"),
                  recordedInOneWriteWithTheAttach: false),
            judged: judged)
        #expect(verdict == .suspicious(gap: 30))
    }

    /// BOTH instants key it. A log entry that matched on the answer alone would silence every future
    /// conversation Dan happened to answer at the same second, which is the shape of an exclusion that
    /// grows to cover the corpus (L182, L100).
    @Test func anEntryMatchingOnlyOneInstantDoesNotSilenceAConversation() throws {
        let judged = try JudgedFastAnswers.parse(Self.log)
        let verdict = AutomaticAnswerSignature.judge(
            .init(theirMessageSentAt: Self.at("2026-08-31T16:38:55Z"),
                  noticedAt: nil,
                  answeredAt: Self.at("2026-08-31T16:39:17Z"),
                  recordedInOneWriteWithTheAttach: false),
            judged: judged)
        #expect(verdict == .suspicious(gap: 22))
    }

    /// A malformed line is REFUSED, never skipped. A skipped line reads exactly like a conversation
    /// nobody judged, so a typo would quietly un-judge a row somebody had settled (L100, L11).
    @Test func aMalformedLineIsRefusedRatherThanSkipped() {
        #expect(throws: JudgedFastAnswers.Refusal.self) {
            try JudgedFastAnswers.parse("2026-08-31T16:37:55Z not-a-date reason here")
        }
        #expect(throws: JudgedFastAnswers.Refusal.self) {
            try JudgedFastAnswers.parse("2026-08-31T16:37:55Z 2026-08-31T16:39:17Z")
        }
    }

    /// An empty log is a legitimate state (nothing judged yet) and must parse to nothing rather than
    /// refusing, so the file can be created before it holds anything.
    @Test func anEmptyLogIsNothingJudgedRatherThanARefusal() throws {
        #expect(try JudgedFastAnswers.parse("# nothing yet\n").isEmpty)
    }

    /// And the SHIPPED file parses, so a typo in it is caught here rather than by the live suite going
    /// an unexplained red on a machine that has a store.
    @Test func theShippedLogParses() throws {
        let url = RepoRoot.url.appendingPathComponent("fixtures/answered-fast-by-hand.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        let judged = try JudgedFastAnswers.parse(text)
        #expect(!judged.isEmpty,
                "the shipped log is empty, so every entry in it has been lost or it was never written")
        for entry in judged {
            #expect(!entry.reason.isEmpty,
                    Comment(rawValue: "an entry with no reason records that somebody looked and not what "
                            + "they concluded, which is the whole value of the log"))
        }
    }
}
