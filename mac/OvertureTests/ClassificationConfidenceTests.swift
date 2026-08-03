import Testing
import Foundation

// #60: classificationOverriddenByDan is mapped through from the Prospect into QueueItem
// so the row can hide the stale fit-reason line once Dan has corrected the classification.
@Suite("QueueItem override flag mapping")
struct QueueItemOverrideFlagTests {
    private func makeProspect(overridden: Bool = false) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: nil,
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.classificationOverriddenByDan = overridden
        return p
    }

    @Test func flagFalseByDefault() {
        #expect(QueueItem(makeProspect()).classificationOverriddenByDan == false)
    }

    @Test func flagTrueWhenProspectIsOverridden() {
        #expect(QueueItem(makeProspect(overridden: true)).classificationOverriddenByDan == true)
    }
}

// #114: bookingSuggested and isAutoBooked are mapped from the Prospect so the queue
// can surface a "confirm this booking?" banner without touching SwiftData from the view layer.
@Suite("QueueItem booking suggestion mapping")
struct QueueItemBookingSuggestionTests {
    private func makeProspect(bookingSuggested: Bool = false,
                              outcome: Outcome = .noResponse,
                              outcomeSource: OutcomeSource? = nil) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: nil,
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.bookingSuggested = bookingSuggested
        p.outcome = outcome
        p.outcomeSourceRaw = outcomeSource?.rawValue
        return p
    }

    @Test func bookingSuggestedFalseByDefault() {
        #expect(QueueItem(makeProspect()).bookingSuggested == false)
    }

    @Test func bookingSuggestedTrueWhenProspectFlagsIt() {
        #expect(QueueItem(makeProspect(bookingSuggested: true)).bookingSuggested == true)
    }

    @Test func isAutoBookedTrueOnlyForBookedPlusAuto() {
        #expect(QueueItem(makeProspect(outcome: .booked, outcomeSource: .auto)).isAutoBooked == true)
    }

    @Test func isAutoBookedFalseForBookedManual() {
        #expect(QueueItem(makeProspect(outcome: .booked, outcomeSource: .manual)).isAutoBooked == false)
    }

    @Test func isAutoBookedFalseForNonBookedAuto() {
        #expect(QueueItem(makeProspect(outcome: .replied, outcomeSource: .auto)).isAutoBooked == false)
    }
}

// #114: pendingBookingCount counts only items where bookingSuggested is true.
@Suite("QueueModel pending booking count")
struct PendingBookingCountTests {
    private func item(bookingSuggested: Bool) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "G", discipline: "music", venue: nil,
                          performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "self", profile: "neutral",
                          coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .new)
        i.bookingSuggested = bookingSuggested
        return i
    }

    @Test func zeroWhenNoneSuggested() {
        #expect(QueueModel.pendingBookingCount([item(bookingSuggested: false), item(bookingSuggested: false)]) == 0)
    }

    @Test func countsOnlySuggestedItems() {
        let items = [item(bookingSuggested: true), item(bookingSuggested: false), item(bookingSuggested: true)]
        #expect(QueueModel.pendingBookingCount(items) == 2)
    }

    @Test func zeroForEmptyList() {
        #expect(QueueModel.pendingBookingCount([]) == 0)
    }
}
