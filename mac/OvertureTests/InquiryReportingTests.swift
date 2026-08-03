import Testing
import Foundation
import SwiftData

// Phase 4 (#1437): the job here is NOT a report (that is #16, "Year-end Sankey of outreach outcomes").
// It is making sure an inquiry's source and outcome are captured cleanly and QUERYABLY now, so #16 can
// read inquiry data later without a backfill of history that was never recorded.
//
// The queryability half is the real work. `Inquiry.isOpen` reads two stored fields (the outcome, plus
// whether Dan set it by hand), and this project has already been bitten by a two-key rule that a
// SwiftData #Predicate could not express (#901: "unable to type-check this expression in reasonable
// time"). For an inquiry the second key is redundant, because an inquiry can never be closed
// automatically: it is suggestion-only for bookings (permitsAutoBook == false) and lost is always Dan's
// manual call. That redundancy is what makes a one-key predicate correct, so it is pinned below rather
// than assumed: if anyone ever adds an auto-close path, these fail instead of #16 quietly miscounting.
@MainActor
@Suite("Inquiry reporting capture (#1437)")
struct InquiryReportingTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func inquiry(_ outcome: Outcome? = nil, manual: Bool = false, sentAt: Date? = nil,
                         replied: Bool = false, source: InquirySource = .contactForm) -> Inquiry {
        let inq = Inquiry(source: source, inquirerName: "Ada", inquirerEmail: "ada@x.org",
                          eventName: "Gala")
        if let outcome { inq.outcome = outcome }
        if manual { inq.outcomeSourceRaw = OutcomeSource.manual.rawValue }
        inq.sentAt = sentAt
        inq.replied = replied
        return inq
    }

    // The load-bearing agreement: whatever `isOpen` says in Swift, the stored-field predicate must say
    // for the same record, across EVERY outcome and both outcome sources. This is the property that
    // lets #16 count open inquiries with a query instead of re-deriving the rule and drifting from it.
    @Test("the open/closed query agrees with isOpen for every outcome and source")
    func predicateMatchesIsOpen() throws {
        let ctx = ModelContext(try container())
        var expected: [String: Bool] = [:]

        for outcome in Outcome.allCases {
            for manual in [true, false] {
                let inq = inquiry(outcome, manual: manual)
                inq.inquirerName = "\(outcome.rawValue)-\(manual)"
                ctx.insert(inq)
                expected[inq.inquirerName] = inq.isOpen
            }
        }

        let open = try ctx.fetch(FetchDescriptor<Inquiry>(predicate: InquiryReporting.openPredicate))
        let openNames = Set(open.map(\.inquirerName))

        for (name, isOpen) in expected {
            #expect(openNames.contains(name) == isOpen, "\(name) disagreed")
        }
    }

    // Outcome.fromStored treats an unrecognised raw value as "no response", i.e. still open. The
    // predicate has to match that fallback, which is why it asks whether the record is CLOSED rather
    // than listing the open values: a raw string it has never seen must not silently count as closed.
    @Test("an unrecognised stored outcome counts as open, matching Outcome.fromStored")
    func unknownRawValueCountsAsOpen() throws {
        let ctx = ModelContext(try container())
        let inq = inquiry()
        inq.outcomeRaw = "something_a_later_version_wrote"
        ctx.insert(inq)

        let open = try ctx.fetch(FetchDescriptor<Inquiry>(predicate: InquiryReporting.openPredicate))

        #expect(inq.isOpen)
        #expect(open.count == 1)
    }

    // The legacy "passed" raw value maps to the soft lost case, so it must count as CLOSED on both
    // sides rather than falling through the unknown-value door above.
    @Test("the legacy passed value counts as closed on both sides")
    func legacyPassedIsClosed() throws {
        let ctx = ModelContext(try container())
        let inq = inquiry()
        inq.outcomeRaw = "passed"
        inq.outcomeSourceRaw = OutcomeSource.manual.rawValue
        ctx.insert(inq)

        let open = try ctx.fetch(FetchDescriptor<Inquiry>(predicate: InquiryReporting.openPredicate))

        #expect(!inq.isOpen)
        #expect(open.isEmpty)
    }

    // The funnel positions #16's Sankey needs, each derived from what is already stored.
    @Test("each inquiry reports where it sits in the funnel")
    func funnelStages() {
        #expect(InquiryReporting.stage(for: inquiry()) == .awaitingFirstReply)
        #expect(InquiryReporting.stage(for: inquiry(sentAt: Date())) == .awaitingTheirAnswer)
        #expect(InquiryReporting.stage(for: inquiry(.replied, sentAt: Date(), replied: true)) == .inConversation)
        #expect(InquiryReporting.stage(for: inquiry(.booked, manual: true)) == .booked)
        #expect(InquiryReporting.stage(for: inquiry(.lostSoft, manual: true)) == .lost)
        #expect(InquiryReporting.stage(for: inquiry(.lostHard, manual: true)) == .lost)
    }

    // For a lost inquiry, a Sankey needs the drop-off EDGE: how far it got before it died. All three
    // are derivable from stored timestamps, so none of this needs a new field or a backfill.
    @Test("a lost inquiry reports how far it got before it died")
    func lostDropOffPoint() {
        #expect(InquiryReporting.lostAfter(inquiry(.lostSoft, manual: true)) == .neverReplied)
        #expect(InquiryReporting.lostAfter(inquiry(.lostSoft, manual: true, sentAt: Date())) == .noAnswer)
        #expect(InquiryReporting.lostAfter(inquiry(.lostSoft, manual: true, sentAt: Date(), replied: true))
                == .conversationDied)
        // Not lost at all, so there is no drop-off to report.
        #expect(InquiryReporting.lostAfter(inquiry(.booked, manual: true)) == nil)
    }

    // Source is stored raw and survives a value the running build does not recognise, so a later
    // source added by a future version is never silently rewritten to the default on read-back.
    @Test("source is captured per inquiry and survives an unrecognised stored value")
    func sourceIsCaptured() {
        #expect(inquiry(source: .contactForm).source == .contactForm)
        #expect(inquiry(source: .directEmail).source == .directEmail)

        let inq = inquiry()
        inq.sourceRaw = "referral_from_a_later_version"
        #expect(inq.sourceRaw == "referral_from_a_later_version")
    }
}
