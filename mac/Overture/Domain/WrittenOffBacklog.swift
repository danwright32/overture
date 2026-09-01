import Foundation

// Milestone 61 Phase 0.3. The reader for `Prospect.contradictionMarkedAt`.
//
// `ReachabilityVerdictRefresh` stamps every row it finds carrying a stored "no way in" over a route the
// row actually holds, and then repairs it. That stamp is the only surviving record the contradiction
// ever existed, because the repair is precisely what makes it unobservable (L277). This reads it back.
//
// One question, and it is one Dan can act on: which shows were written off as unreachable and turned out
// to hold a route all along. It is the honest accounting of what the paid checks got wrong, and it is
// the population Phase 5.2's second stratum measures over.
enum WrittenOffBacklog {

    struct Row: Equatable, Sendable, Identifiable {
        var id: String { naturalKey }

        var naturalKey: String
        var groupName: String
        var venue: String?
        var markedAt: Date
    }

    struct Report: Equatable, Sendable {
        var rows: [Row]

        var total: Int { rows.count }
    }

    static func make(from prospects: [Prospect]) -> Report {
        let rows = prospects.compactMap { p -> Row? in
            // The date IS the marker: there is no companion field, for the reason recorded on
            // `Prospect.contradictionMarkedAt`.
            guard let markedAt = p.contradictionMarkedAt else { return nil }
            return Row(naturalKey: p.naturalKey, groupName: p.groupName, venue: p.venue,
                       markedAt: markedAt)
        }
        // Newest first, then by natural key on a tie, so the list does not reshuffle under Dan between
        // reads. The same rule the other reports on this sheet follow.
        .sorted { ($0.markedAt, $1.naturalKey) > ($1.markedAt, $0.naturalKey) }
        return Report(rows: rows)
    }
}
