import Testing
import Foundation
import SwiftData

// #2130: the reached-out row's action control must say what it does.
//
// Dan pressed "Send a follow-up" on 2026-08-05 and got a list that could send nothing. The control could
// not simply be wired to a send either, because "due now" on that row is `min` of three clocks and means
// any of six different things, two of which are not sendable at all. His rule: "buttons need to do what
// they say."
//
// So the row asks what is actually due and labels itself accordingly, the way the Due sheet already does.
@MainActor
@Suite("What the reached-out row's control is for")
struct ReachedOutActionTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
    private var today: String { EasternDate.today(now) }

    private func show(_ ctx: ModelContext, event: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: event, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ p: Prospect, sentAt: Date) -> Recipient {
        let r = Recipient(id: "c@x.org", email: "c@x.org", provenance: .act)
        r.sentAt = sentAt
        r.sendState = .sent
        r.gmailMessageId = "m"
        p.setRecipients(p.recipients + [r])
        return r
    }

    // A contact who has gone quiet long enough: the next email really is a nudge, and it sends.
    @Test func aSilentContactLongEnoughEarnsANudge() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, sentAt: daysAgo(30))
        #expect(ReachedOutAction.of(r, in: p, now: now, today: today) == .sendNudge)
    }

    // Nothing is due yet, so the slot offers nothing rather than a button that would refuse.
    @Test func aContactPitchedYesterdayEarnsNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, sentAt: daysAgo(1))
        #expect(ReachedOutAction.of(r, in: p, now: now, today: today) == .none)
    }

    // The show has passed and NOBODY wrote back, so the sendable thing is the closing note rather than a
    // nudge about a date gone by.
    @Test func aPassedShowNobodyAnsweredEarnsAClosingNote() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, event: EasternDate.dayString(from: daysAgo(10)))
        _ = contact(p, sentAt: daysAgo(30))
        let only = try #require(p.recipients.first)
        #expect(ReachedOutAction.of(only, in: p, now: now, today: today) == .sendClosingNote)
    }

    // #2397: the show has passed and somebody DID write back. The closing note would assert nobody
    // answered, which is false, so the row asks Dan to say how it ended instead. No email at all.
    @Test func aPassedShowTheyRepliedToEarnsSayingHowItEnded() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, event: EasternDate.dayString(from: daysAgo(10)))
        let r = contact(p, sentAt: daysAgo(30))
        r.reopenOnReply(at: daysAgo(20))
        #expect(ReachedOutAction.of(r, in: p, now: now, today: today) == .sayHowItEnded)
    }

    // A form pitch cannot be emailed or detected, so the only thing that moves it is Dan saying what
    // happened. Never a send button, which would promise something Overture cannot do.
    @Test func aFormPitchEarnsSayingWhatHappened() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, sentAt: daysAgo(30))
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = daysAgo(30)
        #expect(ReachedOutAction.of(r, in: p, now: now, today: today) == .sayWhatHappened)
    }

    // Somebody wrote back and is waiting on a reply, on a show still AHEAD. This slot offers nothing:
    // answering has its own control. Above all it must never be a nudge, because a generic prod is exactly
    // the wrong email to send somebody who has already written.
    @Test func aContactWhoWroteBackIsNeverOfferedANudge() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, sentAt: daysAgo(30))
        r.replied = true
        r.repliedAt = daysAgo(2)
        let action = ReachedOutAction.of(r, in: p, now: now, today: today)
        #expect(action == .none)
        #expect(action != .sendNudge)
    }

    // MARK: every action names itself, and only the sendable ones claim to send

    @Test func everyActionHasItsOwnLabel() {
        #expect(ReachedOutAction.sendNudge.label == "Send a follow-up")
        #expect(ReachedOutAction.sendClosingNote.label == "Send a closing note")
        // #2397: no button of its own. The close-out menu beside this slot is how Dan records an ending,
        // and a second control with the same purpose is the duplicate-copy trap (#843).
        #expect(ReachedOutAction.sayHowItEnded.label == nil)
        // No button of its own: the row's timing text already says this and the state control is how he
        // says it, so a second control with the same words would be a duplicate (#843).
        #expect(ReachedOutAction.sayWhatHappened.label == nil)
        #expect(ReachedOutAction.none.label == nil)
    }

    // The distinction the whole issue turns on: a control that says Send must actually send an email, and
    // one that does not must not be worded as though it will.
    @Test func onlyTheEmailActionsClaimToSend() {
        #expect(ReachedOutAction.sendNudge.sendsAnEmail)
        #expect(ReachedOutAction.sendClosingNote.sendsAnEmail)
        #expect(!ReachedOutAction.sayHowItEnded.sendsAnEmail)
        #expect(!ReachedOutAction.sayWhatHappened.sendsAnEmail)
        #expect(!ReachedOutAction.none.sendsAnEmail)
        // Anything whose label begins with Send must be one that genuinely sends, so the wording and the
        // behaviour cannot drift apart in a later edit.
        for action in ReachedOutAction.allCases where action.label?.hasPrefix("Send") == true {
            #expect(action.sendsAnEmail, "\(action) is worded as a send but does not send")
        }
    }
}
