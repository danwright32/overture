import Testing

// #92: after the relationship weights jumped, "high" can fill with warm orgs regardless of the
// event. This readout splits high-tier items by what lifted them — a prior relationship vs the
// event's own merit — so Dan can see, on a real queue, whether high is over-filled.
@Suite("Queue priority breakdown")
struct QueuePriorityBreakdownTests {
    private func item(prior: String = "none", production: String = "unknown", profile: String = "neutral",
                      coverage: String = "unknown", discipline: String = "music",
                      passedOnThisShow: Bool = false,
                      tier: String, fitScore: Int) -> QueueItem {
        QueueItem(id: "k", groupName: "G", discipline: discipline, venue: nil, performanceDate: nil,
                  sourceListingURL: nil, websiteURL: nil, priorRelationship: prior, production: production,
                  profile: profile, coverage: coverage, passedOnThisShow: passedOnThisShow,
                  fitScore: fitScore, tier: tier, fitReason: "r",
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

    // #1669 / #1648 Phase A2: the merit split hand-built its Candidate and forgot the passed-on
    // penalty, so a show Dan already turned down was measured as if he never had. Here the event's own
    // axes come to 9 (self 2 + strong 2 + uncovered 2 + dance 3), which clears the high cutoff of 5,
    // but Dan passed on it, and -5 puts real merit at 4. Only the warm relationship is holding it in
    // high, so it belongs on the relationship side of the split.
    @Test func aShowDanPassedOnDoesNotCountAsStandingOnItsOwnMerit() {
        let passed = item(prior: "warm", production: "self", profile: "strong",
                          coverage: "likely_uncovered", discipline: "dance", passedOnThisShow: true,
                          tier: "high", fitScore: 14)
        let c = QueuePriorityBreakdown.summarize([passed])
        #expect(c.high == 1)
        #expect(c.relationshipDriven == 1)
        #expect(c.meritDriven == 0)
    }

    @Test func emptyQueueIsAllZeros() {
        #expect(QueuePriorityBreakdown.summarize([]) == QueuePriorityBreakdown.Counts())
    }

    // #335: the masthead breakdown must read as a decomposition of the high-fit count, not a
    // separate total. The label leads with "Of the N high-fit:" so the two numbers visibly sum to N.
    @Test func highFitBreakdownLabelTiesToTheHighFitCount() {
        let c = QueuePriorityBreakdown.Counts(high: 10, relationshipDriven: 2, meritDriven: 8, longshot: 5)
        #expect(c.highFitBreakdownLabel() == "Of the 10 high-fit: 2 from a prior relationship, 8 on event merit")
    }

    @Test func highFitBreakdownLabelIsNilWhenNoHighFit() {
        #expect(QueuePriorityBreakdown.Counts(high: 0).highFitBreakdownLabel() == nil)
    }
}
