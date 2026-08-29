import Testing
import Foundation
import SwiftData

// #2863: a pitch that came back with "we would like to, but that is over our budget".
//
// Every other pitched ending says something untrue about it. "Never heard back" claims a silence when
// somebody actually answered, "They said not now" claims the timing was the problem, "I turned them
// down" puts Dan's name on a decision the org made, and "They said no" (where this landed until now)
// keeps the right GROUP and throws away the only part of the answer worth having: they wanted the work
// and could not pay this rate.
//
// Price is the one lost reason that is about Dan's own pricing rather than about the show, which makes
// it the one he can act on. Folding it into `theySaidNo` makes "how many pitches a season are lost on
// rate" permanently unanswerable, because the difference was never written down. Same argument that
// kept `theySaidNotNow` out of `theySaidNo`, `pitchingOtherShows` out of `dateConflict` (#1821) and
// `noWayToReachThem` out of `notAFit` (#2684).
@MainActor
@Suite("Lost on price is its own ending (#2863)")
struct LostOnPriceOutcomeTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self, DayOff.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func pitched(_ ctx: ModelContext, group: String = "Aurora Strings",
                         closedAs outcome: ShowOutcome?, aContactReplied: Bool = false) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "chamber",
                         venue: "Weill Recital Hall", performanceDate: "2026-09-12",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved, dismissReason: nil)
        p.sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        p.showOutcome = outcome
        ctx.insert(p)
        if aContactReplied {
            let r = Recipient(id: "booking@example.test", email: "booking@example.test",
                              provenance: .act)
            r.sendState = .sent
            r.replied = true
            p.setRecipients([r])
        }
        return p
    }

    // MARK: - It reaches the menu Dan actually uses

    // Something WAS sent, so it belongs in the pitched half and nowhere else. Being in that list is the
    // whole of its wiring: `ShowOutcome.menu(wasPitched:)` is the one place the choice of menu is made
    // (#2395), and the close out menu on a reached out row reads it.
    @Test func itIsAPitchedEndingAndReachesThatMenu() {
        #expect(ShowOutcome.pitched.contains(.theySaidPriceTooHigh))
        #expect(!ShowOutcome.neverPitched.contains(.theySaidPriceTooHigh))
        #expect(ShowOutcome.menu(wasPitched: true).contains(.theySaidPriceTooHigh))
        #expect(!ShowOutcome.menu(wasPitched: false).contains(.theySaidPriceTooHigh))
    }

    // Where it sits on the menu, pinned because the order is a property of the vocabulary rather than
    // something each view re-decides. It goes beside the other answers somebody gave, after the flat no
    // and before Dan's own refusal.
    @Test func itSitsWithTheOtherAnswersSomebodyGave() {
        #expect(ShowOutcome.pitched == [.booked, .neverHeardBack, .theySaidNotNow,
                                        .theySaidNo, .theySaidPriceTooHigh, .turnedThemDown])
    }

    // It is Dan's to pick, not one Overture writes for itself. `isOverturesOwn` is derived from the two
    // halves, so a value missing from both would silently become automatic and every menu would refuse it.
    @Test func danCanChooseItHimself() {
        #expect(!ShowOutcome.theySaidPriceTooHigh.isOverturesOwn)
        #expect(ShowOutcome.danCanChoose.contains(.theySaidPriceTooHigh))
    }

    @Test func itIsReportedAsPitchedAndLost() {
        #expect(ShowOutcome.theySaidPriceTooHigh.group == .pitchedAndLost)
    }

    // MARK: - The words

    // The "They said..." shape, because it is the plainest report of what happened and matches the two
    // endings beside it. "Price was too high" would read as Dan judging his own rate, and it is the
    // counted phrase that settles it: this wording survives being read after a number and that one does not.
    @Test func itReadsAsWhatTheySaidRatherThanAsAJudgementOfTheRate() {
        #expect(ShowOutcome.theySaidPriceTooHigh.label == "They said the price was too high")
        let line = ShowOutcome.recordedLine(.theySaidPriceTooHigh, org: "Aurora Strings")
        #expect(line == "Aurora Strings closed out: they said the price was too high.")
    }

    // A pitched ending is what the lost split counts, so it must carry wording meant for use after a
    // number. Required, not optional: an ending with no phrase falls back to its raw value in the report.
    @Test func itCarriesACountedPhraseInTheLabelsOwnWords() throws {
        let phrase = try #require(ShowOutcome.theySaidPriceTooHigh.countedPhrase)
        #expect(phrase == "they said the price was too high")
        #expect(phrase.lowercased() == ShowOutcome.theySaidPriceTooHigh.label.lowercased())
    }

    // MARK: - The reader that counts it

    // #16 is the reason this is its own case rather than a note in a field, and `lostSplitLine` is the
    // reader that will count it: it walks `ShowOutcome.pitched` and names every ending the tally holds.
    // Without a case of its own a budget refusal is inside the "they said no" fragment forever.
    @Test func theLostSplitCountsItApartFromAFlatNo() {
        var tally = OutcomeTally()
        tally.lost = 3
        tally.lostReasons = [.theySaidNo: 1, .theySaidPriceTooHigh: 2]

        #expect(OutcomePatterns.lostFragment(count: 2, outcome: .theySaidPriceTooHigh)
                == "2 they said the price was too high")
        let line = OutcomePatterns.lostSplitLine(tally)
        #expect(line?.contains("2 they said the price was too high") == true)
        #expect(line?.contains("1 they said no") == true)
    }

    // MARK: - It is not "They said no"

    // The whole point of the case. Every fact Dan reads or a report counts has to differ, or the two
    // endings collapse back into one the moment anybody looks.
    @Test func nothingAboutItReadsOrStoresAsAFlatNo() {
        #expect(ShowOutcome.theySaidPriceTooHigh != ShowOutcome.theySaidNo)
        #expect(ShowOutcome.theySaidPriceTooHigh.rawValue == "they_said_price_too_high")
        #expect(ShowOutcome.theySaidPriceTooHigh.rawValue != ShowOutcome.theySaidNo.rawValue)
        #expect(ShowOutcome.theySaidPriceTooHigh.label != ShowOutcome.theySaidNo.label)
        #expect(ShowOutcome.theySaidPriceTooHigh.countedPhrase != ShowOutcome.theySaidNo.countedPhrase)
        #expect(ShowOutcome.recordedLine(.theySaidPriceTooHigh, org: "Org")
                != ShowOutcome.recordedLine(.theySaidNo, org: "Org"))
    }

    // MARK: - How the show READS once it is closed

    // `lostDoorOpen`, the status `neverHeardBack` and `theySaidNotNow` already use, because an org that
    // wanted the work and could not pay this time is not an org to stop pitching. `lostNotInterested`
    // would say they refused the work itself, which is the one thing they did not do.
    //
    // Narrow by construction: the two statuses are read in three places (the closed out predicate in
    // `QueueView+Model`, a colour in `DraftReviewView`, and `Prospect`'s terminal check), and neither
    // feeds the fit score, so this decides how the show reads on screen. What future ranking does with it
    // is decided in `LocalHistory`, separately, below.
    @Test func itLeavesTheDoorOpenRatherThanReadingAsARefusal() {
        #expect(ShowOutcome.theySaidPriceTooHigh.asPerformanceStatus == .lostDoorOpen)
        #expect(ShowOutcome.theySaidPriceTooHigh.asPerformanceStatus != .lostNotInterested)
    }

    // The three readers of that choice, exercised rather than assumed, on a real stored show: the show
    // reads as closed (`Prospect.isClosed`, so nothing routine fires again), and it reads as lost rather
    // than as still in play. Carrying a value at all means the show is over.
    @Test func aShowClosedOnPriceReadsAsClosedAndLost() throws {
        let ctx = ModelContext(try container())
        let p = pitched(ctx, group: "Budget Bound Ensemble", closedAs: .theySaidPriceTooHigh)

        #expect(p.performanceStatus == .lostDoorOpen)
        #expect(p.performanceStatus.label == "Closed (not now)")
        #expect(p.isClosed)

        let item = QueueItem(p)
        #expect(item.isLost)
        #expect(!item.isBooked)
    }

    // MARK: - The bridge to the vocabulary being replaced

    // The `DismissReason` bridge reads stores written before #2394 forward, and no such store can hold
    // this value, so nil is the stated answer rather than an unstated gap. It is a pitched ending anyway,
    // and a pitched ending was never dismissed.
    @Test func itHasNoLegacyDismissReasonSpelling() {
        #expect(ShowOutcome.theySaidPriceTooHigh.asDismissReason == nil)
        #expect(!DismissReason.allCases.map(\.asShowOutcome).contains(.theySaidPriceTooHigh))
    }

    // MARK: - LocalHistory learns nothing this ending did not already teach

    // The branch that had to be argued rather than left to fall through.
    //
    // A price answer is a REPLY, and a reply already earns the org "warm" by its own branch, which
    // `Ranker.priorPoints` weights 10. Adding a branch for this ending above that one would DOWNGRADE the
    // org to whatever the branch said: "lost_soft" is 3, and "lost_hard" is -20 for an org that said yes
    // to the work. So the right answer is no branch at all, and falling through is what preserves the
    // stronger, truer signal the reply already carried.
    @Test func aRepliedShowClosedOnPriceStaysWarm() throws {
        let ctx = ModelContext(try container())
        pitched(ctx, group: "Budget Bound Ensemble", closedAs: .theySaidPriceTooHigh,
                aContactReplied: true)

        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.map(\.status) == ["warm"])
    }

    // The other side of the same argument, for a show whose reply Dan heard some other way (a phone
    // call, a forwarded note) so nothing is recorded on a contact. It reads as an ordinary send, which is
    // exactly what any other pitched show with no recorded reply reads as: nothing about the rate makes
    // the org a worse lead than one that was merely emailed, and Overture has no signal to say more.
    // What matters is that it never goes NEGATIVE.
    @Test func aShowClosedOnPriceWithNoRecordedReplyIsAnOrdinaryContact() throws {
        let ctx = ModelContext(try container())
        pitched(ctx, group: "Quiet Budget Choir", closedAs: .theySaidPriceTooHigh)

        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.map(\.status) == ["contacted"])
    }

    // Measured against its neighbours in the same run, so a later tidy up that files this ending into
    // either lost branch goes red here rather than silently changing what the scout learns.
    @Test func itsNeighboursStillTeachWhatTheyAlwaysDid() throws {
        let ctx = ModelContext(try container())
        pitched(ctx, group: "Refused Org", closedAs: .theySaidNo)
        pitched(ctx, group: "Not Now Org", closedAs: .theySaidNotNow)
        pitched(ctx, group: "Price Org", closedAs: .theySaidPriceTooHigh, aContactReplied: true)

        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        let byOrg = Dictionary(uniqueKeysWithValues: records.map { ($0.groupName, $0.status) })
        #expect(byOrg["Refused Org"] == "lost_hard")
        #expect(byOrg["Not Now Org"] == "lost_soft")
        #expect(byOrg["Price Org"] == "warm")
    }

    // MARK: - Siblings: the other surfaces a pitched ending reaches

    // An inquiry's endings derive from `ShowOutcome.pitched`, so this arrives on the inquiry row's "Mark
    // lost" menu by construction, and it should: an inbound inquiry that did not book on rate is the same
    // fact. Confirmed rather than assumed while the change is open.
    @Test func itReachesTheInquiryMenuToo() {
        #expect(InquiryEnding.danCanChoose.contains(.theySaidPriceTooHigh))
    }

    // The one reader the compiler could NOT name, because it is a comparison rather than an exhaustive
    // switch: `InquiryMutations.MarkAction.outcome` sends `theySaidNo` to `.lostHard` and everything else
    // to `.lostSoft`. A budget answer must take the soft branch, matching `lostDoorOpen` on the show side.
    @Test func aninquiryLostOnPriceIsTheSoftLostCase() throws {
        let ctx = ModelContext(try container())
        let inq = Inquiry(source: .contactForm, inquirerName: "Ada Whitfield",
                          inquirerEmail: "ada@example.test", eventName: "Winter Gala")
        ctx.insert(inq)

        InquiryMutations.mark(inq, as: .lost(.theySaidPriceTooHigh), context: ctx,
                              feedback: ActionFeedback(), now: Date())

        #expect(inq.showOutcome == .theySaidPriceTooHigh)
        #expect(inq.outcome == .lostSoft)
        #expect(!inq.isOpen)
    }

    // A pitched ending is never a dismissal, so it must never reach the run night scope question or the
    // day off offer, both of which are keyed to the never pitched half.
    @Test func itIsNeverTreatedAsADismissal() {
        #expect(!RunNightDrop.classified.contains(.theySaidPriceTooHigh))
        #expect(DayOffOffer.offer(reason: .theySaidPriceTooHigh, performanceDate: "2026-09-12",
                                  alreadyBlocked: false) == nil)
    }
}
