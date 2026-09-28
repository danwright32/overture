import Foundation
import SwiftData

// #4106 plan v7, Step T0: every order dependent queue term, called through a CANONICAL INPUT ORDER.
//
// WHY THIS EXISTS. Phase 0b measured today's pass over reversed or shuffled rows and found 6 rows that
// differ at 1,344 shows and 217 at 5,376. An oracle whose answer moves with the order its input arrives
// in cannot judge a patched value, because a patch and a rebuild that disagree only in tie order are
// indistinguishable from a patch that is wrong (L70). So every oracle a Phase 0c prototype is proved
// against is one of these: the production function, unchanged, handed its input in one fixed order.
//
// WHAT THIS IS NOT. It is never a patch path and never product behaviour. Nothing under `mac/Overture/`
// calls it, and making the PRODUCT terms deterministic is Step T, after Dan rules on each visible order
// (decisions 13 and 18). Until then the product is exactly as order dependent as it was.
//
// THE ORDER. Rows by natural key (the id every value type here carries is `Prospect.naturalKey`);
// org answers by (orgKey, presenterName, probedAt). Each wrapper's sort sits on its OWN line with a name
// found nowhere else, so `scripts/mutate.sh --at` can remove exactly one of them and watch the
// 100 permutation test for that term go red (L1).
//
// ONE DEPENDENCE THIS CANNOT REACH, and it says so rather than pretending: ReachedOutQueue's
// representative is chosen over `p.recipients`, which is a RELATIONSHIP's order rather than the input
// list's. Sorting the prospects cannot touch it, so it is judged by tie class instead
// (`reachedOutTieClass`), as plan section 6's second bullet says.
enum CanonicalOracle {

    // MARK: the canonical orders

    static func byNaturalKey(_ left: Prospect, _ right: Prospect) -> Bool {
        left.naturalKey < right.naturalKey
    }

    static func showLinkRowOrder(_ left: ShowLink.Row, _ right: ShowLink.Row) -> Bool {
        left.id < right.id
    }

    static func engagementRowOrder(_ left: EngagementLink.Row, _ right: EngagementLink.Row) -> Bool {
        left.id < right.id
    }

    static func answerOrder(_ left: OrgReachabilityAnswer, _ right: OrgReachabilityAnswer) -> Bool {
        if left.orgKey != right.orgKey { return left.orgKey < right.orgKey }
        if left.presenterName != right.presenterName { return left.presenterName < right.presenterName }
        return left.probedAt < right.probedAt
    }

    // MARK: the wrappers, one per order dependent term

    static func showLinkGroup(_ rows: [ShowLink.Row]) -> [String: [String]] {
        let canonicalShowLinkGroupRows = rows.sorted(by: showLinkRowOrder)
        return ShowLink.group(canonicalShowLinkGroupRows)
    }

    static func showLinkCollapse(_ rows: [ShowLink.Row],
                                 drawn: Set<String>? = nil) -> (fronts: [String: [String]], hidden: Set<String>) {
        let canonicalShowLinkCollapseRows = rows.sorted(by: showLinkRowOrder)
        return ShowLink.collapse(canonicalShowLinkCollapseRows, drawn: drawn)
    }

    static func queueScope(_ all: [Prospect]) -> [Prospect] {
        let canonicalQueueScopeRows = all.sorted(by: byNaturalKey)
        return QueueModel.queueScope(canonicalQueueScopeRows)
    }

    static func reachedOut(_ prospects: [Prospect],
                           now: Date) -> [(prospect: Prospect, recipient: Recipient, next: Date)] {
        let canonicalReachedOutRows = prospects.sorted(by: byNaturalKey)
        return ReachedOutQueue.activeWithDates(from: canonicalReachedOutRows, now: now)
    }

    static func engagementLink(_ rows: [EngagementLink.Row]) -> [String: [EngagementLink.Member]] {
        let canonicalEngagementRows = rows.sorted(by: engagementRowOrder)
        return EngagementLink.group(canonicalEngagementRows)
    }

    static func feedBreakEvents(_ rows: [Prospect], asOf: String) -> [FeedBreakEvent.Event] {
        let canonicalFeedBreakRows = rows.sorted(by: byNaturalKey)
        return FeedBreakEvent.events(among: canonicalFeedBreakRows, asOf: asOf)
    }

    // laterLookalikes is built inline in `QueueModel.scope` and reaches nothing but the cards, so the
    // wrapper reads it where a card reads it: each built card's `laterLookalikeTitles`, keyed by the card.
    static func laterLookalikes(_ prospects: [Prospect], now: Date, today: String) -> [String: [String]] {
        let canonicalLookalikeRows = prospects.sorted(by: byNaturalKey)
        let scope = QueueModel.scope(from: canonicalLookalikeRows, now: now, today: today)
        return lookalikeTitlesByCard(scope, keys: canonicalLookalikeRows.map(\.naturalKey))
    }

