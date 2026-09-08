import Foundation

// #3653 Phase 3: what a whole-scope consumer of the render pass is allowed to know about a show.
//
// THE POINT IS THE REFUSAL, not the list. A function written over `[QueueItem]` can reach any of the
// card's 130 fields, so nothing stops a whole-scope sweep growing a read of a lint verdict, a send group
// or a greeting, and the day one does, the card can no longer be built for the rendered rows alone: the
// whole-scope consumer would need one for every show in the store. That regression is invisible in
// review, because the new line reads exactly like every line around it (L63, the #2033 shape in this
// same file).
//
// Written over `some QueueScopeFacts` instead, the compiler refuses it. The body can reach nothing but
// the ~24 answers below, which are precisely what `QueueScopeRow` carries, so "this sweep does not need
// a card" stops being a claim in a PR body and becomes a thing the build enforces.
//
// `QueueItem` conforms too, and that is not a loophole: it is what lets today's callers, and the parity
// oracle, pass a card where a row is expected and get the same answer. The narrowing that matters is on
// the FUNCTIONS, which can no longer see anything else.
protocol QueueScopeFacts {
    var id: String { get }
    var groupName: String { get }
    var discipline: String { get }
    var venue: String? { get }
    var presenter: String? { get }
    var location: String? { get }

    var performanceDate: String? { get }
    var runNights: [String] { get }
    var performanceStartTimes: [String] { get }
    var nightStartTimes: [String] { get }
    var startTimesVary: Bool { get }

    var fitScore: Int { get }
    var tier: String { get }
    var status: ReviewStatus { get }
    var sentAt: Date? { get }
    var outcome: Outcome { get }
    var showOutcome: ShowOutcome? { get }
    var bookingSuggested: Bool { get }
    var hasDraft: Bool { get }

    var reachabilityProbedAt: Date? { get }
    var reachabilityUnansweredAt: Date? { get }
    var reachabilityRecheckRequestedAt: Date? { get }
    var reachabilityResult: Reachability.ProbeResult? { get }
    var inheritedReachability: OrgAnswerLedger.Inherited? { get }

    // Derived on both sides, from the SAME pure rules, which is what `QueueScopeRowParityTests` pins.
    var performanceStatus: PerformanceStatus { get }
    var isBooked: Bool { get }
    var isLost: Bool { get }
}

// #3653 Phase 3c: the cheap half of a queue card.
//
// NAMED `QueueScopeRow` AND NOT `QueueRow`, which is what the plan called it. `QueueRow` is taken, by
// the enum at `InquiryQueue.swift:47` that unifies a scouted show and a hire inquiry into one daily
// list, and that is a different idea entirely: it is what the LIST holds, while this is what a show
// reduces to before anybody decides whether to draw it. The plan did not know, and taking the name
// would have meant renaming a type the queue renders through. `Scope` is the word this codebase already
// uses for the population these are built over (`RenderData.queueScope`, `QueueModel.queueScope`).
//
// WHAT THIS IS FOR. `QueueItem` has 130 stored fields, and building one costs the send grouping, the
// recipient snapshots and a draft lint pass over every pending contact's body. The render pass built one
// for every show in the queue, on every redraw, and then used all 130 fields for the rows on screen and
// about twenty of them for everything else.
//
// This is those twenty. Every whole-scope consumer of the pass (`QueueModel.summary`,
// `pendingBookingCount`, `selfBookingIndex`, `scoutRows`, `probeSelection`, `groupByDate`,
// `orderedWithinNight`, `keysMissedByACheck` and the masthead) reads only these, which was established
// by reading each consumer's body through to the fields it touches rather than from a table, and
// recorded on #3653 as the phase's feasibility gate. That gate is what makes the split legal: if one of
// them had needed a card, widening the row to carry card fields would have reintroduced the cost the
// split exists to remove, invisibly.
//
// WHAT IS DELIBERATELY NOT HERE: anything lint-derived, greeting-derived or send-group-derived. Those
// are what a card costs, and #3654 is what stops them being paid for a show nobody is looking at.
//
// EVERY FIELD BUT THE IDENTITY CARRIES A DEFAULT, on `QueueItem`'s own precedent beside it. A row is
// built from a show by the initialiser at the bottom of this file, which fills all of them, and the
// memberwise one exists so a test can state the three or four fields its question is about instead of
// twenty-four. A row built with a field missing is therefore possible, which is the price: what stops it
// mattering is that nothing in `mac/Overture` calls the memberwise init at all.
struct QueueScopeRow: Identifiable, Equatable, Sendable, QueueScopeFacts {
    var id: String
    var groupName: String
    var discipline: String
    var venue: String? = nil
    var presenter: String? = nil
    var location: String? = nil

