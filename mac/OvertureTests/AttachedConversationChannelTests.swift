import Testing
import Foundation
import SwiftData

// #2716: `Recipient.outreachChannel` is the switch behind four behaviours, and until now its two values
// answered every question about a pitch on their own: `.email` meant Overture sent it and can watch it,
// `.contactForm` meant Overture can do neither. Milestone #58 breaks that pairing, because a form or DM
// pitch can now carry an attached Gmail conversation (#2715), and at that point BOTH values are wrong for
// somebody.
//
// The decision made here, once, with every reader re-decided against it:
//
//   - `outreachChannel` records HOW THE PITCH WENT OUT. It is history, it is stamped at send, and it never
//     flips (L37). A pitch that left through a contact form did not become an email because a reply to it
//     arrived by one.
//   - What Overture can WATCH is a separate question with its own predicate,
//     `Recipient.hasWatchableConversation`, and the four rules that used to ask the channel now ask
//     whichever of the two questions they actually mean.
//
// These tests pin both halves: today's behaviour is unchanged for a pitch with no conversation attached
// (which is every form pitch on the live store), and the four rules move together the moment one is.
//
// Every date is pinned at BOTH ends: the fixture's own dates and the clock read against them (L130). No
// test here reads the real clock.
@MainActor
@Suite("Attached conversation channel")
struct AttachedConversationChannelTests {
    private let today = "2026-08-15"
    // Midday Eastern on the day the reply landed.
    private var now: Date { EasternDate.date(from: "2026-08-15")!.addingTimeInterval(12 * 3_600) }
    private let showNight = "2026-08-20"
    private var pitchedAt: Date { EasternDate.date(from: "2026-08-01")! }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // The live shape this milestone is about: a show reachable only through the act's own contact form,
    // pitched by hand, recorded by Dan. No address, no thread, no message id.
    private func formPitched(_ ctx: ModelContext, day: String? = "2026-08-20",
                             formURL: String = "https://corinhale.example/contact") -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "54 Sings|\(day ?? "none")", groupName: "54 Sings Shuffle Along",
                         discipline: "theater", venue: "The Green Room 42", performanceDate: day,
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .drafted)
        p.draftSubject = "Photographing 54 Sings Shuffle Along."
        ctx.insert(p)
        let r = Recipient(id: Recipient.makeId(email: nil, formURL: formURL)!, email: nil,
                          name: "Corin Hale", provenance: .act,
                          contactMethodRaw: ContactMethod.formOrDM.rawValue, contactFormURL: formURL)
        p.setRecipients([r])
        p.recordFormOutreach(r, now: pitchedAt, formURL: formURL)
        return (p, r)
    }

    // What #2715 will write: the conversation Dan confirmed, the address they wrote from, and (once
    // detection has run over it) the reply itself.
    private func attach(_ r: Recipient, threadId: String = "thread-abc",
                        repliedAt: Date? = nil, from: String? = nil) {
        r.gmailThreadId = threadId
        if let from { r.email = from; r.replyFromAddress = from }
        if let repliedAt {
            r.replied = true
            r.repliedAt = repliedAt
            r.inboundReplyMessageId = "<their-message>"
        }
    }

    // MARK: the predicate itself

    // The one question every rule below asks, and it is about the CONVERSATION, never about the channel.
    // An empty string is not a conversation: SwiftData will hand back whatever was stored, and a blank
    // thread id would otherwise read as watchable and be fetched (the same `!t.isEmpty` guard every Gmail
    // reader already applies).
    @Test func aWatchableConversationIsAThreadIdAndNothingElse() throws {
        let ctx = ModelContext(try container())
        let (_, r) = formPitched(ctx)

        #expect(!r.hasWatchableConversation)
        r.gmailThreadId = ""
        #expect(!r.hasWatchableConversation)
        r.gmailThreadId = "thread-abc"
        #expect(r.hasWatchableConversation)
    }

    // The pairing this issue breaks, stated as an assertion so it cannot be quietly re-merged: a pitch can
    // be a form pitch AND carry a conversation at the same time.
    @Test func anUnwatchedFormPitchIsTheChannelAndTheSilenceTogether() throws {
        let ctx = ModelContext(try container())
        let (_, r) = formPitched(ctx)

        #expect(r.isUnwatchedFormPitch)
        attach(r)
        #expect(r.outreachChannel == .contactForm)   // history, unchanged by the attach
        #expect(!r.isUnwatchedFormPitch)
    }

    // MARK: the timing slot

    // Unchanged, and asserted first: with no conversation attached, a dated form pitch's slot names the
    // night (#2169), which is every form pitch on the live store today.
    @Test func aFormPitchWithNoConversationStillNamesTheNight() throws {
        let ctx = ModelContext(try container())
        let (p, r) = formPitched(ctx)

        #expect(ReachedOutQueue.timingLabel(for: r, of: p, now: now, today: today) == "in 5 days")
    }

    // The concrete defect in #2716. A reply lands on Aug 15 for a show on Aug 20. `isDueNow` consults
    // `nextActionableMoment`, which includes the unhandled reply, so the row paints rust with a filled
    // Answer button; the slot short-circuited to the night before consulting the same clock and read "in
    // 5 days" beside it. Two adjacent statements about one row, disagreeing (L16).
    @Test func anAttachedReplyIsDueNowAndTheSlotSaysSo() throws {
        let ctx = ModelContext(try container())
        let (p, r) = formPitched(ctx)
        attach(r, repliedAt: now.addingTimeInterval(-3_600), from: "corin.hale@gmail.example")

        #expect(ReachedOutQueue.isDueNow(for: r, of: p, now: now))
        // #2710: the slot reads as due, and now says WHAT is due rather than "Reach out now". This row
        // has no send on it at all (a form pitch carries no address), so the old wording was an
        // instruction it could not carry out. The show has not passed, so it is asked what happened
        // rather than how it ended.
        #expect(ReachedOutQueue.timingLabel(for: r, of: p, now: now, today: today) == ReachedOutQueue.decisionLabel)
    }

    // And after the show, the same row must not read "3 days ago" beside an unanswered reply. #2710: it
    // is past the show now, so the words are the ending ones.
    @Test func anAttachedReplyAfterTheShowStillReadsAsDue() throws {
        let ctx = ModelContext(try container())
        let (p, r) = formPitched(ctx, day: "2026-08-12")
        attach(r, repliedAt: EasternDate.date(from: "2026-08-13")!, from: "corin.hale@gmail.example")

        #expect(ReachedOutQueue.timingLabel(for: r, of: p, now: now, today: today) == ReachedOutQueue.endingLabel)
    }

    // The decide clock is what asks "say what happened", and it asks because Overture cannot see a reply.
    // Once it can, the question is answered by the conversation, so the clock yields.
    //
    // What is left is the ordinary post-event prompt, dated the day AFTER the show, which is a real thing
    // still owed on the row and the reason this asserts a moved moment rather than nil: an attached pitch
    // that nobody answers still needs Dan to record how it ended.
    @Test func theDecideClockYieldsToAnAttachedConversation() throws {
        let ctx = ModelContext(try container())
        let (p, r) = formPitched(ctx)

        // Before: the decide clock is the show's own night, and it wins the fold.
        #expect(ReachedOutQueue.nextActionableMoment(for: r, of: p, now: now)
                == EasternDate.date(from: showNight))
        attach(r)
        #expect(ReachedOutQueue.nextActionableMoment(for: r, of: p, now: now)
                == EasternDate.date(from: "2026-08-21"))
        // And the slot counts down to it instead of naming the night, which is the short-circuit #2716
        // removes. "in 6 days" rather than 5: the prompt is at Eastern midnight, and it is midday now.
        #expect(ReachedOutQueue.timingLabel(for: r, of: p, now: now, today: today) == "in 6 days")
        // The row is still on the stage either way, held by the floor at the show's own date (L45).
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) == EasternDate.date(from: showNight))
    }

    // The one case the floor cannot hold: a show with no date. The pitched-plus-gap clock survives there
    // attached or not, because nil-ing it would drop the row out of the only surface that tracks the pitch
    // (L45), which is the worse of the two defects.
    @Test func anUndatedShowKeepsItsDecideClockEvenWithAConversationAttached() throws {
        let ctx = ModelContext(try container())
        let (p, r) = formPitched(ctx, day: nil)
        attach(r)

        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) != nil)
    }

    // MARK: the row's action

    // Unchanged: an unwatched form pitch that has come due asks Dan to say where it stands.
    @Test func anUnwatchedFormPitchStillAsksWhatHappened() throws {
        let ctx = ModelContext(try container())
        let (p, r) = formPitched(ctx, day: "2026-08-12")

        #expect(ReachedOutAction.of(r, in: p, now: now, today: today) == .sayWhatHappened)
    }

    // `ReachedOutAction.of` returned `.sayWhatHappened` or `.none` FOREVER for a form pitch, its own
    // comment ("a form pitch has no thread and no send") false the moment one is attached, so no post-event
    // prompt could ever be offered on a contact holding a live conversation (L55).
    @Test func anAttachedConversationReachesThePostEventTrack() throws {
        let ctx = ModelContext(try container())
        let (p, r) = formPitched(ctx, day: "2026-08-12")
        attach(r, repliedAt: EasternDate.date(from: "2026-08-11")!, from: "corin.hale@gmail.example")

        #expect(ReachedOutAction.of(r, in: p, now: now, today: today) == .sayHowItEnded)
    }

    // #2710: this used to be the sharp end of reaching that track. The closing note threaded off
    // `gmailMessageId`, which an attached conversation never has by design, so #2716 gave this one row a
    // carve-out to stop it being offered a button that could only refuse (L109).
    //
    // With no closing note at all, the carve-out is gone and this row is no longer special: EVERY passed
    // show now asks Dan how it ended. Kept as a test because the row reaching that answer for the right
    // reason still matters, and because a future send arriving here would put the refusing button back.
    @Test func anAttachedConversationIsAskedHowItEndedLikeEveryOtherPassedShow() throws {
        let ctx = ModelContext(try container())
        let (p, r) = formPitched(ctx, day: "2026-08-12")
        attach(r)   // attached, nobody has written back, the show has passed

        let action = ReachedOutAction.of(r, in: p, now: now, today: today)
        #expect(action == .sayHowItEnded)
        #expect(!action.sendsAnEmail)
    }

    // The other direction, and the reason the channel does not flip to `.email`. `isAwaitingFollowUp`
    // anchors the nudge on `sentAt`, which for a form pitch is when Dan recorded it and is typically weeks
    // old, so a flip would make the nudge INSTANTLY overdue, count it in the Due pill, and send a real cold
    // nudge onto a stranger's conversation.
    @Test func anAttachedConversationNeverBecomesNudgeable() throws {
        let ctx = ModelContext(try container())
        let (_, r) = formPitched(ctx)
        attach(r, from: "corin.hale@gmail.example")

        #expect(r.email != nil)          // it now has an address...
        #expect(!r.isAwaitingFollowUp)   // ...and is still not somebody Overture may nudge
    }

    // MARK: what the row says

    // Two adjacent lines, each correct alone, contradicting each other on the surface Dan triages from
    // (L118, #843): the address on one line, "Overture cannot see a reply to this one" on the next.
    @Test func theCardStopsSayingItCannotSeeAReplyOnceItCan() {
        let form = "https://corinhale.example/contact"
        #expect(FormOutreachCopy.channelLine(formURL: form, hasWatchableConversation: false)
                == FormOutreachCopy.sentLine)
        #expect(FormOutreachCopy.channelLine(formURL: form, hasWatchableConversation: true)
                == FormOutreachCopy.watchedLine)
        // A DM says the same thing about the route it actually went out on.
        let dm = "https://instagram.com/corinhale"
        #expect(FormOutreachCopy.channelLine(formURL: dm, hasWatchableConversation: false)
                == FormOutreachCopy.sentLineSocial)
        #expect(FormOutreachCopy.channelLine(formURL: dm, hasWatchableConversation: true)
                == FormOutreachCopy.watchedLineSocial)
    }

    // `rowAudience`'s contract is "everyone the row's NEXT email reaches". For a form pitch that has not
    // been answered there is no next email at all, so listing the address learned from the attach names an
    // audience for a send that does not exist (L64). The route stays on the row: it is what Dan recognises,
    // and it is where the pitch actually went.
    @Test func anAttachedButUnansweredRowNamesTheRouteNotAnAudience() throws {
        let ctx = ModelContext(try container())
        let (p, r) = formPitched(ctx)
        attach(r, from: "corin.hale@gmail.example")

        #expect(ReplyIdentity.rowAudience(for: r, in: p).lines == ["corinhale.example"])
    }

    // Once they HAVE written back there is a real send, and it goes to the address they wrote from, so the
    // row names it. Anything else would promise a route the answer will not take.
    @Test func anansweredRowNamesWhoTheReplyGoesBackTo() throws {
        let ctx = ModelContext(try container())
        let (p, r) = formPitched(ctx)
        attach(r, repliedAt: now.addingTimeInterval(-3_600), from: "corin.hale@gmail.example")

        let audience = ReplyIdentity.rowAudience(for: r, in: p)
        #expect(audience.lines == ["corin.hale@gmail.example"])
        #expect(audience.responder == "corin.hale@gmail.example")
    }
}
