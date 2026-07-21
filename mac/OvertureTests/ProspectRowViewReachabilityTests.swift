import Testing
import SwiftUI
import ViewInspector
@testable import Overture

// #1145 Layer 1: the "Hard to reach" badge on a Review row. It renders only when the free heuristic flags
// a known-dead case (social-only source, or no presenting org), and only while the show is still a
// candidate (not yet sent, not booked), so it aids the keep/dismiss decision without cluttering finished
// rows. Verified through the ViewInspector harness so the badge is proven to actually appear, not merely
// defined ("logic in a SwiftUI view is untestable" unless exercised).
@MainActor
@Suite("ProspectRowView reachability badge (#1145)")
struct ProspectRowViewReachabilityTests {
    private func item(presenter: String?, sourceListingURL: String?, websiteURL: String? = nil,
                      status: ReviewStatus = .new, sentAt: Date? = nil) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                          performanceDate: "2026-09-12", sourceListingURL: sourceListingURL, websiteURL: websiteURL,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status)
        i.presenter = presenter
        i.sentAt = sentAt
        return i
    }

    private func texts(_ item: QueueItem) throws -> [String] {
        let view = ProspectRowView(item: item, today: "2026-07-09", onKeep: {}, onDismiss: { _ in })
        return try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    @Test func aSocialOnlySourceShowsTheBadge() throws {
        let t = try texts(item(presenter: "Aurora Strings", sourceListingURL: "https://instagram.com/aurorastrings"))
        #expect(t.contains { $0.contains(ReachabilityCopy.hardToReachBadge) })
    }

    @Test func aShowWithNoPresenterShowsTheBadge() throws {
        let t = try texts(item(presenter: nil, sourceListingURL: "https://carnegiehall.org/calendar/x"))
        #expect(t.contains { $0.contains(ReachabilityCopy.hardToReachBadge) })
    }

    @Test func aNamedPresenterOnANormalListingShowsNoBadge() throws {
        let t = try texts(item(presenter: "Aurora Strings", sourceListingURL: "https://carnegiehall.org/calendar/x"))
        #expect(!t.contains { $0.contains(ReachabilityCopy.hardToReachBadge) })
    }

    @Test func aRealWebsiteShowsNoBadge() throws {
        let t = try texts(item(presenter: nil, sourceListingURL: "https://instagram.com/x",
                               websiteURL: "https://aurorastrings.org"))
        #expect(!t.contains { $0.contains(ReachabilityCopy.hardToReachBadge) })
    }

    // Once the pitch has gone out, the show was clearly reachable; the badge must not linger on it.
    @Test func anAlreadySentShowShowsNoBadge() throws {
        let t = try texts(item(presenter: nil, sourceListingURL: "https://instagram.com/x",
                               status: .approved, sentAt: Date(timeIntervalSince1970: 1_780_000_000)))
        #expect(!t.contains { $0.contains(ReachabilityCopy.hardToReachBadge) })
    }
}
