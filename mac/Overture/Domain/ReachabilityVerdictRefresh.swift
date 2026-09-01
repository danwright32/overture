import Foundation
import SwiftData

// Milestone 61 Phase 0.3, under Dan's decision 7 of 2026-08-31.
//
// A stored reachability verdict records what a paid check CONCLUDED. Nothing updates it afterwards, so
// it drifts away from what the show holds: a contact deleted by hand, a venue warning dismissed, a
// guard cleared. Measured on the live store 2026-08-31 against a WAL inclusive copy, 4 rows carried a
// stored `no_email_found` over a live route.
//
// Dan's call, 2026-08-31, on being shown the narrow four row option first: "why wouldn't we refresh all
// 690 of them? Shouldn't it be accurate?", and again after being shown that some shows would move DOWN
// and why.
//
// A ONE TIME REPAIR, NOT A RULE CHANGE, and the distinction is the whole of what makes this safe.
// Confirmed with him directly in the same session, because the two readings need different code and the
// wrong one silently reverses a decision he made deliberately. `contactRouteForScoring` is untouched: it
// still reads the stored verdict, so the score still follows what the check concluded and a contact
// deleted by hand still does not move it. That is his 2026-08-13 call, recorded in that function's own
// comment, and it stands. What this removes is the accumulated drift, once. The cost he accepted is that
// drift can begin again afterwards.
//
// This is the shape #2664 got wrong in the other direction: it made the ranker follow the badge and
// "went further than the decision he actually made". Going further in the same way here would have been
// making this pass run on every launch.
enum ReachabilityVerdictRefresh {

    // Whether this Mac has already run the repair. A UserDefaults key rather than a stored column,
    // because the fact is about this installation having done the work once, not about any row.
    static let hasRunKey = "reachabilityVerdictRefreshCompletedAt"

    struct Report: Equatable, Sendable {
        // Rows observed carrying a negative verdict over a live route, stamped BEFORE anything was
        // rewritten. This is the number the repair would otherwise have made unobservable.
        var marked: Int
        // Movement judged through the app's OWN scoring function, `Ranker.contactRoutePoints`, rather
        // than a ranking invented beside it: a second definition of what a route is worth would drift
        // from the one that actually scores Dan's queue (L107, L263).
        var lifted: Int
        var lowered: Int
        var unchanged: Int
        var skippedNeverChecked: Int
        var skippedSentOrBooked: Int
    }

    // Returns nil when the repair has already run on this Mac, so a caller can tell "did nothing because
    // there was nothing to do" from "did nothing because it was not asked to" (L98).
    @discardableResult
    static func run(in context: ModelContext,
                    defaults: UserDefaults = .standard,
                    now: Date = Date()) -> Report? {
        guard defaults.object(forKey: hasRunKey) == nil else { return nil }

        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var report = Report(marked: 0, lifted: 0, lowered: 0, unchanged: 0,
                            skippedNeverChecked: 0, skippedSentOrBooked: 0)

        // PASS ONE: stamp every contradiction before a single verdict is rewritten. Deliberately a
        // separate loop rather than a step inside the repair, because interleaving them makes the
        // ordering an accident of statement order that a later edit can silently reverse (L277).
        for p in prospects {
            guard p.reachabilityResult == .noEmailFound, p.hasAnyRoute else { continue }
            p.contradictionMarkedAt = now
            report.marked += 1
        }

        // PASS TWO: the repair.
        for p in prospects {
            // Never checked stays never checked. `reachabilityResultFromRecipients` answers
            // `noEmailFound` for a show with no contacts, and a show nobody has looked at has none
            // either, so refreshing unconditionally would stamp a verdict no check ever reached onto
            // every unchecked show in the store (L10, L11).
            guard let old = p.reachabilityResult else {
                report.skippedNeverChecked += 1
                continue
            }
            // A show already pitched or booked keeps the verdict it went out under, matching the badge's
            // own rule at `reachabilityResultAsHeld`. What was true when Dan wrote to them is history,
            // not drift.
            guard p.sentAt == nil, !p.isBooked else {
                report.skippedSentOrBooked += 1
                continue
            }

            let new = p.reachabilityResultFromRecipients
            // The row's CURRENT tier on both sides, so the number reported is the verdict's own effect
            // rather than the verdict's and the tier's together.
            let tier = p.contactTierFromRecipients
            let before = Ranker.contactRoutePoints(ContactRoute(probeResult: old), tier: tier)
            let after = Ranker.contactRoutePoints(ContactRoute(probeResult: new), tier: tier)
            p.reachabilityResult = new
            if after > before { report.lifted += 1 }
            else if after < before { report.lowered += 1 }
            else { report.unchanged += 1 }
        }

        defaults.set(now, forKey: hasRunKey)
        return report
    }
}
