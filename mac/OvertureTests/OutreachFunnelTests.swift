import Testing
import Foundation

// #2035: 108 contacts had produced 3 sends, and nothing in the app could say why.
//
// The one report Dan can read counts CONTACTED shows only, so it describes the tail and is silent about
// everything before the send. Measured BY THIS CODE against the live store 2026-08-11: 873 scouted, 66
// holding a contact, 13 drafted, 6 sent, and of those 66, 38 still upcoming with a contact and no draft
// while 15 had passed their date that way, 10 of them after a PAID check. (An earlier hand-written set,
// 81 / 49 / 16 / 11, counted a form-or-DM contact as a contact and was wrong by a fifth.)
//
// Nothing renders these yet: the text block they were written for was removed the same day, because what
// Dan wants is #16's year-end Sankey rather than three sentences. See OutreachFunnel.swift.
@Suite("Where shows go between being scouted and being written to (#2035)")
struct OutreachFunnelTests {

    private let today = "2026-08-11"

    private func show(date: String, status: ReviewStatus = .new, draft: String? = nil,
                      sent: Date? = nil, probed: Date? = nil, runEnd: String? = nil,
                      emails: [String?] = []) -> Prospect {
        let p = Prospect(naturalKey: "k-\(date)-\(UUID().uuidString)", groupName: "A Show",
                         discipline: "other", venue: "A Hall", performanceDate: date,
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "neutral", coverage: "unknown",
                         fitScore: 0, tier: "longshot", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: status)
        p.draftBody = draft
        p.sentAt = sent
        p.reachabilityProbedAt = probed
        p.runEndDate = runEnd
        p.recipients = emails.enumerated().map { index, address in
            Recipient(id: "r-\(date)-\(index)", email: address, name: "Someone", provenance: .act)
        }
        return p
    }

    @Test func anEmptyStoreCountsZeroEverywhere() {
        #expect(OutreachFunnel.counts(from: [], today: today) == OutreachFunnel.Counts())
    }

    // The stage counts themselves.
    @Test func eachStageCountsTheShowsThatReachedIt() {
        let rows = [
            show(date: "2026-09-01"),                                             // scouted only
            show(date: "2026-09-02", emails: ["a@b.com"]),                        // contact found
            show(date: "2026-09-03", draft: "a body", emails: ["c@d.com"]),       // drafted
            show(date: "2026-09-04", status: .contacted, draft: "a body",
                 sent: Date(), emails: ["e@f.com"])                               // sent
        ]
        let c = OutreachFunnel.counts(from: rows, today: today)
        #expect(c.scouted == 4)
        #expect(c.contactFound == 3)
        #expect(c.drafted == 2)
        #expect(c.sent == 1)
    }

    // The leak the report exists to show.
    @Test func aShowWithAContactAndNoDraftIsCountedAsWaiting() {
        let c = OutreachFunnel.counts(from: [show(date: "2026-09-01", emails: ["a@b.com"])], today: today)
        #expect(c.waitingWithAContact == 1)
        #expect(c.expiredWithAContact == 0)
    }

    // A show already drafted is not waiting: the expensive part AND the drafting are both done, and what
    // is left is Dan's decision, which is not a leak.
    @Test func aDraftedShowIsNotWaiting() {
        let c = OutreachFunnel.counts(from: [show(date: "2026-09-01", draft: "a body", emails: ["a@b.com"])],
                                      today: today)
        #expect(c.waitingWithAContact == 0)
    }

    // Nor is one Dan dismissed. He has answered for that show, and counting it would make his own
    // decisions read as a backlog.
    @Test func aDismissedShowIsNotWaiting() {
        let c = OutreachFunnel.counts(from: [show(date: "2026-09-01", status: .dismissed, emails: ["a@b.com"])],
                                      today: today)
        #expect(c.waitingWithAContact == 0)
    }

    // And the ones that ran out of time in that state, with the paid ones counted apart because they are
    // the number with a cost attached.
    @Test func aShowThatPassedItsDateHoldingAContactIsCountedAsExpired() {
        let free = show(date: "2026-08-01", emails: ["a@b.com"])
        let paid = show(date: "2026-08-02", probed: Date(), emails: ["c@d.com"])
        let c = OutreachFunnel.counts(from: [free, paid], today: today)
        #expect(c.expiredWithAContact == 2)
        #expect(c.expiredAfterAPaidCheck == 1)
        #expect(c.waitingWithAContact == 0)
    }

    // A show that WAS written to and has since passed is not a loss, whatever its date.
    @Test func aPassedShowThatWasSentIsNotCountedAsExpired() {
        let c = OutreachFunnel.counts(
            from: [show(date: "2026-08-01", status: .contacted, sent: Date(), emails: ["a@b.com"])],
            today: today)
        #expect(c.expiredWithAContact == 0)
        #expect(c.sent == 1)
    }

    // A multi-night run has not passed until its LAST night. Judging it on the first would call a run Dan
    // can still pitch expired, and put it in the column that says the chance is gone.
    @Test func aRunStillPlayingIsNotExpired() {
        let c = OutreachFunnel.counts(
            from: [show(date: "2026-08-05", runEnd: "2026-08-20", emails: ["a@b.com"])], today: today)
        #expect(c.expiredWithAContact == 0)
        #expect(c.waitingWithAContact == 1)
    }

    // A route is not an address. A form-or-DM-only contact cannot be written to, so counting it as a
    // contact found would say a show is ready to write to when nothing can be sent (L16).
    @Test func aContactWithNoAddressIsNotAContactFound() {
        let c = OutreachFunnel.counts(from: [show(date: "2026-09-01", emails: [nil, "  "])], today: today)
        #expect(c.contactFound == 0)
        #expect(c.waitingWithAContact == 0)
    }

    // A whitespace draft is not a draft, for the same reason a whitespace address is not an address.
    @Test func aWhitespaceDraftIsNotADraft() {
        let c = OutreachFunnel.counts(from: [show(date: "2026-09-01", draft: "   ", emails: ["a@b.com"])],
                                      today: today)
        #expect(c.drafted == 0)
        #expect(c.waitingWithAContact == 1)
    }
}
