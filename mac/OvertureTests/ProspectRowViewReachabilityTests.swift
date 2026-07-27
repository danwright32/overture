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
                      status: ReviewStatus = .new, sentAt: Date? = nil,
                      probed: Bool = false, hasEmail: Bool = false) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                          performanceDate: "2026-09-12", sourceListingURL: sourceListingURL, websiteURL: websiteURL,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status)
        i.presenter = presenter
        i.sentAt = sentAt
        if probed {
            i.reachabilityProbedAt = Date(timeIntervalSince1970: 1_780_000_000)
            // #1596 Phase 3: the badge reads the stored result, which the writers set once where the venue
            // and press guards have run. A row with a probe date and no result reads as never checked.
            i.reachabilityResult = hasEmail ? .emailFound : .noEmailFound
        }
        i.hasPendingRecipient = hasEmail
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

    @Test func aRealWebsiteWithAPresenterShowsNoBadge() throws {
        let t = try texts(item(presenter: "Aurora Strings", sourceListingURL: "https://carnegiehall.org/calendar/x",
                               websiteURL: "https://aurorastrings.org"))
        #expect(!t.contains { $0.contains(ReachabilityCopy.hardToReachBadge) })
    }

    // #1335: a website with no presenter (venue-ish) or on a social listing must not swallow the warning.
    @Test func aWebsiteWithNoPresenterStillWarns() throws {
        let t = try texts(item(presenter: nil, sourceListingURL: "https://instagram.com/x",
                               websiteURL: "https://aurorastrings.org"))
        #expect(t.contains { $0.contains(ReachabilityCopy.hardToReachBadge) })
    }

    // #1308 Layer 2 Phase 2: once a probe has run, the row shows the firm answer.
    @Test func aProbedShowWithAnEmailShowsEmailFound() throws {
        let t = try texts(item(presenter: "Aurora Strings", sourceListingURL: "https://carnegiehall.org/x",
                               probed: true, hasEmail: true))
        #expect(t.contains { $0.contains(ReachabilityCopy.emailFoundBadge) })
        #expect(!t.contains { $0.contains(ReachabilityCopy.hardToReachBadge) })
    }

    @Test func aProbedShowWithNoEmailShowsNoEmailFound() throws {
        let t = try texts(item(presenter: "Aurora Strings", sourceListingURL: "https://carnegiehall.org/x",
                               probed: true, hasEmail: false))
        #expect(t.contains { $0.contains(ReachabilityCopy.noEmailFoundBadge) })
    }

    // Once the pitch has gone out, the show was clearly reachable; the badge must not linger on it.
    @Test func anAlreadySentShowShowsNoBadge() throws {
        let t = try texts(item(presenter: nil, sourceListingURL: "https://instagram.com/x",
                               status: .approved, sentAt: Date(timeIntervalSince1970: 1_780_000_000)))
        #expect(!t.contains { $0.contains(ReachabilityCopy.hardToReachBadge) })
    }

    // Dan's call after the first real check (2026-07-27): the reachability answer belongs directly under
    // Keep and Dismiss, not buried in the tag stack on the left. It is the fact he is deciding ON, so it
    // should sit with the controls he decides WITH, not among the classification pills.
    @Test func theReachabilityBadgeSitsWithTheKeepAndDismissControls() throws {
        let t = try texts(item(presenter: "Aurora Strings", sourceListingURL: nil,
                               probed: true, hasEmail: true))
        guard let keep = t.firstIndex(of: "Keep"),
              let badge = t.firstIndex(where: { $0.contains(ReachabilityCopy.emailFoundBadge) }) else {
            Issue.record("expected both the Keep control and the reachability badge to render")
            return
        }
        #expect(badge > keep)
    }

    // The test that would have caught it. `theReachabilityBadgeSitsWithTheKeepAndDismissControls` above
    // asserts ORDER, and order is not placement: it passed on all three attempts where the badge landed
    // INSIDE the Keep/Dismiss row, rendering beside Dismiss and widening it. ViewInspector flattens the
    // tree, so "after Keep" is equally true of a horizontal sibling and a vertical one.
    //
    // This one pins the structure instead: find the row that holds Keep, and assert the badge is NOT in it.
    @Test func theReachabilityBadgeIsNotInsideTheKeepAndDismissRow() throws {
        let item = item(presenter: "Aurora Strings", sourceListingURL: nil, probed: true, hasEmail: true)
        let view = ProspectRowView(item: item, today: "2026-07-09", onKeep: {}, onDismiss: { _ in })
        // findAll, not find: `find` returns the OUTERMOST match, which is the whole row (left column plus
        // actions) and therefore contains the badge no matter where it sits. The button row is the
        // innermost HStack holding Keep, so take the candidate with the fewest text descendants.
        let candidates = try view.inspect().findAll(ViewType.HStack.self).filter { row in
            ((try? row.findAll(ViewType.Text.self).contains { try $0.string() == "Keep" }) ?? false)
        }
        guard let buttonRow = candidates.min(by: {
            (try? $0.findAll(ViewType.Text.self).count) ?? 0 < (try? $1.findAll(ViewType.Text.self).count) ?? 0
        }) else {
            Issue.record("expected an HStack containing the Keep control")
            return
        }
        let textsInButtonRow = try buttonRow.findAll(ViewType.Text.self).map { try $0.string() }
        #expect(textsInButtonRow.contains("Keep"))
        #expect(!textsInButtonRow.contains { $0.contains(ReachabilityCopy.emailFoundBadge) })
    }
}
