import Foundation

// Bridges stored prospects into OutcomeStats samples for the patterns view (#42): pick a
// dimension to group by, and each prospect becomes a sample carrying whether it was
// contacted and how it turned out. The tallying/rates live in OutcomeStats (tested).
enum OutcomePatterns {
    enum Dimension: String, CaseIterable, Sendable {
        case production, discipline, tier, coverage, profile, venue

        var label: String {
            switch self {
            case .production: return "Production"
            case .discipline: return "Discipline"
            case .tier: return "Fit tier"
            case .coverage: return "Coverage"
            case .profile: return "Profile"
            case .venue: return "Venue"
            }
        }
    }

    // The display rows: a tally per dimension value, only where something was contacted
    // (no 0/0 noise), ranked by bookings then volume. The view just renders these.
    static func rankedTallies(from prospects: [Prospect], by dimension: Dimension) -> [(name: String, tally: OutcomeTally)] {
        OutcomeStats.tallyByDimension(samples(from: prospects, by: dimension))
            .filter { $0.value.contacted > 0 }
            .sorted { ($0.value.booked, $0.value.contacted) > ($1.value.booked, $1.value.contacted) }
            .map { (name: $0.key, tally: $0.value) }
    }

    // Below this many contacted prospects a rate is noise (1 of 1 = 100% reads as a strong
    // signal but isn't), so the view marks the group "too few to tell" instead (#64).
    static let lowSampleThreshold = 4
    static func isLowSample(_ tally: OutcomeTally) -> Bool { tally.contacted < lowSampleThreshold }

    // #885: the two lines Dan reads on this screen, and the rule that suppresses half of one of them.
    //
    // These are statistical claims he is invited to ACT on (pitch more of this discipline, drop that
    // one), and they were assembled in the view body: the low-sample suppression as a ternary, the
    // percentage by a view-private formatter, and "replied" as a bare bit of arithmetic.
    //
    // Below the threshold the percentage is hidden entirely, because a booking rate over two shows is
    // noise wearing the costume of a number, and a number is what he would believe.
    static func bookedLine(_ tally: OutcomeTally) -> String {
        let base = "\(tally.booked) booked of \(tally.contacted)"
        return isLowSample(tally) ? base : base + percentSuffix(tally.bookingRate)
    }

    // "Replied" includes the ones who went on to BOOK: somebody who booked certainly replied. That rule
    // was arithmetic in a view, and it is the difference between an honest response rate and one that
    // silently undercounts every success.
    static func repliedLine(_ tally: OutcomeTally) -> String {
        "\(tally.replied + tally.booked) replied" + percentSuffix(tally.responseRate)
    }

    static func percentSuffix(_ rate: Double?) -> String {
        guard let rate else { return "" }
        return " · \(Int((rate * 100).rounded()))%"
    }

    // The dimension values are short slugs ("self", "agency", "music", "high"); a readable cap is enough.
    static func slugLabel(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func samples(from prospects: [Prospect], by dimension: Dimension) -> [OutcomeSample] {
        prospects.map { p in
            // Phase F: with the A3 rollup gone, a reply lives on the contact, not the lead outcome.
            // Count an otherwise-unresolved lead as replied when a contact wrote back.
            // #2226: booked FIRST, and asked of the show rather than of its `outcome` field. The only
            // way Dan can record a booking by hand is the Mark… menu, which writes the CONTACT, so the
            // show's own outcome stayed `noResponse` with a reply on a contact and the line below turned
            // every hand-recorded booking into a reply. That is every booking there has been, inside the
            // report whose headline number is the booking rate.
            let effectiveOutcome: Outcome = p.isBooked ? .booked
                : (p.outcome == .noResponse && p.recipients.contains(where: \.replied)) ? .replied : p.outcome
            return OutcomeSample(wasContacted: p.wasProvablyContacted, outcome: effectiveOutcome,
                                 dimension: dimensionValue(of: p, by: dimension),
                                 // And the source from wherever the booking was recorded, or the auto and
                                 // manual halves stop summing to the total they split.
                                 outcomeSource: p.isBooked ? p.bookingSource
                                     : p.outcomeSourceRaw.flatMap(OutcomeSource.init),
                                 // #2399: the ending itself, from the one field. This is what the three
                                 // groups are counted from, and it is why the lost count is no longer
                                 // structurally zero: it used to be read off `Outcome.lostSoft`/`.lostHard`,
                                 // which nothing in the app has ever written (#2401).
                                 //
                                 // A booking detected from Downbeat writes the legacy outcome without
                                 // touching the one field, so `isBooked` is folded in here rather than left
                                 // to a second reader: a show booked automatically must count as booked.
                                 showOutcome: p.isBooked ? .booked : p.showOutcome,
                                 aContactReplied: p.recipients.contains(where: \.replied))
        }
    }

    private static func dimensionValue(of p: Prospect, by dimension: Dimension) -> String {
        switch dimension {
        case .production: return p.production
        case .discipline: return p.discipline
        // #1670: the tier the pitch actually went out under. The live tier can move after the send (a
        // genre correction, a performer match, a contact check from #1648), and grouping by it would
        // bucket a show under a tier it did not have when Dan pitched it, silently mixing two scoring
        // bases in one report. Falls back to the live tier for a row that has never been sent, which is
        // the only case where nothing was frozen.
        case .tier: return p.tierAtSend ?? p.tier
        case .coverage: return p.coverage
        case .profile: return p.profile
        case .venue: return p.venue ?? "No venue"
        }
    }

    // One auto-detected booking behind a segment's "auto-detected" count (#212), so Dan can
    // open the count and audit which Downbeat matches were booked on his behalf.
    struct AutoBookedBooking: Equatable, Identifiable {
        let groupName: String
        let performanceDate: String?
        let venue: String?
        var id: String { "\(groupName)|\(performanceDate ?? "")|\(venue ?? "")" }
    }

    // The auto-detected bookings for one dimension value, oldest performance first. Only
    // outcome == booked with an auto source counts; manual confirmations and other segments
    // are excluded, matching the count shown in the patterns row.
    static func autoBookedBookings(from prospects: [Prospect], by dimension: Dimension,
                                   value: String) -> [AutoBookedBooking] {
        prospects
            .filter {
                $0.outcome == .booked
                    && $0.outcomeSourceRaw == OutcomeSource.auto.rawValue
                    && dimensionValue(of: $0, by: dimension) == value
            }
            .sorted { ($0.performanceDate ?? "") < ($1.performanceDate ?? "") }
            .map { AutoBookedBooking(groupName: $0.groupName, performanceDate: $0.performanceDate,
                                     venue: $0.venue) }
    }
}

// #885 (guard sweep): the booking split's two lines. "Auto-detected" versus "confirmed by you" is a
// provenance claim about where a booking came from (#117), and Dan audits it by clicking through.
extension OutcomePatterns {
    static func autoDetectedLine(_ tally: OutcomeTally) -> String { "\(tally.bookedAuto) auto-detected" }

    static func confirmedByYouLine(_ tally: OutcomeTally) -> String { "\(tally.bookedManual) confirmed by you" }
}
