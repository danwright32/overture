import Testing
import Foundation

// #2171. #2116 anchored an unconfirmed AI conversation state to the instant it was guessed, so an
// untriaged suggestion ages and can read as overdue. A second writer defeated it: every classify run
// re-stamped that anchor, so the guess was always freshly made and the card re-filed itself under today,
// which is exactly the defect #2111 and #2116 were about (L74, L55).
//
// Measured on the live store: the Pumpkin Singalong reply arrived 2026-08-04 20:55 Eastern, and its
// wants_to_book guess carried a setAt of 2026-08-05 20:48, one minute before Dan looked at it. The
// screenshot read "Reach out now" on a card whose work had arrived the previous evening.
//
// The existing ReminderDateAgesWithTheWorkTests could not see this: it holds the inputs still and moves
// the clock, which is structurally unable to catch a WRITER that moves the inputs. This is its companion,
// driving the real writer.
@Suite("A repeated guess keeps its original date (#2171)")
struct ARepeatedGuessKeepsItsDateTests {
    private let t0 = Date(timeIntervalSince1970: 1_754_300_000)
    private var aDayLater: Date { t0.addingTimeInterval(86_400) }

    private func contact() -> Recipient {
        let r = Recipient(id: "nbecker@everyvoicechoirs.org", email: "nbecker@everyvoicechoirs.org",
                          provenance: .act)
        r.replied = true
        r.repliedAt = t0
        r.inboundReplySentAt = t0
        return r
    }

    // The fix. The anchor records when this judgement first needed Dan, not when the machine last
    // repeated itself.
    @Test func reSuggestingTheSameStateLeavesTheAnchorAlone() {
        let r = contact()
        r.suggestConversationState(.wantsToBook, now: t0)
        #expect(r.conversationStateSetAt == t0)

        r.suggestConversationState(.wantsToBook, now: aDayLater)

        #expect(r.conversationStateSetAt == t0, "a repeated guess is not new work")
        #expect(r.conversationState == .wantsToBook)
        #expect(r.conversationStateSource == .auto)
    }

    // Repeated many times, as the classifier actually runs. One re-stamp anywhere in the sequence is the
    // whole defect, so this cannot pass by the second call happening to be a no-op.
    @Test func aGuessRepeatedAllDayNeverMovesItsDate() {
        let r = contact()
        r.suggestConversationState(.interested, now: t0)
        for hour in 1...12 {
            r.suggestConversationState(.interested, now: t0.addingTimeInterval(Double(hour) * 3_600))
        }
        #expect(r.conversationStateSetAt == t0)
    }

    // A genuinely NEW judgement still surfaces as new, or the fix would freeze a changed suggestion at the
    // date of the one it replaced.
    @Test func aChangedGuessTakesTheLaterDate() {
        let r = contact()
        r.suggestConversationState(.interested, now: t0)
        r.suggestConversationState(.wantsToBook, now: aDayLater)

        #expect(r.conversationStateSetAt == aDayLater)
        #expect(r.conversationState == .wantsToBook)
    }

    // And a hand-set state is still never overwritten, which is the guard that was already there.
    @Test func aStateDanSetByHandIsStillUntouchable() {
        let r = contact()
        r.conversationState = .hasQuestion
        r.conversationStateSetAt = t0
        r.conversationStateSource = .manual

        r.suggestConversationState(.declined, now: aDayLater)

        #expect(r.conversationState == .hasQuestion)
        #expect(r.conversationStateSetAt == t0)
        #expect(r.conversationStateSource == .manual)
    }

    // The consequence Dan actually sees, through the calculator: a suggestion made a day ago and
    // re-suggested today is still dated a day ago, so it sorts above work that only came due today
    // instead of re-filing itself under this morning.
    @Test func aRepeatedGuessStillReadsAsADayOldWork() {
        let r = contact()
        r.suggestConversationState(.wantsToBook, now: t0)
        r.suggestConversationState(.wantsToBook, now: aDayLater)

        let due = ConversationReminder.nextReminderDate(
            state: r.conversationState, setAt: r.conversationStateSetAt,
            remindedAt: r.conversationRemindedAt, performanceDate: "2026-10-31", isClosed: false,
            hasUnhandledReply: r.hasUnhandledReply, repliedAt: r.replyArrivedAt,
            source: r.conversationStateSource, now: aDayLater)

        #expect(due == t0, "the card must stay dated to when the judgement first needed him")
    }

    // The same run through the importer's own path, so the fix is proven where the re-stamping actually
    // happened rather than only on the model method underneath it.
    @Test func theClassifyImporterCannotRefreshAStandingGuess() {
        let r = contact()
        r.suggestConversationState(.wantsToBook, now: t0)

        // What the importer does to a still-auto row on every run.
        if r.conversationStateSource != .manual {
            r.suggestConversationState(.wantsToBook, now: aDayLater)
        }

        #expect(r.conversationStateSetAt == t0)
    }
}
