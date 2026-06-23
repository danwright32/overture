import Testing
@testable import Overture

// #32: rules-uncertain classifications should show an "unsure" mark so Dan can double
// check the guesses, and the mark clears once he has reviewed it.
@Suite("Classification confidence")
struct ClassificationConfidenceTests {
    private func item(confidence: String, reviewed: Bool) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "G", discipline: "music", venue: nil,
                          performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "self", profile: "neutral",
                          coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .new)
        i.classificationConfidence = confidence
        i.confidenceReviewedByDan = reviewed
        return i
    }

    @Test func uncertainAndUnreviewedShowsTheMark() {
        #expect(item(confidence: "uncertain", reviewed: false).isClassificationUncertain == true)
    }

    @Test func confidentIsNeverMarked() {
        #expect(item(confidence: "confident", reviewed: false).isClassificationUncertain == false)
    }

    @Test func dansReviewClearsTheMark() {
        #expect(item(confidence: "uncertain", reviewed: true).isClassificationUncertain == false)
    }
}
