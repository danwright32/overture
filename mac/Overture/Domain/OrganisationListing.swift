import Foundation

// #1776 (milestone 34): what Overture decided about each organisation, and why, in ONE derivation.
//
// The gate already reaches these verdicts, but it answers each question separately and none of its
// answers says WHY. #1731 needs the why on screen ("the only visible trace is a name quietly NOT
// appearing, which is indistinguishable from a bug"), and #1729 needs the organisations most likely to
// be judged wrong ranked so Dan can settle them in seconds. Writing either at the surfacing layer would
// be a second copy of a judgment #1702 exists to keep single, so both read this.
//
// Pure and store-free, on the OrgAnswerLedger precedent: every rule here decides what Dan is charged or
// what a card claims, and neither may live in a SwiftUI body where no test can reach it (#863).
enum OrganisationListing {

    // A prospect, as this derivation needs it. The title comes along because the DISTINCT SHOW count is
    // evidence Dan reads, not merely a number: many different titles in one room reads as a rented room,
    // one title over many dates reads as a company in its own house.
    struct Show: Equatable, Sendable {
        let presenter: String?
        let venue: String?
        let title: String
    }

    // What the gate decided, in Dan's vocabulary rather than the gate's. "Presenter" is his word and the
    // app's own field name; "producer" is internal and is not his problem (#1719).
    enum Verdict: Equatable, Sendable {
        // The building's own brand. Its addresses are refused and its name is not drawn on a card.
        case theBuilding
        // A producer: one paid answer may stand for every show it presents.
        case sharesOneAnswer
        // Neither. Every show it presents is researched, and paid for, on its own.
        case paidForSeparately
    }

    // Why an organisation is judged the building. Only ever set on `.theBuilding`, and deliberately
    // limited to what the presenter arms can actually say. A fourth reason ("a parent building") was
    // considered and dropped: it belongs to ProducerGate.houses and is unreachable from these arms, so
    // stating it here would mean inventing a judgment rather than reporting one.
    enum Reason: Equatable, Sendable {
        // Promotion can never reach this one: the presenter field literally holds a room's name (#1763).
        case spelledExactlyLikeARoom
        // A name overlap with a room. Promotion does reach this one.
        case namedInsideARoom
        // Dan said so. Named apart from the two above because a verdict he set is his to revisit and one
        // a rule reached is a rule doing its job, and the two invite different responses (#1719).
        case yourOwnCorrection
    }

    struct Entry: Equatable, Sendable, Identifiable {
        // The gate's own folded key, which is also what a correction is stored under.
        let key: String
        // One readable spelling, as a page wrote it.
        let name: String
        let verdict: Verdict
        let reason: Reason?
        let standing: ProducerOverrideEditing.Standing
        // The evidence, which is what #1729 puts in front of Dan rather than a verdict of its own.
        let rowCount: Int
        let distinctShowCount: Int
        let distinctVenueCount: Int

        var id: String { key }

        // Whether a correction offered here could actually move the verdict. False exactly where the name
        // is spelled like a room and Dan has not already corrected it, because the gate tests that arm
        // before it reads any override, so a correction would be stored and then ignored (#1763).
        var isCorrectable: Bool {
            if standing != .none { return true }
            return reason != .spelledExactlyLikeARoom
        }
    }

    // Every organisation in the corpus, sorted by the rows it covers so the ones worth the most attention
    // read first. Built ONCE per render beside VenueBrands, never per row: deciding this walks every
    // presenter against every venue spelling in the store (roughly 156 by 140 on Dan's), which is a cost
    // a card must not pay while it is being drawn (#1687, #1121).
    static func build(shows: [Show], overrides: ProducerOverrides = .none) -> [Entry] {
        let gateShows = shows.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) }
        let venueKeys = ProducerGate.venueKeys(of: gateShows)

        var byKey: [String: [Show]] = [:]
        var nameForKey: [String: String] = [:]
        for show in shows {
            guard let presenter = show.presenter, let key = ProducerGate.key(presenter) else { continue }
            byKey[key, default: []].append(show)
            if nameForKey[key] == nil { nameForKey[key] = presenter }
        }

        return byKey.map { key, members in
            let name = nameForKey[key] ?? key
            let standing: ProducerOverrideEditing.Standing =
                overrides.demoted.contains(key) ? .demoted
                : overrides.promoted.contains(key) ? .promoted
                : .none

            let isBrand = ProducerGate.isVenueBrand(key, venueKeys: venueKeys, overrides: overrides)
            let verdict: Verdict = isBrand ? .theBuilding
                : ProducerGate.qualifies(name, among: gateShows, overrides: overrides) ? .sharesOneAnswer
                : .paidForSeparately

            // Asked in the order the gate itself asks them, so the reason named is the one that actually
            // fired. Equality first, because that is the arm the gate tests before it reads an override.
            var reason: Reason? = nil
            if isBrand {
                if venueKeys.contains(key) { reason = .spelledExactlyLikeARoom }
                else if standing == .demoted { reason = .yourOwnCorrection }
                else { reason = .namedInsideARoom }
            }

            return Entry(key: key, name: name, verdict: verdict, reason: reason, standing: standing,
                         rowCount: members.count,
                         distinctShowCount: Set(members.map(\.title)).count,
                         distinctVenueCount: Set(members.compactMap { ProducerGate.key($0.venue) }).count)
        }
        .sorted { ($0.rowCount, $1.name) > ($1.rowCount, $0.name) }
    }

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="organisations the gate refuses that are not a venue brand, ranked by the rows they cover"
    // #1729: the organisations most likely to have been judged wrong, which Dan can settle in seconds if
    // he is shown them. A SUGGESTION and never a classification: measured over the live store the top of
    // this list is FRIGID New York (27 rows, 25 distinct shows, a rented room) and The New York
    // Neo-Futurists (11 rows, 1 title, a company in its own house), but also DCINY and the Metropolitan
    // Opera, which are genuine producers Dan would wave away. That is the accepted cost.
    //
    // Ranked by ROWS, because rows are what a correction saves or protects, and because ranking by
    // distinct shows finds only the rented-room shape and is structurally blind to its mirror. The cutoff
    // is three rows: measured, the refused population runs 27, 11, 10, 7, 6, 4, 3 and then a cliff where
    // all 110 others carry one or two rows each, where a correction is worth nothing.
    static let shortlistMinimumRows = 3

    static func shortlist(shows: [Show], overrides: ProducerOverrides = .none) -> [Entry] {
        build(shows: shows, overrides: overrides).filter {
            $0.verdict == .paidForSeparately
                && $0.standing == .none
                && $0.rowCount >= shortlistMinimumRows
        }
    }
}
