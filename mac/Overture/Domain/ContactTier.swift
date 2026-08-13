import Foundation

// #2622: WHO the check found, which until now every found email scored the same.
//
// The card for Pier Lamia Porter at The Green Room 42 read "Unverified email found" over
// jasonwetzelmusic@gmail.com. Jason Wetzel is her musical director. An address for the person whose show
// it is, an address for somebody performing on it, and an address for that person's manager are three
// different findings, and Overture recorded one.
//
// Dan's definition, 2026-08-13, chosen over billing order deliberately, because the billed name and the
// person who books the photographer are routinely different people and it is the second one the score
// should care about:
//
//   primary    whoever owns the show and could actually hire Dan. A self-producing headliner, or the
//              producing organisation's producer or artistic director.
//   secondary  somebody on the show without that authority. A co-performer, a music director, a guest.
//   tertiary   a third party representing them. A manager, an agent, a publicist, a booking agency.
//
// The RUN writes it, judged from the page it read, and it is deliberately NOT derived in Swift from the
// stored `role` string: that is an unbounded free-text vocabulary, and no pattern match can tell a music
// director who also produces the night from one who was hired for it. The accepted cost of that choice is
// that the tier only reaches shows checked AFTER it ships; every contact already in the store reads as
// unknown, which is left honest rather than filled by a second definition of the rule (the issue's open
// question 4).
enum ContactTier: String, Codable, Sendable, CaseIterable {
    case primary
    case secondary
    case tertiary

    // Highest first, so "the best tier found" is a max over this.
    var rank: Int {
        switch self {
        case .primary: return 3
        case .secondary: return 2
        case .tertiary: return 1
        }
    }

    // #2622 open question 5, answered in the type: an UNKNOWN tier is `nil`, and it is not a fourth case.
    // A contact found before this shipped and a contact whose tier the run declined to judge are the same
    // thing (nobody has said who this is), and both are a different thing from a show no check has ever
    // looked at, which the row's own `reachabilityResult` says and this never speaks to.
    static func best(of tiers: [ContactTier?]) -> ContactTier? {
        tiers.compactMap { $0 }.max { $0.rank < $1.rank }
    }
}
