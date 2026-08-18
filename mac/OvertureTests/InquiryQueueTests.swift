import Testing
import Foundation

// Phase 3 (#1436): inquiries ride the same daily list as prospects, but they must NEVER be dropped by a
// date rule that governs a show to pitch. An inquiry is live because someone awaits Dan's reply, whatever
// the event date, so a past, far-future, or unknown event date must never silently remove it from the
// list. This is the single worst failure mode the plan flags, so it is pinned here first.
//
// #2348: the audit used to run through QueueModel.combinedQueueRows, the one list that held both kinds.
// Nothing called it (the queue is stage scoped, so a stage renders its shows and its inquiries as two
// blocks), so it was deleted with the rest of the retired second filter and the audit moved onto the
// path the app really uses: an inquiry's stage is StageNavigation.stage(for:), and the rows come from
// QueueModel.inquiryRows. Both are asserted for each date, because a rule that holds in the stage and not
// in the rows would still lose the inquiry.
@MainActor
@Suite("Inquiry queue fold-in and the date-window audit")
struct InquiryQueueTests {
    private let today = "2026-07-01"

    private func inquiry(_ name: String, date: String?) -> Inquiry {
        let inq = Inquiry(source: .directEmail, inquirerName: name, inquirerEmail: nil, eventName: "Gala")
        inq.performanceDate = date
        return inq
    }

    private func inquiryRow(id: String, date: String?) -> InquiryRow {
        InquiryRow(id: id, inquirerName: "Ada \(id)", source: .directEmail, eventName: "Gala",
                   performanceDate: date, venue: "V", outcome: .noResponse, sentAt: nil,
                   replied: false, hasUnhandledReply: false, answeredReplyLine: nil,
                   bounced: false, bookingSuggested: false, followUpNudgeDue: false,
                   shouldSuggestClosing: false)
    }

    // The whole live path for one inquiry: the stage that would render it, and the row it renders as.
    private func staysInTheList(_ inq: Inquiry) -> Bool {
        StageNavigation.stage(for: inq) != nil
            && QueueModel.inquiryRows([inq], now: Date()).count == 1
    }

    private func prospect(_ key: String, date: String?) -> Prospect {
        Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "V",
                 performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "unknown", profile: "neutral",
                 coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .new)
    }

    // THE AUDIT ────────────────────────────────────────────────────────────────
    @Test func aFarFutureInquiryStillAppears() {
        #expect(staysInTheList(inquiry("Far", date: "2027-06-01")))
    }

    @Test func aPastInquiryStillAppears() {
        #expect(staysInTheList(inquiry("Past", date: "2026-01-01")))
    }

    @Test func anUndatedInquiryStillAppears() {
        #expect(staysInTheList(inquiry("Tbd", date: nil)))
    }

    // Control: the same PAST date does drop a prospect show out of triage, so the two really are being
    // judged differently and the assertions above are not just agreeing with an empty rule. The
    // far-future half of this control went with the queue's date window (#1567 took the last surface off
    // it), so a show that far out now stays too, which is why only the past date is asserted here.
    @Test func theSamePastDateDropsAProspect() {
        let past = prospect("ppast", date: "2026-01-01")
        let ahead = prospect("pahead", date: "2026-07-19")

        #expect(StageNavigation.naturalKeys(for: .scout, in: [past, ahead], context: .at(today)) == ["pahead"])
    }

    // The rows group by date, which is what puts an inquiry under the night it is about. Grouping keeps
    // the order it is handed, so a caller wanting date order sorts first: that used to be
    // combinedQueueRows' job and is now the view's.
    @Test func inquiryRowsGroupUnderTheirOwnDates() {
        let groups = QueueModel.groupRowsByDate([inquiryRow(id: "i17", date: "2026-07-17"),
                                                 inquiryRow(id: "i18", date: "2026-07-18"),
                                                 inquiryRow(id: "tbd", date: nil)]
                                                    .map { QueueRow.inquiry($0) })

        #expect(groups.map(\.id) == ["2026-07-17", "2026-07-18", "tbd"])
        #expect(groups[1].rows.count == 1)
        if case .inquiry(let r) = groups[1].rows[0] { #expect(r.id == "i18") } else { Issue.record("expected inquiry row") }
        #expect(groups[2].monthDay == "Date to be confirmed")
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
