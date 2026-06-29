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

    static func samples(from prospects: [Prospect], by dimension: Dimension) -> [OutcomeSample] {
        prospects.map { p in
            // Phase F: with the A3 rollup gone, a reply lives on the contact, not the lead outcome.
            // Count an otherwise-unresolved lead as replied when a contact wrote back.
            let effectiveOutcome: Outcome =
                (p.outcome == .noResponse && p.recipients.contains(where: \.replied)) ? .replied : p.outcome
            return OutcomeSample(wasContacted: p.wasContacted, outcome: effectiveOutcome,
                                 dimension: dimensionValue(of: p, by: dimension),
                                 outcomeSource: p.outcomeSourceRaw.flatMap(OutcomeSource.init))
        }
    }

    private static func dimensionValue(of p: Prospect, by dimension: Dimension) -> String {
        switch dimension {
        case .production: return p.production
        case .discipline: return p.discipline
        case .tier: return p.tier
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
