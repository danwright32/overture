import Foundation

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
struct QueueScopeRow: Identifiable, Equatable, Sendable {
    let id: String
    let groupName: String
    let discipline: String
    let venue: String?
    let presenter: String?
    let location: String?

    let performanceDate: String?
    let runNights: [String]
    let performanceStartTimes: [String]
    let nightStartTimes: [String]
    let startTimesVary: Bool

    let fitScore: Int
    let tier: String
    let status: ReviewStatus
    let sentAt: Date?
    let outcome: Outcome
    let showOutcome: ShowOutcome?
    let bookingSuggested: Bool
    let hasDraft: Bool

    let reachabilityProbedAt: Date?
    let reachabilityUnansweredAt: Date?
    let reachabilityResult: Reachability.ProbeResult?

    // The contacts, reduced to the facts a row needs, gathered in ONE walk.
    let facts: RecipientFacts

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
        let contacts = p.countedRecipients
        return RecipientFacts(standings: contacts.map(\.standing),
                              reachabilityAsHeld: p.reachabilityResultAsHeld)
    }
}

extension QueueScopeRow {
    // The row for one show, built from the facts the caller already gathered.
    //
    // The facts are HANDED IN rather than gathered here, which is the whole reason this is cheap: the
    // pass gathers them once per show and gives the same value to this and to the card, so building both
    // is one walk rather than two and `RecipientWalkCountTests`'s pin still holds.
    init(_ p: Prospect, facts: RecipientFacts) {
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
                  reachabilityResult: facts.reachabilityAsHeld,
                  facts: facts)
    }
}
