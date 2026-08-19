import Foundation
import SwiftData

// #2988: offer the shows whose contact answer was produced while the app was WITHHOLDING the producing
// organisation it already held (#2983), so they stop reading "No email found" for the 90 days the badge
// trusts a stamp.
//
// #2983 fixed the work-list, and a fix to a writer reaches only the rows written after it. Measured on the
// live store 2026-08-19: 23 shows read `no_email_found` and 12 of them carry a presenter the run was never
// told about, four of which name an organisation appearing in no check transcript on this Mac at all. One of
// those is the show Dan reported, whose company publishes an address on its own contact page.
//
// It sets #2261's REQUEST FLAG and nothing else, which is the whole design:
//
//   * The recorded verdict, its reason and its stamp all SURVIVE. #2261 chose a flag over a clearing so
//     that a re-check finding nothing leaves Dan no worse off than before, and a repair pass must not
//     quietly choose differently (L5).
//   * It SPENDS NOTHING. The flag makes a row a probe candidate again (`hasFreshReachabilityAnswer` reads
//     it), so the shows become offerable and Dan still decides what to check and when. No paid lookup
//     happens because this ran.
//   * It reuses that one mechanism rather than adding a second way to un-freeze an answer, so the two
//     cannot come to disagree about what a pending re-check means.
enum PresenterWithheldRecheck {
    // What this WOULD offer, computed without writing anything, so the count can be stated before any
    // decision to spend. Shares its predicate with `run` rather than restating it, so the number reported
    // and the rows changed can never be two different sets (L16).
    static func candidates(in context: ModelContext, presenterCarriedSince: Date) -> [Prospect] {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        return all.filter { isCandidate($0, presenterCarriedSince: presenterCarriedSince) }
    }

    private static func isCandidate(_ p: Prospect, presenterCarriedSince: Date) -> Bool {
        // A show that named nobody had no producer to withhold, so its empty answer is not evidence of this
        // defect and re-offering it would spend real money to learn the same thing. Asked through the SAME
        // predicate the queue builders use, so this pass and the field it compensates for cannot disagree
        // about who counts as named.
        guard OrganiserNaming.namedOrganiser(presenter: p.presenter) != nil else { return false }
        // Only the EMPTY verdict. A show that came home with an address was answered, whatever it was told.
        guard p.reachabilityResult == .noEmailFound else { return false }
        // Never move a request that already exists, including one Dan made himself: the row reads that
        // timestamp to decide it has acknowledged him, so overwriting it would reset an acknowledgement he
        // has already seen. This is also what makes a second run a no-op.
        guard p.reachabilityRecheckRequestedAt == nil else { return false }
        // The BOUNDARY, which is what makes this terminate rather than re-offer forever. A check run after
        // the presenter began being carried has had its real answer, and `no_email_found` is then a
        // legitimate verdict about a search that really happened; flagging those would re-offer a correct
        // answer on every launch and spend on it each time (L174).
        guard let probedAt = p.reachabilityProbedAt else { return false }
        return probedAt < presenterCarriedSince
    }

    // The boundary is LEARNED on first launch, never hard-coded, and that is the one decision here worth
    // understanding.
    //
    // A literal date would be wrong for the gap between #2983 merging and Dan installing the build that
    // carries it, during which the OLD build kept checking shows without being told the presenter. Those
    // checks would sit after a merge-dated boundary and be excluded, which is the exact population this
    // pass exists for. The first launch of a build containing this code IS the earliest instant any check
    // could have carried a presenter, so that launch records it and every later launch reads the same
    // value. Stored rather than recomputed, or it would move forward with every launch and the window
    // would close behind whichever rows had not been reached yet (the mistake `FirstSeenBackfill` names).
    static let boundaryKey = "presenterCarriedSince"

    static func boundary(defaults: UserDefaults, now: Date) -> Date {
        if let stored = defaults.object(forKey: boundaryKey) as? Date { return stored }
        defaults.set(now, forKey: boundaryKey)
        return now
    }

    // Returns the rows it CHANGED, never the rows it considered, because that number is what Dan is told
    // before he spends anything (L12).
    @discardableResult
    static func run(in context: ModelContext, presenterCarriedSince: Date, now: Date) -> Int {
        var changed = 0
        for p in candidates(in: context, presenterCarriedSince: presenterCarriedSince) {
            p.reachabilityRecheckRequestedAt = now
            changed += 1
        }
        return changed
    }
}
