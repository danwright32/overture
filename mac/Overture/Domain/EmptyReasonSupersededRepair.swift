import Foundation
import SwiftData

// #3598. Clear a stored `reachabilityEmptyReason` that the row's OWN contacts contradict.
//
// The reason records what a check CONCLUDED when it came home with nobody to write to. Nothing updates
// it afterwards, so a show that has since gained a route keeps a sentence saying it has none. Measured
// on the live store 2026-09-06: 37 rows carry `named_but_no_route` and 31 of them hold a contact route.
//
// NOTHING RENDERS THOSE, and that is the thing to understand before deciding how much this matters. The
// sentence is drawn only under `ProspectRowView`'s `.noEmailFound` arm, and that verdict recomputes from
// the row's own contacts (#3387), so a contradicted reason is read by no surface. Costing nothing on
// screen is not the same as costing nothing: #3345 was filed at p1, and worked from for a week, on a
// count of exactly this column taken to be a current measurement of the world.
//
// WHAT IS AND IS NOT DESTROYED (L277). This clears the only copy in the STORE, and deliberately not the
// only copy anywhere: every check writes its results to `check-run-archives/<stamp>/`, which is where
// #3345's own evidence came from and where `DeadRunWriteOffRepair` reads which runs did not finish. So
// the diagnosis this removes from the store can still be made from the archives. What goes is a claim
// about the SHOW that stopped being true.
//
// EVERY LAUNCH, NOT ONCE, which is the one way it differs from the two repairs beside it in
// `LaunchMigrations`. `ReachabilityVerdictRefresh` and `DeadRunWriteOffRepair` are one-time because each
// changes what a card SAYS or what the ranker scores, so running them repeatedly would keep reversing a
// decision Dan made deliberately. This changes nothing any surface renders, and the contradiction can be
// created again after the pass has run: `ContactFormResultMigration` upgrades a verdict off
// `.noEmailFound` and leaves the reason, and a contact added by hand gives a row a route at any moment.
// A repair wired to one launch is blind to everything written after it (L332), and there is nothing here
// to be careful about, so it runs every time and is idempotent by construction: it writes the value its
// own condition reads.
enum EmptyReasonSupersededRepair {

    struct Report: Equatable, Sendable {
        var cleared: Int
        // Rows carrying a reason at all. Reported because zero cleared out of zero examined and zero out
        // of four hundred are the same number and different facts (L98): a fresh clone, a store this pass
        // has already settled, and a broken fetch would otherwise all read alike.
        var examined: Int
        var skippedSentOrBooked: Int
    }

    @discardableResult
    static func run(in context: ModelContext) -> Report {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var report = Report(cleared: 0, examined: 0, skippedSentOrBooked: 0)
        for p in prospects {
            guard let reason = p.reachabilityEmptyReason else { continue }
            report.examined += 1
            // A show already pitched or booked keeps what it went out under, the rule every pass in this
            // family follows and `reachabilityResultAsHeld`'s own. What was true when Dan wrote to them
            // is history, not drift.
            guard p.sentAt == nil, !p.isBooked else {
                report.skippedSentOrBooked += 1
                continue
            }
            // Judged through the row's own derivation, never a reproduction of it here: a second
            // definition of what a route is drifts silently, and reproducing this one in SQL is exactly
            // how #3345 came to be filed against a column no surface reads (L107, L263).
            let verdict = p.reachabilityResultFromRecipients
            // `emailFound` and not `weakContactOnly` is what counts as holding an address here, and the
            // difference is the whole reason two of these reasons exist. `weakContactOnly` means an
            // address a guard is holding, which on this store is a venue front desk or a press inbox,
            // and those are exactly what `onlyVenueContact` and `onlyPressContact` say the check found.
            // Counting one as a contradiction would clear the reason using the very evidence it reports.
            guard reason.isContradicted(byAddress: verdict == .emailFound,
                                        byAnyRoute: verdict != .noEmailFound) else { continue }
            p.reachabilityEmptyReason = nil
            report.cleared += 1
        }
        return report
    }
}
