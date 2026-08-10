import Testing
import Foundation
import SwiftData

// #2112 / #2224. Closing a pitch out from the stage Dan actually stands on.
//
// Dan, 2026-08-05: "if a show passes it should give me a hint to mark it as lost. also I want a new
// option here called 'No Response' to indicate that they never even responded to my outreach."
// And 2026-08-06: "I'm almost NEVER going to the archive. I want to leave it there in case I need it but
// I don't want to ever HAVE to go to the archive."
//
// Both outcomes were reachable only from the full card in Archive, which is his reference shelf, not a
// workflow step. An outcome he can only record there is an outcome that in practice does not get
// recorded, which empties the reporting the funnel exists to produce (#16).
@MainActor
@Suite("Closing a pitch out from the Reached out row (#2112, #2224)")
struct ClosingAPitchOutFromTheRowTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let sentAt = Date(timeIntervalSince1970: 1_700_000_000)

    @discardableResult
    private func show(_ ctx: ModelContext, date: String? = "2026-10-25",
                      runEnd: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Every Voice Choirs", discipline: "choral",
                         venue: "Sakura Park", performanceDate: date, sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 8, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .approved)
        p.runEndDate = runEnd
        p.sentAt = sentAt
        p.gmailMessageId = "msg"
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ p: Prospect) -> Recipient {
        let r = Recipient(id: "chelsea@everyvoicechoirs.org", email: "chelsea@everyvoicechoirs.org",
                          provenance: .presenter)
        r.sendState = .sent
        r.sentAt = sentAt
        r.gmailMessageId = "msg-1"
        p.addRecipient(r)
        return r
    }

    // MARK: - Part 1: the hint

    @Test func ashowThatHasBeenAndGoneSaysSo() {
        #expect(ReachedOutClose.passedHint(hasOpened: true, isStillOpen: true)
                == "This show has been and gone.")
    }

    @Test func anupcomingShowSaysNothing() {
        #expect(ReachedOutClose.passedHint(hasOpened: false, isStillOpen: true) == nil)
    }

    // Once it is closed out the hint goes: it exists to prompt an act that has now happened, and a line
    // that stayed would be the app asking for something it already has.
    @Test func aclosedOutPitchDropsTheHint() {
        #expect(ReachedOutClose.passedHint(hasOpened: true, isStillOpen: false) == nil)
    }

    // A multi-night run passing is ONE event, dated at its opening night (#1540: the client's need for
    // photos is over once the run has opened, whatever nights remain).
    @Test func amultiNightRunUsesItsOpeningNight() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, date: "2026-10-25", runEnd: "2026-10-31")

        #expect(p.hasOpened(today: "2026-10-27"), "opened on the 25th, still running")
        #expect(!p.hasOpened(today: "2026-10-25"), "a run opening tonight has not opened yet")
        #expect(!p.hasOpened(today: "2026-10-24"))
    }

    // An undated show never reads as passed. "Date to be confirmed" is a normal state on a season page,
    // and prompting Dan to close out a live lead over it would be worse than saying nothing.
    @Test func anundatedShowIsNeverCalledPassed() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, date: nil)
        #expect(!p.hasOpened(today: "2030-01-01"))
    }

    // MARK: - Part 2: never heard back is its own record

    // The whole point. `Outcome.noResponse` is the DEFAULT every sent prospect carries and means
    // "nothing has happened yet". If the close-out wrote that, "still waiting to hear" and "confirmed
    // silence" would be the same record forever, and that difference can only be captured now.
    @Test func neverHeardBackIsNotTheDefaultNoResponse() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let waiting = contact(p)
        #expect(waiting.resolution == nil, "the premise: a sent, unanswered contact records nothing")

        waiting.markOutcomeManually(resolution: .neverHeardBack, bounced: false)

        #expect(waiting.resolution == .neverHeardBack)
        #expect(waiting.resolution != .declinedSoft, "separable from a real 'not now' in reporting")
    }

    // It closes the door as gently as a soft decline: nobody refused anything.
    @Test func asilenceLeavesTheDoorOpen() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        contact(p).markOutcomeManually(resolution: .neverHeardBack, bounced: false)

        #expect(p.performanceStatus == .lostDoorOpen)
        #expect(p.performanceStatus != .lostNotInterested,
                "a silence must never be recorded as the org turning Dan down")
    }

    // And re-adding that address later is Dan trying again, not overriding a no.
    @Test func thecontactCanBeTriedAgainLater() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p)
        r.markOutcomeManually(resolution: .neverHeardBack, bounced: false)

        let result = ManualRecipientCheck.evaluate(email: r.id, existingRecipients: p.recipients, venue: p.venue)
        #expect(result.action == ManualRecipientCheck.Action.resume(existingId: r.id))
    }

    // It says what happened, not what they said, wherever it is shown.
    @Test func itreadsAsWhatHappened() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p)
        r.markOutcomeManually(resolution: .neverHeardBack, bounced: false)
        #expect(RecipientSnapshot(r).statusLabel == "Never heard back")
    }

    // MARK: - the menu

    // #2395: the endings come from the one vocabulary. #2396: and how each READS as a show status, which is
    // the reader-side mapping that replaced the contact-level copy this phase removed.
    @Test func themenuOffersTheFiveWaysAPitchEnds() {
        #expect(ShowOutcome.pitched.map(\.label)
                == ["Booked", "Never heard back", "They said not now", "They said no", "I turned them down"])
        #expect(ShowOutcome.pitched.map(\.asPerformanceStatus)
                == [.booked, .lostDoorOpen, .lostDoorOpen, .lostNotInterested, .stoodDown])
    }

    // MARK: - recording it

    @Test func recordingBookedTakesTheRowOffTheStageAndCountsInTheReport() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p)
        let now = sentAt.addingTimeInterval(10 * 86_400)
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) != nil)

        let ok = ProspectMutations.recordOutcome(QueueItem(p), .booked, prospects: [p],
                                                 context: ctx, feedback: ActionFeedback())
        #expect(ok)

        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) == nil)
        let tally = OutcomeStats.tally(OutcomePatterns.samples(from: [p], by: .production))
        #expect(tally.booked == 1)
        #expect(tally.bookedManual == 1, "Dan's own call, not a detection")
    }

    @Test func recordingASilenceAlsoTakesTheRowOffTheStage() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p)
        let now = sentAt.addingTimeInterval(10 * 86_400)

        let ok = ProspectMutations.recordOutcome(QueueItem(p), .neverHeardBack, prospects: [p],
                                                 context: ctx, feedback: ActionFeedback())

        #expect(ok)
        #expect(p.showOutcome == .neverHeardBack, "the ending is recorded on the SHOW (#2394)")
        // #2396: and NOWHERE else. The contact keeps only routing facts, so the ending is not copied onto
        // it, and the row leaves the stage because the show's own field says the show is over.
        #expect(r.resolution == nil)
        #expect(ReachedOutQueue.nextReachOut(for: r, of: p, now: now) == nil)
        #expect(p.outcome != .booked, "only a booking touches the legacy show-level outcome")
    }

    // A booking Dan recorded stays HIS. Without the show-level manual stamp the next Downbeat reconcile
    // would auto-book the same show and quietly move it from the manual half of the split to the
    // automatic one, which is a number changing with nothing having happened.
    @Test func abookingHeRecordedIsNotReClaimedByDetection() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.downbeatClientId = "C1"
        let r = contact(p)
        ProspectMutations.recordOutcome(QueueItem(p), .booked, prospects: [p],
                                        context: ctx, feedback: ActionFeedback())

        let booking = OvertureBooking(id: "B1", clientId: "C1", clientDisplayName: "Every Voice Choirs",
                                      shootName: "Gala", startDate: "2026-10-25", endDate: "2026-10-25",
                                      venueId: nil, venueName: "Sakura Park")
        _ = DownbeatBooking.reconcileBooked(prospects: [p], clients: [], bookings: [booking],
                                            health: .ok, now: Date())

        let tally = OutcomeStats.tally(OutcomePatterns.samples(from: [p], by: .production))
        #expect(tally.bookedManual == 1, "he recorded it, so it stays his")
        #expect(tally.bookedAuto == 0)
    }

    // The acknowledgment names the outcome back, because the row leaves the stage the instant it lands
    // and a banner saying only "Saved" would be the sole evidence anything happened.
    @Test func theacknowledgmentNamesWhatWasRecorded() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p)
        let feedback = ActionFeedback()

        ProspectMutations.recordOutcome(QueueItem(p), .neverHeardBack, prospects: [p],
                                        context: ctx, feedback: feedback)

        #expect(feedback.message == "Every Voice Choirs closed out: never heard back.")
    }

    // The failure path: a row for a show this context does not hold records nothing and reports false,
    // so nothing ever looks closed out on the strength of a write that did not land (L12).
    @Test func acloseOutThatCouldNotFindItsShowRecordsNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p)

        let ok = ProspectMutations.recordOutcome(QueueItem(p), .booked, prospects: [],
                                                 context: ctx, feedback: ActionFeedback())

        #expect(!ok)
        #expect(r.resolution == nil)
        #expect(p.outcome == .noResponse)
    }
}

