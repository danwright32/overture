import Testing
@testable import Overture

// #92: after the relationship weights jumped, "high" can fill with warm orgs regardless of the
// event. This readout splits high-tier items by what lifted them — a prior relationship vs the
// event's own merit — so Dan can see, on a real queue, whether high is over-filled.
@Suite("Queue priority breakdown")
struct QueuePriorityBreakdownTests {
    private func item(prior: String = "none", production: String = "unknown", profile: String = "neutral",
                      coverage: String = "unknown", discipline: String = "music",
                      tier: String, fitScore: Int) -> QueueItem {
        QueueItem(id: "k", groupName: "G", discipline: discipline, venue: nil, performanceDate: nil,
                  sourceListingURL: nil, websiteURL: nil, priorRelationship: prior, production: production,
                  profile: profile, coverage: coverage, fitScore: fitScore, tier: tier, fitReason: "r",
                  matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
    }

    @Test func splitsHighTierByRelationshipVersusMerit() {
        let items = [
            // Warm relationship, mediocre event: would be longshot without the relationship.
            item(prior: "warm", tier: "high", fitScore: 10),
            // Cold, but a strong event that clears high on its own (self+strong+uncovered+dance = 9).
            item(prior: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                 discipline: "dance", tier: "high", fitScore: 9),
            // A longshot.
            item(prior: "none", production: "agency", profile: "weak", coverage: "likely_covered",
                 discipline: "music", tier: "longshot", fitScore: -6),
        ]
        let c = QueuePriorityBreakdown.summarize(items)
        #expect(c.high == 2)
        #expect(c.relationshipDriven == 1)
        #expect(c.meritDriven == 1)
        #expect(c.longshot == 1)
    }

    @Test func bookedClientWithAStrongEventCountsAsMeritDriven() {
        // Booked (+20) but the event also clears high on its own merit — it's not ONLY the
        // relationship lifting it.
        let item = item(prior: "booked", production: "self", profile: "strong",
                        coverage: "likely_uncovered", discipline: "dance", tier: "high", fitScore: 29)
        #expect(QueuePriorityBreakdown.summarize([item]).meritDriven == 1)
    }

    @Test func emptyQueueIsAllZeros() {
        #expect(QueuePriorityBreakdown.summarize([]) == QueuePriorityBreakdown.Counts())
    }
}
