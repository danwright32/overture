import Testing
import Foundation
import SwiftData

// #1740: Dan opens Due, sees a nudge for a show he has decided against, and has no way to say so. His
// words: "I'm not going to action this." Today the row offers only Send nudge and View in Archive, so the
// only ways to clear it are to send an email he does not want to send or to leave it counting toward the
// badge until nudge 2 of 2 arrives for the same show he already declined.
//
// What it MEANS is scoped, and Dan scoped it himself (2026-07-30): "This feature is for situations where I
// no longer want to try and work this particular event. No matter what I want to reply to emails and try to
// build a relationship for future events." So it stops THIS EVENT'S PITCH and nothing else. It is not a
// resolution (the lead is not lost), a reply always reopens it, and the post-event closing note survives it
// deliberately, because that note serves the NEXT event.
@Suite("Standing a contact's outreach down (#1740)")
struct StandDownOutreachTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    // A contact and the show it belongs to, because the nudge question is asked about both and the show is
    // not optional: forgetting it is what let a stood-down show still be nudged.
    private func sentContact(followUps: Int = 0, sentDaysAgo: Int = 30) -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music",
                         venue: "The Room", performanceDate: "2026-05-01", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .contacted)
        let r = Recipient(id: "r1", email: "ada@example.org", name: "Ada Fenwick", role: "Manager",
                          provenance: .act)
        r.sentAt = now.addingTimeInterval(-Double(sentDaysAgo) * 86_400)
        r.sendState = .sent
        r.followUpCount = followUps
        return (p, r)
    }

    // The nudge stops for good. Not a snooze: the whole point is that six days from now nothing returns.
    @Test func aStoodDownContactIsNeverDueForANudgeAgain() {
        let (p, r) = sentContact()
        #expect(FollowUp.isAwaitingNudge(r, in: p))   // the precondition the test rests on

        r.standDownOutreach(now: now)

        #expect(!FollowUp.isAwaitingNudge(r, in: p))
        // And still not, a year later, at every gap boundary in between.
        for days in [6, 12, 60, 365] {
            #expect(!FollowUp.isDue(eligible: FollowUp.isAwaitingNudge(r, in: p), sentAt: r.sentAt,
                                    lastFollowUpAt: r.lastFollowUpAt, followUpCount: r.followUpCount,
                                    now: now.addingTimeInterval(Double(days) * 86_400)),
                    "still due after \(days) days")
        }
    }

    // The other half of Dan's answer: he wanted the choice each time, so pushing it out one gap has to be a
    // real option too, and it must NOT read as a nudge having been sent.
    @Test func aSnoozedContactComesBackAfterTheGapWithNoNudgeRecorded() {
        let (p, r) = sentContact()
        r.remindLaterAboutNudge(now: now)

        #expect(!FollowUp.isDue(eligible: FollowUp.isAwaitingNudge(r, in: p), sentAt: r.sentAt,
                                lastFollowUpAt: r.lastFollowUpAt, followUpCount: r.followUpCount,
                                remindedAt: r.nudgeRemindedAt, now: now))
        let afterGap = now.addingTimeInterval(Double(FollowUpConfig().gapDays) * 86_400 + 60)
        #expect(FollowUp.isDue(eligible: FollowUp.isAwaitingNudge(r, in: p), sentAt: r.sentAt,
                               lastFollowUpAt: r.lastFollowUpAt, followUpCount: r.followUpCount,
                               remindedAt: r.nudgeRemindedAt, now: afterGap))
        // The send record is untouched: no nudge went, so nothing may say one did (L37).
        #expect(r.followUpCount == 0)
        #expect(r.lastFollowUpAt == nil)
    }

    // Standing down is not a commercial answer. Dan is declining THIS sequence, not saying the lead is
    // lost, and the issue is explicit that the outcome must not move.
    @Test func standingDownDecidesNothingAboutTheLead() {
        let (p, r) = sentContact()
        r.standDownOutreach(now: now)

        #expect(r.resolution == nil)
        #expect(r.outcomeSource == nil)
        #expect(r.repliedAt == nil)
    }

    // Undo. The row sits one click from Send nudge, so a decision that removes work from a queue and
    // cannot be taken back is a trap.
    @Test func standingDownCanBeTakenBack() {
        let (p, r) = sentContact()
        r.standDownOutreach(now: now)
        r.resumeOutreach()

        #expect(FollowUp.isAwaitingNudge(r, in: p))
        #expect(r.outreachStoodDownAt == nil)
    }

    // A reply is new information, and it reopens the conversation. Without this, a contact Dan stood down
    // in June could write back in July and the app would keep quiet about it, which is the one failure
    // this feature could actually cause: a lost booking rather than an unsent nudge.
    //
    // Derived from the two stamps rather than cleared by whoever records the reply, so no future reply
    // path can forget it (the stand-down is only in force until they write back).
    @Test func aReplyAfterTheStandDownPutsTheContactBackInPlay() {
        let (p, r) = sentContact()
        r.standDownOutreach(now: now)
        #expect(r.isOutreachStoodDown)

        r.replied = true
        r.repliedAt = now.addingTimeInterval(86_400)

        #expect(!r.isOutreachStoodDown)
    }

    // A reply that arrived BEFORE the stand-down is not new information: Dan stood the contact down with
    // that reply already in front of him.
    @Test func aReplyBeforeTheStandDownDoesNotUndoIt() {
        let (p, r) = sentContact()
        r.replied = true
        r.repliedAt = now.addingTimeInterval(-86_400)
        r.standDownOutreach(now: now)

        #expect(r.isOutreachStoodDown)
    }

    // The stored fact has to be readable, or it is a field with a writer and no reader (L46).
    @Test func theStandDownSaysWhenItHappened() {
        let (p, r) = sentContact()
        r.standDownOutreach(now: now)
        #expect(r.outreachStoodDownAt == now)
    }

    // And it has to reach a sentence. A contact with no follow-up activity looks identical to one nobody
    // ever got to, so the card has to say the silence was a decision.
    @Test func theCardSaysHeStoppedSendingAndWhen() {
        let line = StandDownCopy.standDownLine(stoodDownAt: now, now: now.addingTimeInterval(3 * 86_400))
        #expect(line?.contains("stopped sending") == true)
        #expect(line?.contains("days ago") == true)
        // A contact he never stood down gains no line at all.
        #expect(StandDownCopy.standDownLine(stoodDownAt: nil, now: now) == nil)
    }
}

