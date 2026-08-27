import Testing
import Foundation
import SwiftData

// #1840: standing a show down records a closed state of its own.
//
// Dan's reason for wanting it recorded at all: "so it stops asking you to resolve it and the reporting
// counts it as a loss." Nothing that ASKS him to resolve a show reads the show's own outcome, though. Both
// askers (the Reached out decide clock and the conversation reminders) read each CONTACT's resolution, so
// closing the show means closing its contacts.
//
// And that is where the vocabulary ran out. `booked`, `declinedSoft` and `declinedHard` all attribute the
// outcome to the CONTACT, and here nobody declined anything: Dan decided not to pitch. Reusing a decline
// would make every show he walked away from permanently indistinguishable from one where someone said no,
// inside the very reporting meant to tell him which pitches work. His call (2026-07-30): a state that says
// what actually happened.
@Suite("Stood down is its own closed state (#1840)")
struct StoodDownIsItsOwnStateTests {

    // The raw string crosses into the store, so it is pinned rather than left to the enum's spelling.
    @Test func theVocabularyHasItsOwnSpelling() {
        #expect(RecipientResolution(rawValue: "stood_down") == .stoodDown)
        #expect(RecipientResolution.stoodDown.rawValue == "stood_down")
    }

    // The whole point of the new case. A show Dan walked away from and a show someone turned down must
    // stay tellable apart forever, which is exactly what reusing a decline would have destroyed.
    @Test func itIsNotADecline() {
        #expect(RecipientResolution.stoodDown != .declinedSoft)
        #expect(RecipientResolution.stoodDown != .declinedHard)
    }

    // It closes the contact, which is what makes the asking stop.
    @Test func aStoodDownContactIsNoLongerInPlay() {
        let standing = RecipientStanding(sendState: .sent, resolution: .stoodDown, bounced: false,
                                         hasContactPath: true)
        #expect(!standing.isInPlay)
        #expect(standing.wasContacted)
    }

    // The show reads as its own thing too, so a card never says "Closed (not now)" over a show Dan simply
    // stopped working. Two states that mean different things must not collapse into one sentence (#843).
    @Test func theShowReadsAsStoppedRatherThanDeclined() {
        let stoodDown = PerformanceStatus.derive(
            [RecipientStanding(sendState: .sent, resolution: .stoodDown, bounced: false, hasContactPath: true)],
            leadBooked: false)
        let declined = PerformanceStatus.derive(
            [RecipientStanding(sendState: .sent, resolution: .declinedSoft, bounced: false, hasContactPath: true)],
            leadBooked: false)
        #expect(stoodDown == .stoodDown)
        #expect(declined == .lostDoorOpen)
        #expect(PerformanceStatus.stoodDown.label != PerformanceStatus.lostDoorOpen.label)
    }

    // A booking anywhere on the show still wins, because it is the one outcome that outranks everything.
    @Test func aBookingStillOutranksIt() {
        let status = PerformanceStatus.derive(
            [RecipientStanding(sendState: .sent, resolution: .stoodDown, bounced: false, hasContactPath: true),
             RecipientStanding(sendState: .sent, resolution: .booked, bounced: false, hasContactPath: true)],
            leadBooked: false)
        #expect(status == .booked)
    }

    // A contact still in play keeps the show active: standing ONE contact down is not walking away from
    // the show, and #424's rule (pursue whoever is left) is untouched.
    @Test func aContactStillInPlayKeepsTheShowActive() {
        let status = PerformanceStatus.derive(
            [RecipientStanding(sendState: .sent, resolution: .stoodDown, bounced: false, hasContactPath: true),
             RecipientStanding(sendState: .sent, resolution: nil, bounced: false, hasContactPath: true)],
            leadBooked: false)
        #expect(status == .active)
    }
}

