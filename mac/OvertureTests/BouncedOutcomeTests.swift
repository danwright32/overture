import Testing
import Foundation
import SwiftData

// #3674: a pitch whose email never arrived.
//
// Dan, 2026-09-07, reading the close out menu: "I need a new reason that says that the email bounced.
// So it's not a rejected, but it's an indicator I'm never going to hear back."
//
// Every other pitched ending says something untrue about it. "They said no" and "They said not now"
// assert an answer nobody gave, "I turned them down" puts Dan's name on a decision nobody made, and
// "Never heard back" (where this landed until now) claims a silence. A silence is an organisation that
// received a pitch and chose not to answer; a bounce is one that never received anything at all, so
// recording a bounce as a silence writes a fact about the org that is false about them.
//
// A bounce is a fact about the ADDRESS, which makes it the one lost reason that names something
// fixable: the route was wrong and can be re-found. Same argument that kept `theySaidPriceTooHigh`
// out of `theySaidNo` (#2863), `noWayToReachThem` out of `notAFit` (#2684) and `pitchingOtherShows`
// out of `dateConflict` (#1821).
@MainActor
@Suite("A bounced email is its own ending (#3674)")
struct BouncedOutcomeTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self, DayOff.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func pitched(_ ctx: ModelContext, group: String = "A Sharp Theatre",
                         closedAs outcome: ShowOutcome?, aContactReplied: Bool = false) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "theatre",
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

    // Something WAS sent, which is what `ShowOutcome.menu(wasPitched:)` keys on, so it belongs in the
    // pitched half and nowhere else. A bounce cannot happen to a show nobody emailed.
    @Test func itIsAPitchedEndingAndReachesThatMenu() {
        #expect(ShowOutcome.pitched.contains(.emailBounced))
        #expect(!ShowOutcome.neverPitched.contains(.emailBounced))
        #expect(ShowOutcome.menu(wasPitched: true).contains(.emailBounced))
        #expect(!ShowOutcome.menu(wasPitched: false).contains(.emailBounced))
    }

    // Where it sits, pinned because the order is a property of the vocabulary rather than something each
    // view re-decides. Directly under "Never heard back": they are the two endings that record no answer,
    // and the whole point of this case is that Dan has a choice between them, which adjacency is what
    // makes him notice (L609).
    @Test func itSitsDirectlyUnderTheSilenceItIsNot() {
        #expect(ShowOutcome.pitched == [.booked, .neverHeardBack, .emailBounced, .theySaidNotNow,
                                        .theySaidNo, .theySaidPriceTooHigh, .turnedThemDown])
    }

    @Test func danCanChooseItHimself() {
        #expect(!ShowOutcome.emailBounced.isOverturesOwn)
        #expect(ShowOutcome.danCanChoose.contains(.emailBounced))
    }

    @Test func itIsReportedAsPitchedAndLost() {
        #expect(ShowOutcome.emailBounced.group == .pitchedAndLost)
    }

    // MARK: - The words

    // Dan's own words, chosen by him from four renderings on 2026-09-07 with the report line shown
    // beside each. He picked the menu wording that does not survive being read after a number, knowing
    // that: see `itCarriesAShortenedCountedPhrase` for the half that follows from it.
    @Test func itSaysWhatHappenedToTheMessageRatherThanWhatAnybodyDecided() {
        #expect(ShowOutcome.emailBounced.label == "The email bounced")
        let line = ShowOutcome.recordedLine(.emailBounced, org: "A Sharp Theatre")
        #expect(line == "A Sharp Theatre closed out: the email bounced.")
    }

    // The counted phrase is a SHORTENING of the label, not a second phrasing of the fact: the report
    // renders "\(count) \(phrase)", and "3 the email bounced" is not a sentence while "3 bounced" is.
    // Dropping the leading words is what keeps one vocabulary; inventing different ones would be the
    // #843 trap from the naming direction, which is why the guard is a suffix rule and not a free pass.
    @Test func itCarriesAShortenedCountedPhrase() throws {
        let phrase = try #require(ShowOutcome.emailBounced.countedPhrase)
        #expect(phrase == "bounced")
        #expect(ShowOutcome.emailBounced.label.lowercased().hasSuffix(phrase))
    }

    // MARK: - The reader that counts it

    @Test func theLostSplitCountsItApartFromASilence() {
        var tally = OutcomeTally()
        tally.lost = 3
        tally.lostReasons = [.neverHeardBack: 1, .emailBounced: 2]

        #expect(OutcomePatterns.lostFragment(count: 2, outcome: .emailBounced) == "2 bounced")
        let line = OutcomePatterns.lostSplitLine(tally)
        #expect(line?.contains("2 bounced") == true)
        #expect(line?.contains("1 never heard back") == true)
    }

    // MARK: - It is not "Never heard back"

    // The whole point of the case. Every fact Dan reads or a report counts has to differ, or the two
    // endings collapse back into one the moment anybody looks.
    @Test func nothingAboutItReadsOrStoresAsASilence() {
        #expect(ShowOutcome.emailBounced != ShowOutcome.neverHeardBack)
        #expect(ShowOutcome.emailBounced.rawValue == "email_bounced")
        #expect(ShowOutcome.emailBounced.rawValue != ShowOutcome.neverHeardBack.rawValue)
        #expect(ShowOutcome.emailBounced.label != ShowOutcome.neverHeardBack.label)
        #expect(ShowOutcome.emailBounced.countedPhrase != ShowOutcome.neverHeardBack.countedPhrase)
        #expect(ShowOutcome.recordedLine(.emailBounced, org: "Org")
                != ShowOutcome.recordedLine(.neverHeardBack, org: "Org"))
    }

    // MARK: - How the show READS once it is closed

    // `lostDoorOpen`, the status the other non-refusals already use. Nobody refused anything: the message
    // did not arrive. `lostNotInterested` would say the org turned the work down, which is the one thing
    // it cannot have done.
    @Test func itLeavesTheDoorOpenRatherThanReadingAsARefusal() {
        #expect(ShowOutcome.emailBounced.asPerformanceStatus == .lostDoorOpen)
        #expect(ShowOutcome.emailBounced.asPerformanceStatus != .lostNotInterested)
    }

    @Test func aShowClosedAsBouncedReadsAsClosedAndLost() throws {
        let ctx = ModelContext(try container())
        let p = pitched(ctx, group: "Bounced Org", closedAs: .emailBounced)

        #expect(p.performanceStatus == .lostDoorOpen)
        #expect(p.isClosed)

        let item = QueueItem(p)
        #expect(item.isLost)
        #expect(!item.isBooked)
    }

    // MARK: - A reply refutes it

    // Dan's call, 2026-09-07, asked directly with both readings in front of him: reopen, the same as
    // "Never heard back". His stated purpose for the ending is "an indicator I'm never going to hear
    // back", and a reply is that being proved wrong. It also covers the real case the bounce flag is
    // per contact for: a show with two addresses where only one bounced and the other person answers.
    //
    // This is the one place it parts company with #2915's general rule that every ending other than a
    // silence records something that HAPPENED. The bounce did happen; what it was recorded to MEAN did
    // not.
    @Test func aLaterReplyReopensAShowClosedAsBounced() {
        #expect(ReplyReopen.endingIsRefuted(by: .emailBounced))

        let closedAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ReplyReopen.shouldClear(outcome: .emailBounced, closedAt: closedAt,
                                        repliedAt: closedAt.addingTimeInterval(86_400)))
    }

    // The other half of the same rule, unchanged: a reply that PREDATES the close out is the evidence
    // Dan already had when he closed it, so it may not undo his decision.
    @Test func aReplyPredatingTheCloseOutDoesNotReopenIt() {
        let closedAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(!ReplyReopen.shouldClear(outcome: .emailBounced, closedAt: closedAt,
                                         repliedAt: closedAt.addingTimeInterval(-86_400)))
    }

    // MARK: - The bridge to the vocabulary being replaced

    @Test func itHasNoLegacyDismissReasonSpelling() {
        #expect(ShowOutcome.emailBounced.asDismissReason == nil)
        #expect(!DismissReason.allCases.map(\.asShowOutcome).contains(.emailBounced))
    }

    // MARK: - What the scout learns from it: nothing

    // The branch that had to be argued rather than left to fall through, and it is the one place this
    // ending differs from every other pitched one.
    //
    // `LocalHistory` files any show with a `sentAt` as "contacted", which is a statement about the ORG's
    // prior relationship with Dan. For a bounce that statement is false: nobody there was contacted. It
    // is `noWayToReachThem`'s situation exactly (#2684), reached by a different route: Overture had a
    // route and the route was wrong, so the org did nothing to be judged on and must teach nothing.
    //
    // `Ranker.priorPoints` weights "contacted" and no record alike at 0, so this changes no ranking
    // today. What it changes is whether a false fact is written down for every later reader of the
    // history to repeat.
    @Test func aBouncedShowTeachesTheScoutNothingAtAll() throws {
        let ctx = ModelContext(try container())
        pitched(ctx, group: "Bounced Org", closedAs: .emailBounced)

        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.isEmpty)
    }

    // A bounce on one address does not erase a colleague's reply. The warm branch runs first and must
    // keep running: somebody at that org DID write, which is the strongest signal the history carries.
    @Test func aBouncedShowSomebodyElseAnsweredIsStillWarm() throws {
        let ctx = ModelContext(try container())
        pitched(ctx, group: "Half Bounced Org", closedAs: .emailBounced, aContactReplied: true)

        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(records.map(\.status) == ["warm"])
    }

    // Measured against its neighbours in the same run, so a later tidy up that files this ending as an
    // ordinary contact or into either lost branch goes red here rather than silently changing what the
    // scout learns.
    @Test func itsNeighboursStillTeachWhatTheyAlwaysDid() throws {
        let ctx = ModelContext(try container())
        pitched(ctx, group: "Refused Org", closedAs: .theySaidNo)
        pitched(ctx, group: "Not Now Org", closedAs: .theySaidNotNow)
        pitched(ctx, group: "Silent Org", closedAs: .neverHeardBack)
        pitched(ctx, group: "Bounced Org", closedAs: .emailBounced)

        let records = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        let byOrg = Dictionary(uniqueKeysWithValues: records.map { ($0.groupName, $0.status) })
        #expect(byOrg["Refused Org"] == "lost_hard")
        #expect(byOrg["Not Now Org"] == "lost_soft")
        #expect(byOrg["Silent Org"] == "contacted")
        #expect(byOrg["Bounced Org"] == nil)
    }

    // MARK: - Siblings: the other surfaces a pitched ending reaches

    // An inquiry's endings derive from `ShowOutcome.pitched`, so this arrives on the inquiry row's menu
    // by construction, and it should: Dan's reply to an inbound inquiry can bounce exactly as a cold
    // pitch can.
    @Test func itReachesTheInquiryMenuToo() {
        #expect(InquiryEnding.danCanChoose.contains(.emailBounced))
    }

    // The reader the compiler names but whose ANSWER is a decision: the soft lost case, matching
    // `lostDoorOpen` on the show side. A bounce is not a refusal of the work.
    @Test func anInquiryClosedAsBouncedIsTheSoftLostCase() throws {
        let ctx = ModelContext(try container())
        let inq = Inquiry(source: .contactForm, inquirerName: "Ada Whitfield",
                          inquirerEmail: "ada@example.test", eventName: "Winter Gala")
        ctx.insert(inq)

        InquiryMutations.mark(inq, as: .lost(.emailBounced), context: ctx,
                              feedback: ActionFeedback(), now: Date())

        #expect(inq.showOutcome == .emailBounced)
        #expect(inq.outcome == .lostSoft)
        #expect(!inq.isOpen)
    }

    // A pitched ending is never a dismissal, so it must never reach the run night scope question or the
    // day off offer, both of which are keyed to the never pitched half.
    @Test func itIsNeverTreatedAsADismissal() {
        #expect(!RunNightDrop.classified.contains(.emailBounced))
        #expect(DayOffOffer.offer(reason: .emailBounced, performanceDate: "2026-09-12",
                                  alreadyBlocked: false) == nil)
    }
}
