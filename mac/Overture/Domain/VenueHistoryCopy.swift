import Foundation

// #1887: the line the review card shows Dan about a room he has already shot.
//
// WHY A SURFACE EXISTS AT ALL. This feature asserts a fact about Dan, in Dan's name, to a stranger,
// derived from an eight-year-old calendar through a chain of name folding. Without something on
// screen, a folding error and the truth look identical to him, and there is no other moment where a
// wrong band could ever be noticed. So the card states BOTH halves: the claim the email will make,
// and the dates it rests on.
//
// The dates are the point. The band alone would just be the same assertion again in a different
// font (#843's duplicate-copy trap); the dates are what he can actually check against his own
// memory of the room.
enum VenueHistoryCopy {

    // How many dates to name before summarising the rest. Three is enough to recognise a room
    // without turning a card into a list.
    static let datesShown = 3

    static func claim(for band: VenueShootHistory.Band) -> String {
        switch band {
        case .shotBefore: return "you've photographed here before"
        case .aFew: return "you've photographed a few shows here"
        case .regularly: return "you shoot here regularly"
        }
    }

    // Nil when there is nothing to show, which includes a Carnegie show: `VenueShootHistory` returns
    // no band there deliberately, so the card stays silent exactly where the email does.
    static func line(band: VenueShootHistory.Band?, shoots: [VenueShootHistory.Shoot]) -> String? {
        guard let band else { return nil }

        let labels = shoots.map { shoot -> String in
            guard let label = EasternDate.dayLabel(shoot.date) else { return shoot.date }
            return "\(label) \(String(shoot.date.prefix(4)))"
        }
        // A band with no dates behind it should never happen (the band is derived from them), but if
        // it ever did, saying the claim with no evidence is worse than saying nothing: the whole
        // point of this line is that Dan can check it.
        guard !labels.isEmpty else { return nil }

        let shown = labels.suffix(datesShown).reversed()
        let hidden = labels.count - min(labels.count, datesShown)
        let dates = hidden > 0
            ? "\(shown.joined(separator: ", ")) and \(hidden) more"
            : shown.joined(separator: ", ")
        return "Pitch will say \(claim(for: band)): \(dates)"
    }
}
