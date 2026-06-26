import Foundation

// Bridges stored prospects into OutcomeStats samples for the patterns view (#42): pick a
// dimension to group by, and each prospect becomes a sample carrying whether it was
// contacted and how it turned out. The tallying/rates live in OutcomeStats (tested).
enum OutcomePatterns {
    enum Dimension: String, CaseIterable, Sendable {
        case production, discipline, tier

        var label: String {
            switch self {
            case .production: return "Production"
            case .discipline: return "Discipline"
            case .tier: return "Fit tier"
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
            let dim: String
            switch dimension {
            case .production: dim = p.production
            case .discipline: dim = p.discipline
            case .tier: dim = p.tier
            }
            return OutcomeSample(wasContacted: p.wasContacted, outcome: p.outcome, dimension: dim,
                                 outcomeSource: p.outcomeSourceRaw.flatMap(OutcomeSource.init))
        }
    }
}
