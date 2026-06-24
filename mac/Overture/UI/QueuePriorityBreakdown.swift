import Foundation

// #92 diagnostic: with relationship weights now dominant (warm +10, declined +18, booked +20),
// a prior relationship can clear high tier regardless of the event. This splits the high-tier
// queue by what lifted each item — a relationship vs the event's own merit — so the masthead
// can show whether "high" is over-filled with warm orgs (the cue to recalibrate, with data).
enum QueuePriorityBreakdown {
    struct Counts: Equatable {
        var high = 0
        var relationshipDriven = 0   // high only because of the prior relationship
        var meritDriven = 0          // the event clears high on its own
        var longshot = 0
    }

    static func summarize(_ items: [QueueItem]) -> Counts {
        var c = Counts()
        for item in items {
            if item.tier == "high" {
                c.high += 1
                if standsOnMerit(item) { c.meritDriven += 1 } else { c.relationshipDriven += 1 }
            } else {
                c.longshot += 1
            }
        }
        return c
    }

    // An item stands on the event's own merit if it still clears high tier with the prior
    // relationship removed; otherwise the relationship is what lifted it.
    private static func standsOnMerit(_ item: QueueItem) -> Bool {
        let candidate = Candidate(
            reachable: true,
            priorRelationship: .none,
            production: Production(rawValue: item.production) ?? .unknown,
            profile: Profile(rawValue: item.profile) ?? .neutral,
            coverage: Coverage(rawValue: item.coverage) ?? .unknown,
            discipline: Discipline(rawValue: item.discipline) ?? .other)
        return Ranker.scoreFit(candidate).tier == .high
    }
}
