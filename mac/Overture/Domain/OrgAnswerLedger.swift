import Foundation

// #1598 (milestone 32 Phase 5): which shows may show an answer Dan paid for on a DIFFERENT show, and
// which must be paid for again.
//
// Pure and out of the views (#863/#885), because every rule in here is a spending decision or a claim
// on a card, and neither may be stated in a SwiftUI body where nothing can reach it. The SwiftData rows
// are mapped to plain values at the boundary so the rules are testable without a store.
//
// The asymmetry that shapes all of it: a wrongly reused positive costs one wasted Prep read, while a
// wrongly reused negative makes Dan dismiss a bookable show and he never learns it was wrong. So every
// rule fails toward paying again.
enum OrgAnswerLedger {

    // A stored answer, flattened off the model.
    struct Answer: Equatable, Sendable {
        let orgKey: String
        let result: Reachability.ProbeResult
        let probedAt: Date
        let presenterName: String
        let emails: [String]
    }

    // A prospect, as the fan-out needs it. `hasOwnAnswer` is what keeps a show's own paid verdict
    // untouchable.
    struct Show: Equatable, Sendable {
        let key: String
        let presenter: String?
        let venue: String?
        let hasOwnAnswer: Bool
    }

    // What a row shows when the answer came from elsewhere. It carries the ORIGINAL check's date, so
    // staleness is judged from when the work was actually done, and the organisation's name so the help
    // text can say where the answer came from.
    struct Inherited: Equatable, Sendable {
        let result: Reachability.ProbeResult
        let probedAt: Date
        let organisation: String
        let emails: [String]
    }

    // Built ONCE per render and folded into the row values (the EngagementLink.group precedent), never
    // per row: a per-row version would re-judge the gate against the whole store for every card drawn.
    //
    // `shows` MUST be every prospect in the store, dismissed ones included. Judged against only the
    // rows the queue is displaying, a house whose other bookings were dismissed starts looking like a
    // one-venue producer, and a producer can lose the second venue that qualifies it. Either way an
    // answer changes meaning because of an unrelated triage decision, with nothing on screen to say so,
    // and the bug would be invisible for weeks.
    static func inherited(from answers: [Answer], shows: [Show], now: Date,
                          promoted: Set<String> = []) -> [String: Inherited] {
        // Only positives, only fresh, and only with an address behind them. A positive with nothing to
        // show cannot claim there is somebody to email.
        var usable: [String: Answer] = [:]
        for answer in answers where answer.result == .emailFound && !answer.emails.isEmpty {
            guard !Reachability.probeIsStale(probedAt: answer.probedAt, now: now) else { continue }
            // Newest wins if a store somehow holds two rows for one organisation; the unique constraint
            // makes that impossible, and a tie broken silently the wrong way would be worse than either.
            if let existing = usable[answer.orgKey], existing.probedAt >= answer.probedAt { continue }
            usable[answer.orgKey] = answer
        }
        guard !usable.isEmpty else { return [:] }

        let corpus = shows.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) }
        var verdictByOrg: [String: Bool] = [:]
        var out: [String: Inherited] = [:]

        for show in shows where !show.hasOwnAnswer {
            guard let presenter = show.presenter,
                  let orgKey = OrgKey.stored(for: presenter),
                  let answer = usable[orgKey] else { continue }
            let qualifies = verdictByOrg[orgKey]
                ?? ProducerGate.qualifies(presenter, among: corpus, promoted: promoted)
            verdictByOrg[orgKey] = qualifies
            guard qualifies else { continue }
            out[show.key] = Inherited(result: answer.result, probedAt: answer.probedAt,
                                      organisation: answer.presenterName, emails: answer.emails)
        }
        return out
    }
}
