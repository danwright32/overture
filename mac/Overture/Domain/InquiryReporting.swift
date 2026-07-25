import Foundation
import SwiftData

// Phase 4 (#1437): what a hire inquiry contributes to outcome reporting. This ships NO report; #16
// ("Year-end Sankey of outreach outcomes") is the home for that. The job here is only to make sure the
// source and the outcome are captured cleanly and queryably NOW, so #16 can read inquiry history later
// without needing a backfill of facts that were never recorded.
//
// Everything below is DERIVED from fields Inquiry already stores. Nothing new is persisted, so there is
// no schema change and no migration against Dan's live store.
enum InquiryReporting {
    // Where an inquiry sits in the funnel, in the shape #16's Sankey needs.
    enum Stage: String, CaseIterable, Sendable {
        case awaitingFirstReply    // logged; Dan has not written back yet
        case awaitingTheirAnswer   // Dan replied; nothing back yet
        case inConversation        // they answered and it is still live
        case booked
        case lost
    }

    // For a lost inquiry, the drop-off EDGE: how far it got before it died. A Sankey needs this to draw
    // the leak, and all three are derivable from timestamps already stored.
    enum LostAfter: String, CaseIterable, Sendable {
        case neverReplied       // Dan never sent a first reply
        case noAnswer           // Dan replied; they never answered
        case conversationDied   // they answered, then it went nowhere
    }

    static func stage(for inquiry: Inquiry) -> Stage {
        if inquiry.outcome == .booked { return .booked }
        if !inquiry.isOpen { return .lost }
        if inquiry.sentAt == nil { return .awaitingFirstReply }
        return inquiry.replied ? .inConversation : .awaitingTheirAnswer
    }

    // Why it ended, for #16's Declined / Not a fit split. Dan's own answer always wins; an inquiry
    // closed before that was captured (or by a later version this build can't read) falls back to what
    // the timestamps can honestly support, so it still lands in the lost column rather than vanishing
    // from the year-end total.
    static func lostReason(for inquiry: Inquiry) -> InquiryLostReason? {
        guard stage(for: inquiry) == .lost else { return nil }
        if let stated = inquiry.lostReason { return stated }
        return .neverHeardBack
    }

    static func lostAfter(_ inquiry: Inquiry) -> LostAfter? {
        guard stage(for: inquiry) == .lost else { return nil }
        if inquiry.sentAt == nil { return .neverReplied }
        return inquiry.replied ? .conversationDied : .noAnswer
    }

    // The raw outcome values that mean an inquiry is finished, including the legacy "passed" that
    // Outcome.fromStored folds into the soft lost case.
    static let closedOutcomeRawValues: [String] = [
        Outcome.booked.rawValue, Outcome.lostSoft.rawValue, Outcome.lostHard.rawValue, "passed",
    ]

    // Open inquiries, as a QUERY rather than a rule re-derived at the call site (#901: a two-key rule
    // could not be expressed as a #Predicate at all, and a predicate that is merely a superset of the
    // real rule is a defect by construction). This is one key because an inquiry can never be closed
    // automatically: bookings are suggestion-only for it (permitsAutoBook == false) and lost is always
    // Dan's manual call, so `isOpen`'s second term is redundant here. InquiryReportingTests pins that
    // agreement across every outcome and source, so an auto-close added later fails loudly.
    //
    // Deliberately phrased as NOT-closed rather than a list of open values, to match
    // Outcome.fromStored: a raw value this build has never seen reads as "no response" (open), and must
    // not silently count as closed.
    static var openPredicate: Predicate<Inquiry> {
        let closed = closedOutcomeRawValues
        return #Predicate<Inquiry> { !closed.contains($0.outcomeRaw) }
    }
}