    var performanceDate: String? = nil
    var runNights: [String] = []
    var performanceStartTimes: [String] = []
    var nightStartTimes: [String] = []
    var startTimesVary: Bool = false

    var fitScore: Int = 0
    var tier: String = "mid"
    var status: ReviewStatus = .new
    var sentAt: Date? = nil
    var outcome: Outcome = .noResponse
    var showOutcome: ShowOutcome? = nil
    var bookingSuggested: Bool = false
    var hasDraft: Bool = false

    var reachabilityProbedAt: Date? = nil
    var reachabilityUnansweredAt: Date? = nil
    // #3653: BOTH of the fields that release a show from a fresh answer, not one of them.
    //
    // `hasFreshReachabilityAnswer` reads the re-check request FIRST and the inherited answer SECOND, and
    // a row carrying only the probe stamp would answer that question with two of its three inputs
    // missing: a show Dan asked to re-check would read as still answered, and a show holding only its
    // organisation's answer would read as never checked. Both are wrong in the direction that offers to
    // spend money, or refuses to (#2261, #1598 Phase 5).
    var reachabilityRecheckRequestedAt: Date? = nil
    var reachabilityResult: Reachability.ProbeResult? = nil
    var inheritedReachability: OrgAnswerLedger.Inherited? = nil

    // The contacts, reduced to the facts a row needs, gathered in ONE walk.
    var facts: RecipientFacts = .none

    // #3653: the two rules a row derives rather than stores, each through the SAME pure function the
    // card's own value comes from, so a row and a card can never disagree about a show (L107).
    //
    // `PerformanceStatus.of(_:)` cannot be used here: it takes a `Prospect` and reads its recipients, so
    // asking it would be the second walk this whole design exists to avoid. `derive(_:leadBooked:)` is
    // the same rule over the standings the walk already gathered, which is why #3670 and #3653's step
    // 3b.5 pulled it out.
    var performanceStatus: PerformanceStatus {
        if let recorded = showOutcome?.asPerformanceStatus { return recorded }
        return PerformanceStatus.derive(facts.standings, leadBooked: outcome == .booked)
    }

    var isBooked: Bool { performanceStatus == .booked || outcome == .booked }

    var isLost: Bool {
        performanceStatus == .lostDoorOpen || performanceStatus == .lostNotInterested
            || outcome == .lostSoft || outcome == .lostHard
    }
}

// The contacts of one show, reduced to the facts anything cheap needs to know about them.
//
// THE POINT IS THE WALK, not the fields. `Prospect.countedRecipients` is the one accessor that records
// `WorkTally.recipientReaches`, and #3675 pinned a card at exactly one reach. A row that asked the model
// its own questions would make that two per show and the pin would go red, correctly. So the pass gathers
// these once and hands the same value to the row and to the card.
//
// It holds VALUES and never models, which is what lets a row be `Sendable` and comparable and lets the
// row outlive the fetch that produced it.
struct RecipientFacts: Equatable, Sendable {
    // What `PerformanceStatus.derive` needs. One entry per contact, in the order the show holds them.
    let standings: [RecipientStanding]