// The wiring: both halves reach the row Dan stands on, and the control is not a second state menu.
@Suite("The close-out reaches the Reached out row (#2112, #2224)")
struct ReachedOutCloseWiringTests {
    private var source: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    @Test func therowDrawsTheHintAndTheControl() throws {
        let row = try #require(SourceGuardHelper.propertyBody(
            "private func reachedOutRow(_ pair: (prospect: Prospect, recipient: Recipient, next: Date), now: Date) -> some View {",
            in: source))
        #expect(row.contains("ReachedOutClose.passedHint(hasOpened: p.hasOpened(today: today)"))
        #expect(row.contains("CloseOutMenu(outcomes: ShowOutcome.menu(wasPitched: p.wasPitched))"))
        #expect(row.contains("ProspectMutations.recordOutcome("))
    }

    // #1139: the outcome control and the conversation-state control set genuinely different things and
    // must not read as two identical dropdowns. It carries the outcome icon and the outcome accent, which
    // is what makes them a deliberate system rather than one branded control and one system default.
    @Test func theoutcomeControlIsNotASecondStateMenu() throws {
        let row = try #require(SourceGuardHelper.propertyBody(
            "private func reachedOutRow(_ pair: (prospect: Prospect, recipient: Recipient, next: Date), now: Date) -> some View {",
            in: source))
        let menu = SourceGuardHelper.source("Overture/UI/CloseOutMenu.swift")
        #expect(menu.contains("ContactRowControls.Kind.outcome.icon"))
        #expect(menu.contains("ContactRowControls.Kind.outcome.accent.color"))
        #expect(ContactRowControls.Kind.outcome.icon != ContactRowControls.Kind.conversationState.icon)
        #expect(ContactRowControls.Kind.outcome.accent != ContactRowControls.Kind.conversationState.accent)
    }
}