@MainActor
@Suite("Standing down closes the contact and keeps the closing note (#1840)")
struct StoodDownClosesTheContactTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, contacts: Int = 1, replied: Bool = false) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Aurora Strings", performanceDate: "2026-05-01",
                                          venue: "The Room")
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                         venue: "The Room", performanceDate: "2026-05-01", sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .contacted)
        p.sentAt = now.addingTimeInterval(-90 * 86_400)
        for i in 0..<contacts {
            let r = Recipient(id: "r\(i)", email: "c\(i)@example.org", name: "Contact \(i)",
                              role: "Manager", provenance: .act)
            r.sentAt = p.sentAt
            r.sendState = .sent
            // The decide clock demands PROOF a send really happened (#331/#378): a sent timestamp alone is
            // a staged record. Without this the fixture's own precondition was false and the test would
            // have passed for the wrong reason.
            r.gmailMessageId = "msg-\(i)"
            if replied { r.reopenOnReply(at: now.addingTimeInterval(-80 * 86_400)) }
            p.recipients.append(r)
        }
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // Dan's stated reason for recording anything: it has to stop asking him to resolve it.
    @Test func theDecideClockGoesQuiet() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = p.recipients.first!
        #expect(ReachedOutQueue.nextReachOut(for: p.recipients.first!, of: p, now: now) != nil)   // it really is asking today

        ProspectMutations.standDown(prospect: p, recipient: r, scope: .contact, now: now)
        try? ctx.save()

        #expect(r.resolution == .stoodDown)
        #expect(ReachedOutQueue.nextReachOut(for: p.recipients.first!, of: p, now: now) == nil)
    }

    // #2397 changed what silences the post-event prompt, and this is the case that shows why. The old rule
    // was keyed on a CONTACT's resolution: standing one down kept the note coming, a decline on one made it
    // go quiet. Both of those are facts about a person, and neither says the SHOW has ended.
    //
    // What silences it now is the show carrying a recorded ending, which is Dan's own rule read the other
    // way round: nothing is closed unless he closed it, so until he does, Overture keeps asking. A contact
    // declining is exactly when it should ask, because somebody answered and only Dan can say what that
    // meant for the event.
    @Test func onlyAnEndingOnTheShowSilencesThePrompt() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, replied: true)
        let r = p.recipients.first!

        ProspectMutations.standDown(prospect: p, recipient: r, scope: .contact, now: now)
        try? ctx.save()
        #expect(!PostEventPrompt.dueRecipients(from: [p], now: now).isEmpty)

        // One contact declining does NOT close the show, so the prompt stays: it is asking Dan what the
        // event ended as, which is the thing that decline did not answer.
        r.resolution = .declinedSoft
        try? ctx.save()
        #expect(!PostEventPrompt.dueRecipients(from: [p], now: now).isEmpty)

        p.showOutcome = .theySaidNo
        try? ctx.save()
        #expect(PostEventPrompt.dueRecipients(from: [p], now: now).isEmpty)
    }

    // Standing the SHOW down closes every contact on it, which is what "I am not working this event" means.
    @Test func theShowGrainClosesEveryContact() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, contacts: 2)

        ProspectMutations.standDown(prospect: p, recipient: p.recipients.first!, scope: .show, now: now)
        try? ctx.save()

        #expect(p.recipients.allSatisfy { $0.resolution == .stoodDown })
    }

    // A reply is new information and it takes the recorded state with it: a contact who wrote back is not
    // a closed lead, and leaving the state behind would report one against a live conversation.
    @Test func aReplyClearsTheRecordedState() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = p.recipients.first!
        ProspectMutations.standDown(prospect: p, recipient: r, scope: .contact, now: now)
        try? ctx.save()

        r.reopenOnReply(at: now.addingTimeInterval(86_400))
        try? ctx.save()

        #expect(r.resolution == nil)
        #expect(!r.isOutreachStoodDown)
    }

    // A reply must not clear a state Dan set for a different reason. Only the stand-down is his "I walked
    // away", and a booking or a real decline is a fact about the world that a later email does not undo.
    @Test func aReplyLeavesEveryOtherClosedStateAlone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = p.recipients.first!
        r.resolution = .declinedHard

        r.reopenOnReply(at: now.addingTimeInterval(86_400))

        #expect(r.resolution == .declinedHard)
    }

    // Undo takes the recorded state back with the stand-down, or the show stays closed on a decision Dan
    // just reversed.
    @Test func undoClearsTheRecordedStateToo() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, contacts: 2)
        ProspectMutations.standDown(prospect: p, recipient: p.recipients.first!, scope: .show, now: now)
        try? ctx.save()

        ProspectMutations.resumeStandDown(prospect: p, recipient: p.recipients.first!, scope: .show)
        try? ctx.save()

        #expect(p.recipients.allSatisfy { $0.resolution == nil })
        #expect(!p.isOutreachStoodDown(asOf: nil))
        #expect(ReachedOutQueue.nextReachOut(for: p.recipients.first!, of: p, now: now) != nil)
    }
}

// A rule and its wiring are two claims (#1679). The reopen can be perfectly correct and never run, which
// is exactly the state this was in when it was written: the live reply path set the two fields by hand and
// knew nothing about the recorded state, so a contact who wrote back would have stayed closed forever.
@Suite("The live reply path really reopens (#1840)")
struct ReplyReopenWiringTests {
    @Test func theReplyDetectorGoesThroughTheReopen() {
        let service = SourceGuardHelper.source("Overture/Integration/ReplyService.swift")
        #expect(service.contains("r.reopenOnReply(at: now)"))
        // And no longer sets the reply by hand beside it, which is how the two would drift apart again.
        #expect(!service.contains("r.replied = true"))
    }
}
