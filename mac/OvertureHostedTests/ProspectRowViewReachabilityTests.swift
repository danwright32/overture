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
    private func item(presenter: String?, sourceListingURL: String? = nil,
                      status: ReviewStatus = .new, sentAt: Date? = nil,
                      probed: Bool = false, hasEmail: Bool = false) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                          performanceDate: "2026-09-12", sourceListingURL: sourceListingURL,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: status)
        i.presenter = presenter
        i.sentAt = sentAt
        if probed {
            // #3169: against the LIVE clock, because ProspectRowView asks for the badge with no
            // `now` and reads the wall clock at render time. A pinned instant here means "probed on
            // that day", which stopped meaning "probed recently" the moment real time walked past
            // the freshness window, and eight tests in this file went red on an untouched main.
            i.reachabilityProbedAt = LiveClockProbe.fresh
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

    // #1859: a show that simply names no organiser shows NOTHING before a check. It is not a dead end,
    // it is one nothing has looked at, and since #1856 a check on it pursues the act.
    @Test func aShowWithNoPresenterShowsNoBadgeUntilACheckHasLooked() throws {
        let t = try texts(item(presenter: nil, sourceListingURL: "https://carnegiehall.org/calendar/x"))
        #expect(!t.contains { $0.contains(ReachabilityCopy.hardToReachBadge) })
    }

    @Test func aNamedPresenterOnANormalListingShowsNoBadge() throws {
        let t = try texts(item(presenter: "Aurora Strings", sourceListingURL: "https://carnegiehall.org/calendar/x"))
        #expect(!t.contains { $0.contains(ReachabilityCopy.hardToReachBadge) })
    }

    @Test func aRealWebsiteWithAPresenterShowsNoBadge() throws {
        let t = try texts(item(presenter: "Aurora Strings", sourceListingURL: "https://carnegiehall.org/calendar/x"))
        #expect(!t.contains { $0.contains(ReachabilityCopy.hardToReachBadge) })
    }

    // #1335: a website with no presenter (venue-ish) or on a social listing must not swallow the warning.
    @Test func aWebsiteWithNoPresenterStillWarns() throws {
        let t = try texts(item(presenter: nil, sourceListingURL: "https://instagram.com/x"))
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

    // #3169: what a released answer actually renders, which nothing hosted asserted until the day every
    // fixture in this file aged into it at once. `Reachability.badge` covers the rule already; what was
    // missing is that THIS row is what a rotted fixture silently becomes, so a future rot shows up as a
    // second badge appearing rather than only as the first one vanishing.
    @Test func aProbeTheClockHasReleasedShowsTheStaleBadge() throws {
        var released = item(presenter: "Aurora Strings", sourceListingURL: "https://carnegiehall.org/x",
                            probed: true, hasEmail: true)
        released.reachabilityProbedAt = LiveClockProbe.stale
        let t = try texts(released)
        #expect(t.contains { $0.contains(ReachabilityCopy.staleProbeBadge) })
        #expect(!t.contains { $0.contains(ReachabilityCopy.emailFoundBadge) })
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

    // #1597 follow-up (Dan, walking the Debug build): "can we also put the email directly under this
    // indicator when there is one... any and all emails including weak cases. I should see all of them."
    //
    // The badge says an address exists; it never says WHICH. That is the thing he needs while triaging,
    // because "info@thevenue.com" and "nora@noracalder.example" are the same badge and completely different
    // decisions. ALL of them, not just the primary: a self-produced show with two named performers found
    // two people, and showing one silently hides the other.
    // #1628: `confidence` defaults to `.high` so these fixtures exercise the PLAIN badge. Left at nil (or
    // anything below high) the row now reads "Unverified email found", which is a different assertion and
    // has its own test below.
    private func withContacts(_ emails: [String], result: Reachability.ProbeResult,
                              confidence: ContactConfidence? = .high) -> QueueItem {
        var i = item(presenter: "Aurora Strings", sourceListingURL: nil, probed: true)
        i.reachabilityResult = result
        i.contacts = emails.enumerated().map { idx, email in
            var r = RecipientSnapshot(id: "r\(idx)", name: nil, email: email, role: nil, provenance: .act,
                                      sendState: .pending, replied: false, lastReplyText: nil,
                                      resolution: nil, bounced: false, outcomeSource: .auto)
            r.contactConfidence = confidence
            return r
        }
        i.hasPendingRecipient = (result == .emailFound)
        return i
    }

    @Test func aFoundAddressIsShownUnderTheBadge() throws {
        let t = try texts(withContacts(["hello@auroratrio.com"], result: .emailFound))
        #expect(t.contains { $0.contains(ReachabilityCopy.emailFoundBadge) })
        #expect(t.contains("hello@auroratrio.com"))
    }

    // #1628, Dan's call 2026-07-28: when NOTHING found was verified the badge says so itself, instead of
    // a caveat printed beside every address (which broke the address column three layouts running).
    @Test func theBadgeNamesAnUnverifiedFindWhenNothingWasVerified() throws {
        let t = try texts(withContacts(["info@somevenue.example"], result: .emailFound, confidence: .medium))
        #expect(t.contains { $0.contains(ReachabilityCopy.unverifiedEmailFoundBadge) })
        #expect(t.contains("info@somevenue.example"), "the address is still printed, just once and plainly")
    }

    // One solid address is enough: a weaker sibling beside it must not drag the badge down, or it cries
    // wolf on a show Dan can act on.
    @Test func oneVerifiedContactKeepsThePlainBadge() throws {
        var i = withContacts(["nora@noracalder.example"], result: .emailFound, confidence: .high)
        var weak = i.contacts[0]
        weak = RecipientSnapshot(id: "r1", name: nil, email: "info@venue.example", role: nil,
                                 provenance: .act, sendState: .pending, replied: false,
                                 lastReplyText: nil, resolution: nil, bounced: false, outcomeSource: .auto)
        weak.contactConfidence = .low
        i.contacts.append(weak)
        let t = try texts(i)
        #expect(t.contains { $0.contains(ReachabilityCopy.emailFoundBadge) })
        #expect(!t.contains { $0.contains(ReachabilityCopy.unverifiedEmailFoundBadge) })
    }

    // Every one of them. Showing only the first would hide the second performer on exactly the shows
    // where finding both was the hard part (#366).
    @Test func everyAddressIsShownNotJustTheFirst() throws {
        let t = try texts(withContacts(["nora@noracalder.example", "emery@emeryblake.example"], result: .emailFound))
        #expect(t.contains("nora@noracalder.example"))
        #expect(t.contains("emery@emeryblake.example"))
    }

    // The weak case too, and this is where it earns the most: the gold badge says an address exists but
    // is not really sendable, and seeing that it is the venue's front desk is what makes that judgment
    // legible instead of something Dan has to take on trust.
    @Test func aWeakAddressIsShownToo() throws {
        let t = try texts(withContacts(["info@thevenue.com"], result: .weakContactOnly))
        #expect(t.contains { $0.contains(ReachabilityCopy.weakContactOnlyBadge) })
        #expect(t.contains("info@thevenue.com"))
    }

    // Nothing found means nothing to show, and certainly no empty line pretending to be an address.
    @Test func aRowWithNoAddressShowsNoAddressLine() throws {
        let t = try texts(withContacts([], result: .noEmailFound))
        #expect(t.contains { $0.contains(ReachabilityCopy.noEmailFoundBadge) })
        #expect(!t.contains { $0.contains("@") })
    }

    // A contact carrying no email at all (a contact FORM, which Overture does record) must not render as
    // a blank line under the badge.
    @Test func aContactWithNoEmailDoesNotRenderAnEmptyLine() throws {
        var i = withContacts([], result: .emailFound)
        i.contacts = [RecipientSnapshot(id: "r0", name: "Booking", email: nil, role: nil, provenance: .act,
                                        sendState: .pending, replied: false, lastReplyText: nil,
                                        resolution: nil, bounced: false, outcomeSource: .auto)]
        let view = ProspectRowView(item: i, today: "2026-07-09", onKeep: {}, onDismiss: { _ in })
        let t = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(!t.contains(""))
    }
}