// The list and the badge come from one predicate and must agree, which is #863 restated: a number on a
// pill is a promise about rows.
@MainActor
@Suite("A stood-down contact leaves the Due list and its count (#1740)")
struct StandDownDueListTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func show(_ ctx: ModelContext, contacts: [String]) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Aurora Strings", performanceDate: "2026-05-01",
                                          venue: "The Room")
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                         venue: "The Room", performanceDate: "2026-05-01", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .contacted)
        p.sentAt = now.addingTimeInterval(-30 * 86_400)
        for (i, email) in contacts.enumerated() {
            let r = Recipient(id: "r\(i)", email: email, name: "Contact \(i)", role: "Manager",
                              provenance: .act)
            r.sentAt = p.sentAt
            r.sendState = .sent
            r.gmailMessageId = "msg-r\(i)"
            p.recipients.append(r)
        }
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @Test func theStoodDownContactDropsOffAndTheOthersStay() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, contacts: ["one@example.org", "two@example.org"])
        #expect(FollowUp.dueRecipients(from: [p], now: now).count == 2)

        // By id, never by position: a SwiftData relationship is a set, so `recipients[0]` is whichever
        // contact the store happens to hand back first.
        p.recipients.first { $0.id == "r0" }?.standDownOutreach(now: now)
        try? ctx.save()

        let due = FollowUp.dueRecipients(from: [p], now: now)
        #expect(due.count == 1)
        #expect(due.first?.recipient.id == "r1")
    }

    // The badge and the rows are one promise. A count that still says 1 over an empty list is the exact
    // shape #863 exists to prevent.
    @Test func theDueCountDropsWithTheRow() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, contacts: ["one@example.org"])
        #expect(DueWork.counts(prospects: [p], now: now).followUps == 1)

        p.recipients.first!.standDownOutreach(now: now)
        try? ctx.save()

        #expect(DueWork.counts(prospects: [p], now: now).followUps == 0)
        #expect(FollowUp.dueRecipients(from: [p], now: now).isEmpty)
    }

    // A nudge must not be sendable behind the row's back either: the send path reads the same predicate,
    // so a stood-down contact cannot be nudged by any surface (#1679, a rule and its wiring are two claims).
    // BOTH grains, because the send path takes the show and the contact separately and it would be easy to
    // pass only one: asking about the contact alone silently ignores a whole show Dan walked away from.
    @Test func theSendPathRefusesToNudgeAtEitherGrain() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, contacts: ["one@example.org"])
        p.recipients.first!.standDownOutreach(now: now)
        try? ctx.save()
        #expect(!FollowUp.isAwaitingNudge(p.recipients.first!, in: p))

        p.recipients.first!.resumeOutreach()
        p.standDownOutreach(now: now)
        try? ctx.save()
        #expect(!FollowUp.isAwaitingNudge(p.recipients.first!, in: p))
    }

    // And the sender really asks with the show in hand, not the contact alone. Source-level because the
    // send itself reaches Gmail, and the argument being dropped is invisible to every behavioural test:
    // the call compiles and passes either way (#1679).
    @Test func theSenderAsksWithTheShowInHand() {
        let sender = SourceGuardHelper.source("Overture/Integration/SendService.swift")
        #expect(sender.contains("FollowUp.isAwaitingNudge(recipient, in: prospect)"))
    }

    // Standing a NUDGE down must not blind the decide clock: "stop writing to this one" is not "I have
    // decided what happened to this lead", and the Reached out queue asks the second question.
    @Test func theDecideClockStillHoldsAStoodDownContact() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, contacts: ["one@example.org"])
        p.recipients.first!.standDownOutreach(now: now)
        try? ctx.save()

        #expect(p.recipients.first!.isAwaitingFollowUp)
    }
}

