import Foundation

// #2989: what the empty contact answers in the store are actually claiming.
//
// A check that comes home with nobody to write to records WHY, as one of nine reasons, and until now
// nothing counted them. Those reasons are not shades of one thing: `nothingPublished` asserts that this
// show's act, performers and presenter publish no address anywhere, which is a claim about searches that
// really ran, while `noOneIdentified` admits the run never worked out who to write to. Dan acts on them
// differently, and the difference between them is the difference between a finished search and an
// untested claim.
//
// #2983 is what the silence cost. Twelve of twenty three empty answers were wrong, and six of them
// claimed `nothingPublished` about an organisation whose name the run had never been given, so the
// strongest available claim was made about the weakest available search. It was found because Dan
// happened to look at one card, recognise the company, and open its website.
//
// THE CROSS-CUT IS THE POINT, not the table. A list of counts by reason is something nobody reads twice.
// What accuses is the one contradiction visible without opening a single card: a show whose check says
// nobody publishes an address, sitting beside the name of the producing organisation.
enum EmptyAnswerReport {

    struct Line: Equatable, Sendable {
        var reason: Reachability.EmptyReason
        var count: Int
    }

    struct Report: Equatable, Sendable {
        // Only the reasons something actually claims. A row per reason over a store with none would
        // state nine zeroes, and a zero whose only input is a value nothing wrote is indistinguishable
        // from a real measurement (L90).
        var byReason: [Line]
        var nothingPublishedWithAPresenter: Int
        var nothingPublishedWithNoPresenter: Int

        var total: Int { byReason.reduce(0) { $0 + $1.count } }
        func count(of reason: Reachability.EmptyReason) -> Int {
            byReason.first { $0.reason == reason }?.count ?? 0
        }
    }

    static func make(from prospects: [Prospect]) -> Report {
        var counts: [Reachability.EmptyReason: Int] = [:]
        var withPresenter = 0
        var withoutPresenter = 0
        for p in prospects {
            guard let reason = p.reachabilityEmptyReason else { continue }
            counts[reason, default: 0] += 1
            guard reason == .nothingPublished else { continue }
            if namesAnOrganisation(p.presenter) { withPresenter += 1 } else { withoutPresenter += 1 }
        }
        // Biggest first, and by raw value on a tie so the order is stable between reads rather than
        // reshuffling under a reader (the same rule the failure registers follow).
        let lines = counts
            .map { Line(reason: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.reason.rawValue) > ($1.count, $0.reason.rawValue) }
        return Report(byReason: lines,
                      nothingPublishedWithAPresenter: withPresenter,
                      nothingPublishedWithNoPresenter: withoutPresenter)
    }

    // A stored empty string is not a named organisation. Counting one as a presenter would make the
    // accusation be about nothing, which is the shape that gets a report ignored.
    private static func namesAnOrganisation(_ presenter: String?) -> Bool {
        !(presenter ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // What each reason CLAIMS, in Dan's terms rather than the stored value's. Exhaustive over the
    // vocabulary, so a reason added later breaks the build here and has to say what it claims, rather
    // than rendering as a raw string or as nothing at all (L113).
    static func label(for reason: Reachability.EmptyReason) -> String {
        switch reason {
        case .nothingPublished: return "Nobody on this show publishes an address"
        case .noOneIdentified: return "Couldn't work out who to write to"
        case .namedButNoRoute: return "Found the people, no way to reach any of them"
        case .onlyVenueContact: return "Only the room's own inbox"
        case .onlyPressContact: return "Only a press or PR desk"
        case .onlySocialProfile: return "Only a social profile, not opened"
        case .unconfirmedSocialProfile: return "Only a profile with the right name on it"
        case .routeNamedButNotSupplied: return "The check named a way in and gave none"
        }
    }

    // Said beside the cross-cut, never left to be inferred. Whether the run was TOLD the presenter's
    // name is recorded nowhere, so a show checked before #2983's fix and one checked after look
    // identical here. Without this line the number reads as an accusation about every row in it, which
    // would be wrong about the ones checked since, and a count that overstates gets ignored (L36).
    static let presenterCaveat = "Overture doesn't record whether a check was told the organisation's name, so this counts every show carrying one, not only the ones where the name went unsearched."
}