    // The badge's verdict, computed rather than the raw route facts, and that is deliberate.
    //
    // `Prospect.reachabilityResultFromRecipients` SHORT CIRCUITS: it walks the contacts once for an
    // address and only computes `usableContactFormURLs` and `socialRouteURLs` when there is none, because
    // those two are the expensive pair and a show with an address never needs them. Storing
    // `Reachability.RouteFacts` here would have to fill all four fields eagerly, so every show would pay
    // the expensive pair whether it needed them or not: a cheaper row that costs more (L102).
    let reachabilityAsHeld: Reachability.ProbeResult?

    static let none = RecipientFacts(standings: [], reachabilityAsHeld: nil)
}

extension RecipientFacts {
    // THE ONE PLACE the tier one path reads a show's contacts.
    //
    // #3653 step 3d asks for the claim to be COUNTED rather than name listed, and this is where that
    // counting happens: `countedRecipients` is the accessor that records `WorkTally.recipientReaches`,
    // so a second walk anywhere in this path moves a number rather than merely offending a rule. A source
    // guard forbidding `DraftCheck`, `SendGroup` and friends here would assert a PROXY for the quantity
    // it protects and would pass unchanged while the row took three walks naming none of them (L63).
    static func of(_ p: Prospect) -> RecipientFacts {
        of(p, contacts: p.countedRecipients)
    }

    // The same reduction, from contacts the caller has ALREADY read.
    //
    // The render pass reads them once and builds a row and a card from that one read, so it takes this
    // arm; anything asking about a single show on its own takes the arm above. ONE definition of what a
    // row knows about a show's contacts, because two would drift and only one of them would be the one
    // the pass actually uses (L107, L263).
    static func of(_ p: Prospect, contacts: [Recipient]) -> RecipientFacts {
        RecipientFacts(standings: contacts.map(\.standing),
                       reachabilityAsHeld: p.reachabilityResultAsHeld)
    }
}

extension QueueScopeRow {
    // The row for one show, built from the facts the caller already gathered.
    //
    // The facts are HANDED IN rather than gathered here, which is the whole reason this is cheap: the
    // pass gathers them once per show and gives the same value to this and to the card, so building both
    // is one walk rather than two and `RecipientWalkCountTests`'s pin still holds.
    init(_ p: Prospect, facts: RecipientFacts,
         // #3653: the organisation's answer, which is NOT a fact about this show's own contacts and so
         // cannot come from the walk. It is derived once per pass from the whole-store ledger
         // (`QueueModel.inheritedAnswers`) and handed in, exactly as the card receives it, so the row and
         // the card cannot disagree about whether a show already has an answer to inherit.
         inheritedReachability: OrgAnswerLedger.Inherited? = nil) {
        // #3653 step 3a: counted here, the one place a row is built from a show.
        //
        // It exists so the four `FeltWaitCostTests` waits have something to wait ON once #3654 stops
        // building a card for every show: today they key on `WorkTally.queueItems`, and the day the card
        // count stops being the scope count, every one of those conditions becomes unmeetable and each
        // test burns its full deadline (90s, 20s, 20s, 60s) in the serial hosted bundle before failing.
        QueueRenderPass.WorkTally.recordQueueRow()
        self.init(id: p.naturalKey,
                  groupName: p.groupName,
                  discipline: p.discipline,
                  venue: p.venue,
                  presenter: p.presenter,
                  location: p.location,
                  performanceDate: p.performanceDate,
                  runNights: p.runNights,
                  performanceStartTimes: p.performanceStartTimes,
                  nightStartTimes: p.nightStartTimes,
                  startTimesVary: p.startTimesVary,
                  fitScore: p.fitScore,
                  tier: p.tier,
                  status: p.status,
                  sentAt: p.sentAt,
                  outcome: p.outcome,
                  showOutcome: p.showOutcome,
                  bookingSuggested: p.bookingSuggested,
                  hasDraft: p.draftBody != nil,
                  reachabilityProbedAt: p.reachabilityProbedAt,
                  reachabilityUnansweredAt: p.reachabilityUnansweredAt,
                  reachabilityRecheckRequestedAt: p.reachabilityRecheckRequestedAt,
                  reachabilityResult: facts.reachabilityAsHeld,
                  inheritedReachability: inheritedReachability,
                  facts: facts)
    }
}
