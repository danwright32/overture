import Testing
import Foundation

private func item(status: ReviewStatus = .new, performanceStatus: PerformanceStatus = .new,
                  showOutcome: ShowOutcome? = nil, key: String = "k") -> QueueItem {
    var q = QueueItem(
        id: key, groupName: "Test Group", discipline: "music", venue: "Weill Recital Hall",
        performanceDate: "2026-07-01", sourceListingURL: nil,
        priorRelationship: "none", production: "self", profile: "neutral",
        coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "reason",
        matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status
    )
    q.performanceStatus = performanceStatus
    q.showOutcome = showOutcome
    return q
}

@Suite("ArchiveStatus")
struct ArchiveStatusTests {
    @Test func dismissedTakesPrecedenceOverPerformanceStatus() {
        // A prospect cut at triage is always performanceStatus .new (never contacted), but Archive
        // must bucket it as Dismissed, not New, so it is hidden by the New+Active default filter.
        let i = item(status: .dismissed, performanceStatus: .new)
        #expect(ArchiveStatus.of(i) == .dismissed)
    }

    // Precedence must hold regardless of performanceStatus, not only when it happens to be .new
    // (the case a scout-cut prospect always carries). Pairing .dismissed with .active and .booked
    // rules out an implementation that only special cases dismissed alongside .new.
    @Test func dismissedTakesPrecedenceEvenWithNonNewPerformanceStatus() {
        #expect(ArchiveStatus.of(item(status: .dismissed, performanceStatus: .active)) == .dismissed)
        #expect(ArchiveStatus.of(item(status: .dismissed, performanceStatus: .booked)) == .dismissed)
    }

    @Test func nonDismissedMapsDirectlyFromPerformanceStatus() {
        #expect(ArchiveStatus.of(item(status: .new, performanceStatus: .new)) == .show(.new))
        #expect(ArchiveStatus.of(item(status: .contacted, performanceStatus: .active)) == .show(.active))
        #expect(ArchiveStatus.of(item(status: .contacted, performanceStatus: .lostDoorOpen)) == .show(.lostDoorOpen))
        #expect(ArchiveStatus.of(item(status: .contacted, performanceStatus: .lostNotInterested)) == .show(.lostNotInterested))
        #expect(ArchiveStatus.of(item(status: .contacted, performanceStatus: .stoodDown)) == .show(.stoodDown))
        #expect(ArchiveStatus.of(item(status: .contacted, performanceStatus: .booked)) == .show(.booked))
    }

    // MARK: the two vocabularies stay in step (#1841)

    // Archive's buckets and PerformanceStatus's outcomes are one vocabulary, not two lists kept in
    // step by hand. Today the exhaustive switch in `of(_:)` is the only thing holding them together,
    // and it stops holding the moment anybody writes a `default:` to make a compile error go away:
    // the new status then lands silently in whichever bucket the default names, and every show in it
    // becomes unfindable behind a chip that says something else. Named per status so a failure says
    // WHICH one collided rather than only that a count was wrong.
    @Test func everyPerformanceStatusGetsItsOwnArchiveBucket() {
        var bucketOwner: [ArchiveStatus: PerformanceStatus] = [:]
        for status in PerformanceStatus.allCases {
            let bucket = ArchiveStatus.of(item(status: .contacted, performanceStatus: status))
            #expect(ArchiveStatus.allCases.contains(bucket),
                    "show status \(status) maps to \(bucket), which is not an Archive chip")
            if let owner = bucketOwner[bucket] {
                Issue.record("""
                    show statuses \(status) and \(owner) both land in Archive bucket \(bucket). \
                    Every show status needs its own bucket, or one of them is unfindable behind a \
                    chip naming the other.
                    """)
            }
            bucketOwner[bucket] = status
        }
        #expect(bucketOwner.count == PerformanceStatus.allCases.count)
    }

    // The other direction: a chip nothing can ever land in. It offers Dan a filter that always
    // returns nothing, and an empty list reads as "no such shows" rather than as a dead control.
    // Every ArchiveStatus must be produced by SOME item, so the chips and the buckets agree both ways.
    @Test func everyArchiveBucketIsReachable() {
        var reachable = Set(PerformanceStatus.allCases.map {
            ArchiveStatus.of(item(status: .contacted, performanceStatus: $0))
        })
        reachable.insert(ArchiveStatus.of(item(status: .dismissed, performanceStatus: .new)))
        reachable.insert(ArchiveStatus.of(item(status: .dismissed, performanceStatus: .new,
                                               showOutcome: .wentBy)))
        let unreachable = Set(ArchiveStatus.allCases).subtracting(reachable)
        #expect(unreachable.isEmpty,
                "Archive chips no show can ever land in: \(unreachable.map(\.label).sorted())")
    }

    // Each bucket's label is the words on its chip, so two chips wearing one sentence would read as
    // the same filter twice (#843). Checked over the whole list rather than the handful spelled out
    // below, so a status added later cannot arrive unlabelled or borrow another's words.
    @Test func everyArchiveBucketHasItsOwnWords() {
        let labels = ArchiveStatus.allCases.map(\.label)
        #expect(Set(labels).count == labels.count, "two Archive chips share a label: \(labels)")
        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    @Test func labelsAreDistinctPlainLanguage() {
        #expect(ArchiveStatus.show(.lostDoorOpen).label == "Closed (not now)")
        #expect(ArchiveStatus.show(.lostNotInterested).label == "Closed (not interested)")
        #expect(ArchiveStatus.dismissed.label == "Dismissed")
        // The chip keeps its own shorter words rather than the card's sentence, which is the one place
        // the two vocabularies deliberately differ, so nothing Dan reads moved with #1841.
        #expect(ArchiveStatus.show(.stoodDown).label == "Stopped working")
        #expect(PerformanceStatus.stoodDown.label == "Stopped working this")
    }

    // #1841: the chips are one list now, and the show half of it is PerformanceStatus's own, in
    // PerformanceStatus's own order. Pinned as the whole list because the order is what Dan reads
    // along the filter bar, and a derived list is exactly where an accidental reordering would hide.
    @Test func archiveChipsAreTheShowStatusesPlusOverturesOwnTwo() {
        #expect(ArchiveStatus.allCases == PerformanceStatus.allCases.map(ArchiveStatus.show)
                + [.dismissed, .wentBy])
        #expect(ArchiveStatus.allCases.map(\.label)
                == ["New", "Active", "Closed (not now)", "Closed (not interested)",
                    "Stopped working", "Booked", "Dismissed", "Went by"])
    }
}
