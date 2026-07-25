import Testing
import Foundation
import SwiftData
@testable import Overture

// #1513, found by Dan walking the Debug build. Reached out was showing two kinds of row in two visual
// languages, and worse, under two date headings that MEANT DIFFERENT THINGS: the inquiry block carried
// its EVENT date and sat ABOVE the "Grouped by when to reach out next" caption (#1233 added that caption
// precisely so these headers are not mistaken for show dates), while the prospect rows below carried
// their REACH-OUT date. Identical treatment, different meaning, in one scrolling view.
//
// The fix gives an inquiry a reach-out date of its own and folds it into the SAME grouping, so one
// caption governs the whole stage and every date header in it answers one question.
@MainActor
@Suite("Reached out merges inquiries and shows under one date meaning (#1513)")
struct ReachedOutMergeTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func day(_ s: String) -> Date { EasternDate.date(from: s)! }

    private func inquiry(sentAt: Date?, replied: Bool = false, repliedAt: Date? = nil) -> Inquiry {
        let inq = Inquiry(source: .contactForm, inquirerName: "Ada", inquirerEmail: "ada@x.org",
                          eventName: "Gala", performanceDate: "2027-07-28")
        inq.sentAt = sentAt
        inq.gmailMessageId = sentAt == nil ? nil : "m-1"
        inq.replied = replied
        inq.repliedAt = repliedAt
        return inq
    }

    // An inquiry Dan has replied to and is waiting on is due when its follow-up nudge is: three business
    // days after he wrote. That is the same question the prospect rows answer, so it can share their
    // heading.
    @Test("a waiting inquiry is due when its follow-up nudge is")
    func waitingInquiryIsDueAtTheNudge() {
        // Thu 2026-01-01 plus three business days is Tue 2026-01-06 (Fri, Mon, Tue).
        let inq = inquiry(sentAt: day("2026-01-01"))

        #expect(inq.nextReachOutDate.map { EasternDate.dayString(from: $0) } == "2026-01-06")
    }

    // Once they write back it is Dan's move, so it sorts by when they replied rather than by a nudge
    // that no longer applies. Sorting it under a future date would bury the one row actually waiting on
    // him.
    @Test("an inquiry that got a reply is due when they replied, not at a future nudge")
    func repliedInquiryIsDueWhenTheyReplied() {
        let inq = inquiry(sentAt: day("2026-01-01"), replied: true, repliedAt: day("2026-01-02"))

        #expect(inq.nextReachOutDate.map { EasternDate.dayString(from: $0) } == "2026-01-02")
    }

    // Nothing to reach out about: not sent yet (it belongs in Review), or closed.
    @Test("an unsent or closed inquiry has no reach-out date")
    func noDateWhenUnsentOrClosed() {
        #expect(inquiry(sentAt: nil).nextReachOutDate == nil)

        let closed = inquiry(sentAt: day("2026-01-01"))
        closed.markOutcomeManually(.booked, now: day("2026-01-05"))
        #expect(closed.nextReachOutDate == nil)
    }

    // The merge itself: both kinds come back in ONE list ordered by that shared date, so the grouping
    // that follows produces one sequence of headings rather than an inquiry block stacked above a
    // separately-grouped prospect list.
    @Test("inquiries and shows interleave in one list ordered by when each is due")
    func bothKindsInterleaveByDate() throws {
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k", groupName: "Test Choir", discipline: "music", venue: "V",
                         performanceDate: "2026-03-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        let r = Recipient(id: "r-1", email: "them@x.org", name: "Them", provenance: .act)
        p.recipients = [r]
        ctx.insert(p)

        let early = inquiry(sentAt: day("2026-01-01"))   // due 2026-01-06
        let late = inquiry(sentAt: day("2026-01-20"))    // Tue, so due Fri 2026-01-23
        ctx.insert(early); ctx.insert(late)

        let entries = QueueModel.reachedOutEntries(
            prospects: [(prospect: p, recipient: r, next: day("2026-01-12"))],
            inquiries: [early, late], now: day("2026-01-05"))

        #expect(entries.count == 3)
        // Ordered by due date: the early inquiry, then the show, then the late inquiry.
        let order = entries.map { EasternDate.dayString(from: $0.next) }
        #expect(order == ["2026-01-06", "2026-01-12", "2026-01-23"])
        // And the show did not lose its place to the inquiries; the middle entry is still the prospect.
        if case .inquiry = entries[1] { Issue.record("the show should sit between the two inquiries") }
    }

    // #1513: the "N contacts across M shows" note sits directly above these rows, so its numbers have to
    // describe the rows Dan can actually see. Counting prospects only made it smaller than the list the
    // moment an inquiry joined it.
    @Test("the contacts note counts inquiries too, so it matches the visible rows")
    func noteCountsInquiries() throws {
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k", groupName: "Test Choir", discipline: "music", venue: "V",
                         performanceDate: "2026-03-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        let a = Recipient(id: "r-1", email: "a@x.org", name: "A", provenance: .act)
        let b = Recipient(id: "r-2", email: "b@x.org", name: "B", provenance: .presenter)
        p.recipients = [a, b]
        ctx.insert(p)
        let inq = inquiry(sentAt: day("2026-01-01"))
        ctx.insert(inq)

        let entries = QueueModel.reachedOutEntries(
            prospects: [(prospect: p, recipient: a, next: day("2026-01-12")),
                        (prospect: p, recipient: b, next: day("2026-01-12"))],
            inquiries: [inq], now: day("2026-01-05"))
        let counts = QueueModel.reachedOutNoteCounts(entries)

        // Three rows on screen: two contacts for one show, plus the inquiry.
        #expect(entries.count == 3)
        #expect(counts.contacts == 3)
        #expect(counts.shows == 2)
    }

    // Two contacts on ONE show is the fan-out the note exists to explain, and it must still read that
    // way when no inquiry is present.
    @Test("with no inquiries the note counts exactly what it always did")
    func noteUnchangedWithoutInquiries() throws {
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k", groupName: "Test Choir", discipline: "music", venue: "V",
                         performanceDate: "2026-03-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        let a = Recipient(id: "r-1", email: "a@x.org", name: "A", provenance: .act)
        let b = Recipient(id: "r-2", email: "b@x.org", name: "B", provenance: .presenter)
        p.recipients = [a, b]
        ctx.insert(p)

        let entries = QueueModel.reachedOutEntries(
            prospects: [(prospect: p, recipient: a, next: day("2026-01-12")),
                        (prospect: p, recipient: b, next: day("2026-01-12"))],
            inquiries: [], now: day("2026-01-05"))
        let counts = QueueModel.reachedOutNoteCounts(entries)

        #expect(counts.contacts == 2)
        #expect(counts.shows == 1)
    }

    // An inquiry with no reach-out date must not silently vanish from a stage it is placed in. If it
    // reaches this list at all it is because StageNavigation put it in Reached out, so it needs a date.
    @Test("an inquiry with nothing to be due about is left out rather than dated arbitrarily")
    func inquiryWithNoDateIsExcluded() throws {
        let ctx = ModelContext(try container())
        let unsent = inquiry(sentAt: nil)
        ctx.insert(unsent)

        let entries = QueueModel.reachedOutEntries(prospects: [], inquiries: [unsent],
                                                   now: day("2026-01-05"))

        #expect(entries.isEmpty)
    }
}
