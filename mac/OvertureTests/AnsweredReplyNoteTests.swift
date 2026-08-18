import Testing
import Foundation
import SwiftData

// #2919. Once `replyHandledAt` clears a reply, the reached-out row went back to looking exactly like a
// pitch nobody ever answered: the group name, the show's date, and "Close this out". Nothing anywhere in
// the app said a conversation had happened, so a live negotiation and total silence rendered identically.
//
// Measured on the live store 2026-08-17: a contact replied twice, Dan answered once from Overture and once
// from his mail client, and the card carried no trace of either. He asked why the reply had not been picked
// up, when it had been picked up, recorded, and cleared by #2865 working exactly as designed. That is L152:
// the operation that RESOLVES everything silences every surface that could have reported it, so the most
// complete success is the one the product says least about.
@MainActor
@Suite("The row says a reply arrived and was answered (#2919)")
struct AnsweredReplyNoteTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                         venue: "Rivermill Hall", performanceDate: "2026-11-20", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ p: Prospect, _ address: String, group: String? = "g") -> Recipient {
        let r = Recipient(id: address, email: address, provenance: .act)
        r.gmailThreadId = "t"
        r.gmailMessageId = "m-\(address)"
        r.sendGroupId = group
        r.sentAt = day("2026-08-01")
        r.sendState = .sent
        p.addRecipient(r)
        return r
    }

    // Both ends of every date pair are pinned, so real time cannot walk a fixture into a different case
    // than the one it was written for (L130); `now` is an argument everywhere below for the same reason.
    private func day(_ s: String) -> Date { EasternDate.date(from: s)! }
    private let now = EasternDate.date(from: "2026-08-18")!

    private let writerAddress = "rowan@aurorastrings.example"

    // What the store holds after detection and an answer: detection records the writer's address, display
    // name and send time on EVERY contact sharing the thread (ReplyService.recordWriter), and
    // `AnsweredReply.recordHandled` stamps the answer across the same set.
    private func answered(_ r: Recipient, wrote: String, answeredOn: String, by writer: String? = nil) {
        r.replied = true
        r.repliedAt = day(wrote)
        r.inboundReplySentAt = day(wrote)
        r.replyFromAddress = writer ?? r.email
        r.replyFromName = "Rowan Ellis"
        r.lastReplyId = "reply-1"
        r.replyHandledAt = day(answeredOn)
    }

    // The defect itself. A conversation that happened and was dealt with now says so, on the row, in words.
    @Test func anAnsweredReplyGetsItsOwnLine() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, writerAddress)
        answered(r, wrote: "2026-08-14", answeredOn: "2026-08-15")

        #expect(AnsweredReplyNote.line(for: r, in: p, now: now) == "Replied Aug 14, you answered Aug 15")
    }

    // Answering the same day is the common case, and "you answered Aug 14" beside "Replied Aug 14" reads
    // as a rendering fault rather than as a fact. The same two facts, said the way a person says them.
    @Test func answeringOnTheSameDaySaysSoRatherThanPrintingTheDateTwice() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, writerAddress)
        answered(r, wrote: "2026-08-14", answeredOn: "2026-08-14")

        #expect(AnsweredReplyNote.line(for: r, in: p, now: now) == "Replied Aug 14, you answered that day")
    }

    // A pitch nobody ever answered draws nothing. The resting row is unchanged, which is the whole point of
    // giving the answered state a line of its own rather than restyling the row.
    @Test func aPitchNobodyRepliedToDrawsNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, writerAddress)

        #expect(AnsweredReplyNote.line(for: r, in: p, now: now) == nil)
    }

    // Somebody is still waiting on him. The Answer control and the highlighted writer already report that,
    // loudly, and a line beside them restating it is the #843 defect this repo keeps finding.
    @Test func aReplyStillWaitingOnHimDrawsNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, writerAddress)
        answered(r, wrote: "2026-08-14", answeredOn: "2026-08-15")
        r.replyHandledAt = nil

        #expect(r.hasUnhandledReply)
        #expect(AnsweredReplyNote.line(for: r, in: p, now: now) == nil)
    }

    // They wrote AGAIN after he answered. The conversation is open once more, so the line comes down and
    // the row goes back to asking. Answered and waiting are two states, never one.
    @Test func aSecondReplyAfterTheAnswerTakesTheLineBackDown() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, writerAddress)
        answered(r, wrote: "2026-08-16", answeredOn: "2026-08-15")

        #expect(r.hasUnhandledReply)
        #expect(AnsweredReplyNote.line(for: r, in: p, now: now) == nil)
    }

    // Closed out on the contact. The line reports an OPEN conversation, and a claim may only be as wide as
    // its check (L11), so a contact carrying an ending says nothing here.
    @Test func aContactWithAnEndingRecordedOnItDrawsNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, writerAddress)
        answered(r, wrote: "2026-08-14", answeredOn: "2026-08-15")
        r.resolution = .stoodDown

        #expect(AnsweredReplyNote.line(for: r, in: p, now: now) == nil)
    }

    // And a bounce is not a conversation. Same reasoning: `hasUnhandledReply` goes false for four separate
    // reasons and only one of them means "he dealt with it".
    @Test func aBouncedContactDrawsNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, writerAddress)
        answered(r, wrote: "2026-08-14", answeredOn: "2026-08-15")
        r.bounced = true

        #expect(AnsweredReplyNote.line(for: r, in: p, now: now) == nil)
    }

    // #2113's lesson, applied here rather than relearned: the row stands on whoever the queue picked, which
    // is not guaranteed to be the person who wrote. A line asked only of the contact the list happens to
    // hold would be silent on exactly the joint conversation it exists for.
    @Test func theLineIsFoundOnThePeerWhoWroteWhenTheRowStandsOnSomebodyElse() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let colleague = contact(p, "admin@aurorastrings.example")
        let writer = contact(p, writerAddress)
        answered(writer, wrote: "2026-08-14", answeredOn: "2026-08-15")

        #expect(!colleague.replied)
        #expect(AnsweredReplyNote.line(for: colleague, in: p, now: now)
                    == "Replied Aug 14, you answered Aug 15")
    }

    // A conversation on a DIFFERENT send group is a different conversation, so it does not leak onto this
    // row. The peer walk is `SendGroup.peers`, which is the same grouping `AnsweredReply.recordHandled`
    // fans the answer out over, so the line can only ever report an exchange this row is actually about.
    @Test func anAnsweredExchangeOnAnotherSendGroupDoesNotLeakOntoThisRow() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let mine = contact(p, "boxoffice@aurorastrings.example", group: "g1")
        let stranger = contact(p, writerAddress, group: "g2")
        answered(stranger, wrote: "2026-08-14", answeredOn: "2026-08-15")

        #expect(AnsweredReplyNote.line(for: mine, in: p, now: now) == nil)
        #expect(AnsweredReplyNote.line(for: stranger, in: p, now: now) != nil)
    }

    // A pitch never ages off until Dan closes it, so a row can sit here past new year. "Nov 2" for a date
    // eleven months back reads as this coming November, which is #2007's finding in `dayLabelWithYear`.
    // BOTH dates carry the year once either needs it: one bare and one dated in the same sentence is worse
    // than either rule applied consistently.
    @Test func anExchangeFromAnotherYearCarriesItsYear() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, writerAddress)
        answered(r, wrote: "2025-11-02", answeredOn: "2025-11-03")

        #expect(AnsweredReplyNote.line(for: r, in: p, now: now)
                    == "Replied Nov 2, 2025, you answered Nov 3, 2025")
    }

    // Durable, in the issue's own word: derived from two stored stamps and never from the clock, so it says
    // the same thing on the day he answers and four months later. The rule that a sent pitch never ages off
    // until Dan closes it applies to what the row SAYS as much as to whether the row is there.
    @Test func theLineDoesNotAgeOffOnAClock() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, writerAddress)
        answered(r, wrote: "2026-08-14", answeredOn: "2026-08-15")

        let muchLater = EasternDate.date(from: "2026-12-20")!
        #expect(AnsweredReplyNote.line(for: r, in: p, now: muchLater)
                    == "Replied Aug 14, you answered Aug 15")
    }

    // Decision 2, and the evidence for it rather than an assertion of it. The row ALREADY marks who wrote,
    // and that marking survives the answer: the writer's address is drawn among the audience and its spoken
    // label says so. Naming them again in this line would tell Dan nothing the line beside it did not
    // (#843), so the line names nobody, and this pins the fact the decision rests on.
    @Test func theRowStillMarksWhoWroteAfterTheAnswerSoTheLineNamesNobody() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let colleague = contact(p, "admin@aurorastrings.example")
        let writer = contact(p, writerAddress)
        for r in [colleague, writer] {
            answered(r, wrote: "2026-08-14", answeredOn: "2026-08-15", by: writerAddress)
        }

        let audience = ReplyIdentity.rowAudience(for: writer, in: p)
        #expect(audience.lines.contains(writerAddress))
        #expect(audience.responder == writerAddress)
        #expect(audience.spokenLabel(for: writerAddress) == "\(writerAddress), replied")

        let line = try #require(AnsweredReplyNote.line(for: writer, in: p, now: now))
        #expect(!line.contains("Rowan"))
        #expect(!line.contains(writerAddress))
    }

    // Decision 3: the line does not say WHERE he answered from, because Overture cannot tell. Four of the
    // paths that clear a reply leave no `sentReplyBody` (a peer on a joint reply, an OmniFocus tick, an
    // attach, and an answer sent from his mail client), so its absence names no single cause and a line
    // claiming one would be a claim its check never measured (L11).
    @Test func answeringFromTheMailClientAndAnsweringInOvertureReadTheSame() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let inOverture = contact(p, writerAddress)
        answered(inOverture, wrote: "2026-08-14", answeredOn: "2026-08-15")
        inOverture.sentReplyBody = "Thursday works, I will bring the long lens."
        inOverture.replySentAt = day("2026-08-15")

        let other = show(ctx, key: "k2")
        let elsewhere = contact(other, writerAddress)
        answered(elsewhere, wrote: "2026-08-14", answeredOn: "2026-08-15")

        #expect(elsewhere.sentReplyBody == nil)
        #expect(AnsweredReplyNote.line(for: inOverture, in: p, now: now)
                    == AnsweredReplyNote.line(for: elsewhere, in: other, now: now))
    }

    // The predicate is written OVER `hasUnhandledReply` rather than beside it (#2921's rule), so the two
    // can never disagree about whether this conversation has been dealt with.
    @Test func theAnsweredStateAndTheUnhandledStateAreNeverBothTrue() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, writerAddress)
        for handled in ["2026-08-13", "2026-08-14", "2026-08-15"] {
            answered(r, wrote: "2026-08-14", answeredOn: handled)
            #expect(!(r.replyIsAnswered && r.hasUnhandledReply))
        }
    }

    // The fourth state the row can be in: the SHOW was closed out. It leaves this stage entirely, so the
    // question of what the line says there does not arise, and this pins that rather than assuming it.
    @Test func aClosedOutShowLeavesTheStageSoTheLineIsNotOnScreenAtAll() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, writerAddress)
        answered(r, wrote: "2026-08-14", answeredOn: "2026-08-15")

        #expect(ReachedOutQueue.isInPlay(r, of: p))
        p.showOutcome = .neverHeardBack
        #expect(!ReachedOutQueue.isInPlay(r, of: p))
    }
}