// The closing-note half. Dan, 2026-07-30, asked for something neither existing path offered: "I'm not sure
// it should count as sent and done. It should count as not sent but also done."
@MainActor
@Suite("Standing a closing note down closes it without sending it (#1740)")
struct StandDownClosingNoteTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func showAwaitingAClosingNote(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Aurora Strings", performanceDate: "2026-05-01",
                                          venue: "The Room")
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                         venue: "The Room", performanceDate: "2026-05-01", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .contacted)
        p.sentAt = now.addingTimeInterval(-90 * 86_400)
        let r = Recipient(id: "r0", email: "one@example.org", name: "Contact", role: "Manager",
                          provenance: .act)
        r.sentAt = p.sentAt
        r.sendState = .sent
        // #2397: the prompt demands PROOF a send really happened (#331/#378). Without this the fixture's
        // own precondition was false and the test would have passed for the wrong reason.
        r.gmailMessageId = "msg-r0"
        r.reopenOnReply(at: now.addingTimeInterval(-80 * 86_400))
        p.recipients.append(r)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @Test func theReminderStopsAndNothingClaimsANoteWasSent() throws {
        let ctx = ModelContext(try container())
        let p = showAwaitingAClosingNote(ctx)
        // Only meaningful if this contact really is being reminded about in the first place.
        #expect(!PostEventPrompt.dueRecipients(from: [p], now: now).isEmpty)

        p.recipients.first!.standDownClosingNote(now: now)
        try? ctx.save()

        #expect(PostEventPrompt.dueRecipients(from: [p], now: now).isEmpty)
        // "Not sent": no send was recorded, and no commercial answer was invented on his behalf.
        #expect(p.recipients.first!.followUpCount == 0)
        #expect(p.recipients.first!.lastFollowUpAt == nil)
        #expect(p.recipients.first!.resolution == nil)
        #expect(p.outcomeSourceRaw == nil)
    }

    @Test func undoBringsTheReminderBack() throws {
        let ctx = ModelContext(try container())
        let p = showAwaitingAClosingNote(ctx)
        p.recipients.first!.standDownClosingNote(now: now)
        try? ctx.save()
        #expect(PostEventPrompt.dueRecipients(from: [p], now: now).isEmpty)

        p.recipients.first!.resumeClosingNote()
        try? ctx.save()

        #expect(!PostEventPrompt.dueRecipients(from: [p], now: now).isEmpty)
    }
}