    static func lookalikeTitlesByCard(_ scope: QueueModel.Scope, keys: [String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for key in keys {
            guard let titles = scope.cards.alreadyBuilt(key)?.laterLookalikeTitles, !titles.isEmpty else { continue }
            out[key] = titles
        }
        return out
    }

    static func inheritedAnswers(_ answers: [OrgReachabilityAnswer], corpus: [Prospect],
                                 now: Date) -> [String: OrgAnswerLedger.Inherited] {
        let canonicalLedgerAnswers = answers.sorted(by: answerOrder)
        let canonicalLedgerCorpus = corpus.sorted(by: byNaturalKey)
        return QueueModel.inheritedAnswers(canonicalLedgerAnswers, corpus: canonicalLedgerCorpus,
                                           overrides: .none, refusals: .none, heldKeys: [], now: now)
    }

    // #4106 Phase 0c.4: the same wrapper with every input the pass hands the ledger. T5's neighbourhood
    // includes refusals, holds and overrides (plan v7 facts 2 and 3), and a wrapper that fixes them at
    // `.none` can never see a patch get one of them wrong. Same canonical orders as the wrapper above, on
    // lines of their own so either can be mutated alone.
    static func inheritedAnswers(_ answers: [OrgReachabilityAnswer], corpus: [Prospect],
                                 overrides: ProducerOverrides, refusals: ContactRefusal.Ledger,
                                 heldKeys: Set<String>, now: Date) -> [String: OrgAnswerLedger.Inherited] {
        let canonicalFullLedgerAnswers = answers.sorted(by: answerOrder)
        let canonicalFullLedgerCorpus = corpus.sorted(by: byNaturalKey)
        return QueueModel.inheritedAnswers(canonicalFullLedgerAnswers, corpus: canonicalFullLedgerCorpus,
                                           overrides: overrides, refusals: refusals, heldKeys: heldKeys,
                                           now: now)
    }

    @discardableResult
    static func reconcileBooked(_ prospects: [Prospect], bookings: [OvertureBooking], now: Date) -> Int {
        let canonicalBookingRows = prospects.sorted(by: byNaturalKey)
        return DownbeatBooking.reconcileBooked(prospects: canonicalBookingRows, clients: [], bookings: bookings,
                                               health: .ok, now: now)
    }

    // MARK: the tie class, for the one dependence a sort cannot reach

    // Every contact the production rule could legitimately have picked as a show's representative:
    // every REPLIED live contact when anybody replied, else every live contact at the minimum `next`.
    // `ReachedOutQueue.activeWithDates` picks the first of these in `p.recipients` order, so a patched
    // value is correct when its pick is a MEMBER of this class, whatever the relationship order was.
    static func reachedOutTieClass(of p: Prospect, now: Date) -> [Recipient] {
        let live = p.recipients.compactMap { r -> (recipient: Recipient, next: Date)? in
            ReachedOutQueue.nextReachOut(for: r, of: p, now: now).map { (recipient: r, next: $0) }
        }
        let replied = live.filter { $0.recipient.replied }
        if !replied.isEmpty { return replied.map(\.recipient) }
        guard let soonest = live.map(\.next).min() else { return [] }
        return live.filter { $0.next == soonest }.map(\.recipient)
    }

    // MARK: permutations

    // `count` orders of `items`, drawn from a generator seeded by the caller and never by the system
    // (L339), so a failure names a seed that reproduces it.
    static func permutations<T>(_ items: [T], count: Int = 100, seed: UInt64) -> [[T]] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { _ in items.shuffled(using: &generator) }
    }

    static func indexPermutations(of size: Int, count: Int = 100, seed: UInt64) -> [[Int]] {
        permutations(Array(0..<size), count: count, seed: seed)
    }
}

// SplitMix64: small, fast, and the same sequence on every run and every machine for a given seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// Each term's output flattened to one string, so "how many distinct answers did 100 orders give" is a
// Set count. Dictionaries are written in sorted key order, so the rendering itself adds no order.
enum OracleRendering {
    static func keyed(_ table: [String: [String]]) -> String {
        table.keys.sorted().map { "\($0)=[\(table[$0]!.joined(separator: ","))]" }.joined(separator: ";")
    }

    static func collapse(_ value: (fronts: [String: [String]], hidden: Set<String>)) -> String {
        keyed(value.fronts) + " hidden=" + value.hidden.sorted().joined(separator: ",")
    }

    static func keys(_ rows: [Prospect]) -> String {
        rows.map(\.naturalKey).joined(separator: ",")
    }

    static func reachedOut(_ rows: [(prospect: Prospect, recipient: Recipient, next: Date)]) -> String {
        rows.map { "\($0.prospect.naturalKey)/\($0.recipient.id)/\($0.next.timeIntervalSince1970)" }
            .joined(separator: ",")
    }

    static func engagement(_ table: [String: [EngagementLink.Member]]) -> String {
        table.keys.sorted().map { key in
            "\(key)=[\(table[key]!.map { "\($0.venue ?? "")@\($0.date)" }.joined(separator: ","))]"
        }.joined(separator: ";")
    }

    static func feedBreaks(_ events: [FeedBreakEvent.Event]) -> String {
        events.map {
            "\($0.venue)|\($0.missedScoutCount)|\($0.memberKeys.joined(separator: ","))|\($0.coveredByAnotherCard)"
        }.joined(separator: ";")
    }

    static func inherited(_ table: [String: OrgAnswerLedger.Inherited]) -> String {
        table.keys.sorted().map { key in
            let one = table[key]!
            return "\(key)=\(one.organisation)|\(one.result.rawValue)|\(one.probedAt.timeIntervalSince1970)"
                + "|\(one.emails.joined(separator: ","))"
        }.joined(separator: ";")
    }

    static func booked(_ rows: [Prospect]) -> String {
        rows.sorted(by: CanonicalOracle.byNaturalKey)
            .map { "\($0.naturalKey):\($0.outcome == .booked ? "booked" : "")\($0.bookingSuggested ? "suggested" : "")" }
            .joined(separator: ",")
    }
}
