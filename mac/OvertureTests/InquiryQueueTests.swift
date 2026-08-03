import Testing
import Foundation

// Phase 3 (#1436): inquiries fold into the same date-grouped daily list as prospects, but they must
// NEVER be dropped by the pitch date-window that governs a show to pitch. An inquiry is live because
// someone awaits Dan's reply, whatever the event date, so a past, far-future, or unknown event date
// must never silently remove it from the list. This is the single worst failure mode the plan flags,
// so it is pinned here first.
@MainActor
@Suite("Inquiry queue fold-in and the date-window audit")
struct InquiryQueueTests {
    private let today = "2026-07-01"

    private func prospectItem(id: String, date: String?) -> QueueItem {
        QueueItem(id: id, groupName: "Group \(id)", discipline: "music", venue: "V",
                  performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                  priorRelationship: "none", production: "unknown", profile: "neutral",
                  coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                  matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                  status: .new)
    }

    private func inquiryRow(id: String, date: String?) -> InquiryRow {
        InquiryRow(id: id, inquirerName: "Ada \(id)", source: .directEmail, eventName: "Gala",
                   performanceDate: date, venue: "V", outcome: .noResponse, sentAt: nil,
                   replied: false, bookingSuggested: false, followUpNudgeDue: false,
                   shouldSuggestClosing: false)
    }

    private func rows(prospects: [QueueItem], inquiries: [InquiryRow]) -> [QueueRow] {
        QueueModel.combinedQueueRows(prospectItems: prospects, inquiryRows: inquiries,
                                     reachedOutKeys: [], today: today)
    }

    private func containsInquiry(_ id: String, in rows: [QueueRow]) -> Bool {
        rows.contains { if case .inquiry(let r) = $0 { return r.id == id }; return false }
    }
    private func containsProspect(_ id: String, in rows: [QueueRow]) -> Bool {
        rows.contains { if case .prospect(let p) = $0 { return p.id == id }; return false }
    }

    // THE AUDIT ────────────────────────────────────────────────────────────────
    @Test func aFarFutureInquiryStillAppears() {
        let out = rows(prospects: [], inquiries: [inquiryRow(id: "far", date: "2027-06-01")])
        #expect(containsInquiry("far", in: out))
    }

    @Test func aPastInquiryStillAppears() {
        let out = rows(prospects: [], inquiries: [inquiryRow(id: "past", date: "2026-01-01")])
        #expect(containsInquiry("past", in: out))
    }

    @Test func anUndatedInquiryStillAppears() {
        let out = rows(prospects: [], inquiries: [inquiryRow(id: "tbd", date: nil)])
        #expect(containsInquiry("tbd", in: out))
    }

    // Control: the same far-future and past dates DO drop a prospect show. This is what the inquiry
    // must not inherit.
    @Test func theSameDatesDropAProspect() {
        let out = rows(prospects: [prospectItem(id: "pfar", date: "2027-06-01"),
                                   prospectItem(id: "ppast", date: "2026-01-01")],
                       inquiries: [])
        #expect(!containsProspect("pfar", in: out))
        #expect(!containsProspect("ppast", in: out))
    }

    // Interleaving: an inquiry dated between two prospect shows groups in date order, not shoved to the
    // end.
    @Test func inquiriesInterleaveWithProspectsByDate() {
        let out = rows(prospects: [prospectItem(id: "p17", date: "2026-07-17"),
                                   prospectItem(id: "p19", date: "2026-07-19")],
                       inquiries: [inquiryRow(id: "i18", date: "2026-07-18")])
        let groups = QueueModel.groupRowsByDate(out)
        #expect(groups.map(\.id) == ["2026-07-17", "2026-07-18", "2026-07-19"])
        #expect(groups[1].rows.count == 1)
        if case .inquiry(let r) = groups[1].rows[0] { #expect(r.id == "i18") } else { Issue.record("expected inquiry row") }
    }

    // A booked or hand-lost inquiry leaves the daily list, like a confirmed booking leaves the pitch
    // queue.
    @Test func aClosedInquiryLeavesTheList() {
        let booked = Inquiry(source: .directEmail, inquirerName: "Ada", inquirerEmail: nil, eventName: "Gala")
        booked.outcome = .booked
        let open = Inquiry(source: .directEmail, inquirerName: "Bo", inquirerEmail: nil, eventName: "Recital")
        let built = QueueModel.inquiryRows([booked, open], now: Date())
        #expect(built.count == 1)
        #expect(built.first?.inquirerName == "Bo")
    }
}