// The scope Dan asked for, and the line the whole feature turns on: standing down an EVENT does not close
// the door on the people. "No matter what I want to reply to emails and try to build a relationship for
// future events."
@MainActor
@Suite("Standing down an event, not the people (#1740)")
struct StandDownScopeTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, contacts: [String], replied: Bool = false) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Aurora Strings", performanceDate: "2026-05-01",
                                          venue: "The Room")
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                         venue: "The Room", performanceDate: "2026-05-01", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .contacted)
        p.sentAt = now.addingTimeInterval(-90 * 86_400)
        for (i, email) in contacts.enumerated() {
            let r = Recipient(id: "r\(i)", email: email, name: "Contact \(i)", role: "Manager",
                              provenance: .act)
            r.sentAt = p.sentAt
            r.sendState = .sent
            // #2397: proof a send really happened, which the post-event prompt demands (#331/#378).
            r.gmailMessageId = "msg-r\(i)"
            if replied { r.reopenOnReply(at: now.addingTimeInterval(-80 * 86_400)) }
            p.recipients.append(r)
        }
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // The show grain clears every contact at once, which is the whole point of having it.
    @Test func standingDownTheShowClearsAllItsContacts() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, contacts: ["one@example.org", "two@example.org"])
        #expect(FollowUp.dueRecipients(from: [p], now: now).count == 2)

        p.standDownOutreach(now: now)
        try? ctx.save()

        #expect(FollowUp.dueRecipients(from: [p], now: now).isEmpty)
    }

    // A fact on the SHOW rather than a stamp copied onto each contact, so a contact added afterwards is
    // covered by a decision made before it existed. Stamping would have missed exactly this.
    @Test func aContactAddedAfterwardsIsCoveredToo() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, contacts: ["one@example.org"])
        p.standDownOutreach(now: now)

        let late = Recipient(id: "late", email: "late@example.org", name: "Added later", role: "Manager",
                             provenance: .manual)
        late.sentAt = p.sentAt
        late.sendState = .sent
        p.recipients.append(late)
        try? ctx.save()

        #expect(FollowUp.dueRecipients(from: [p], now: now).isEmpty)
    }

    // THE line Dan drew. He walked away from the event in July; in September the closing note that keeps
    // the door open for the next one still comes due, because it is not about this event at all.
    @Test func theClosingNoteSurvivesStandingTheShowDown() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, contacts: ["one@example.org"], replied: true)
        p.standDownOutreach(now: now)
        try? ctx.save()

        #expect(!PostEventPrompt.dueRecipients(from: [p], now: now).isEmpty)
    }

    // And the row carries the context, because by then the decision is months old.
    @Test func theClosingNoteRowSaysTheShowWasStoodDown() {
        let line = StandDownCopy.closingNoteOnStoodDownShow(stoodDownAt: now,
                                                            now: now.addingTimeInterval(60 * 86_400))
        #expect(line?.contains("stopped working this show") == true)
        #expect(StandDownCopy.closingNoteOnStoodDownShow(stoodDownAt: nil, now: now) == nil)
    }

    // A reply after the decision puts that contact back in play even at the show grain, per person: one
    // contact writing back does not drag the others back with them.
    @Test func aReplyPutsThatContactBackInPlayOnAStoodDownShow() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, contacts: ["one@example.org", "two@example.org"])
        p.standDownOutreach(now: now)
        #expect(p.isOutreachStoodDown(asOf: nil))

        #expect(!p.isOutreachStoodDown(asOf: now.addingTimeInterval(86_400)))
        #expect(p.isOutreachStoodDown(asOf: now.addingTimeInterval(-86_400)))
    }

    // Undo at the show grain, same as the contact grain.
    @Test func standingDownAShowCanBeTakenBack() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, contacts: ["one@example.org"])
        p.standDownOutreach(now: now)
        try? ctx.save()
        #expect(FollowUp.dueRecipients(from: [p], now: now).isEmpty)

        p.resumeOutreach()
        try? ctx.save()

        #expect(FollowUp.dueRecipients(from: [p], now: now).count == 1)
    }
}
