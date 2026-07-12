import Testing
import Foundation
import SwiftData
@testable import Overture

// #803: CHECKED and READ are not the same thing, and until now the Sources sheet could not tell Dan
// which had happened.
//
// The free daily run fetches and hashes every calendar and reads none of them (his own decision). So a
// source can report "Watching, checked an hour ago" for weeks while nobody has ever actually looked at
// what is on it. That is not a bug, it is the design, but it is invisible, and invisible is how a
// calendar he is counting on goes months without being read while reporting as perfectly healthy.
//
// It is also what makes a page that changes on EVERY load visible. Such a page is re-read on every scout
// Dan runs, forever, and costs him tokens with nothing to show, and the only symptom is a source that is
// somehow never "unchanged".
@MainActor
@Suite("Checked is not the same as read (#803)")
struct SourceReadStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func hoursAgo(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 3600) }

    private func source(checked: Date? = nil, succeeded: Date? = nil,
                        unread: Bool = false, kind: SourceKind = .html) -> WatchedSource {
        let s = WatchedSource(sourceId: "org", orgName: "Org",
                              listingsURL: "https://org.example/events", kind: kind)
        s.lastCheckedAt = checked
        s.lastSucceededAt = succeeded
        s.hasUnreadChanges = unread
        return s
    }

    @Test func aCalendarNobodyHasEverReadSaysSo() {
        let s = source(checked: hoursAgo(1))   // fetched and hashed, never read
        #expect(SourceReadState.of(s) == .neverRead)
    }

    @Test func aCalendarWeHaveReadSaysWhen() {
        let s = source(checked: hoursAgo(1), succeeded: hoursAgo(72))
        #expect(SourceReadState.of(s) == .read(at: hoursAgo(72)))
    }

    // THE state this exists for. The daily run noticed new listings and did not spend a token reading
    // them, exactly as designed. Dan needs to see that they are WAITING, or the design becomes a leak:
    // shows sitting unread on a calendar that reports as healthy.
    @Test func newListingsWaitingToBeReadAreSaidOutLoud() {
        let s = source(checked: hoursAgo(1), succeeded: hoursAgo(72), unread: true)
        #expect(SourceReadState.of(s) == .unreadChangesWaiting(lastRead: hoursAgo(72)))
    }

    @Test func newListingsOnACalendarNeverReadAreAlsoWaiting() {
        let s = source(checked: hoursAgo(1), unread: true)
        #expect(SourceReadState.of(s) == .unreadChangesWaiting(lastRead: nil))
    }

    // Carnegie has no page to read: its shows arrive from a structured feed, natively, on every run.
    // Reporting it as "never read" would be a lie that Dan cannot act on.
    @Test func aNativeFeedIsNotJudgedOnWhetherItsPageWasRead() {
        let s = source(checked: hoursAgo(1), succeeded: hoursAgo(1), kind: .algolia)
        #expect(SourceReadState.of(s) == .read(at: hoursAgo(1)))
    }

    // MARK: - What Dan reads

    @Test func everyStateSaysWhatItIsInWords() {
        #expect(SourceReadState.neverRead.label.localizedCaseInsensitiveContains("read"))
        #expect(SourceReadState.unreadChangesWaiting(lastRead: nil).label
                    .localizedCaseInsensitiveContains("new"))
        #expect(SourceReadState.read(at: now).label(now: now).isEmpty == false)
    }

    // The waiting state is the one that needs Dan to DO something (run a scout), so it says so, and it
    // is the only one that does.
    @Test func onlyTheWaitingStateAsksDanForAnything() {
        #expect(SourceReadState.unreadChangesWaiting(lastRead: nil).needsAScout)
        #expect(SourceReadState.neverRead.needsAScout == false)
        #expect(SourceReadState.read(at: now).needsAScout == false)
    }
}
