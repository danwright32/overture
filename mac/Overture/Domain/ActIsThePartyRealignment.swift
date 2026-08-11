import Foundation
import SwiftData

// #2504: put the producer axes of an already-stored act-named row in step with what they now mean.
//
// LIVE-STORE-CLAIM verified=2026-08-11 measure="rows naming no presenting organisation, and their mean fit score against the rest"
// Measured on the live store 2026-08-11: 439 of 877 rows name no presenting organisation, and they
// average a fit score of 0.4 against 3.2 for the rest. `EventClassifier` now reads the ACT as the party
// on such a row (Dan's call, 2026-08-11: judge the act, because the act is the party he would write to),
// so a show with no organisation billed is self-produced rather than an unanswerable `unknown`.
//
// That change on its own reaches nothing already in the store. The classification is a SNAPSHOT written
// when a show was last read, and the scout skips a source whose page bytes have not changed, so those
// 439 rows would keep the old zero for weeks and Dan would see two rankings of the same kind of show
// with nothing on the card to explain the difference. Same shape as `FitReasonRealignment` and
// `CatchAllFitReasonMigration` before it.
//
// NARROW ON PURPOSE, and it only ever moves a row in the direction the change is about:
//
//   - It reads the row's producer axes back out of `EventClassifier`, so a realigned row and a freshly
//     scouted one cannot disagree about what the same inputs imply. It is never a second copy of the
//     rules.
//   - It writes `production` only where the stored value is `unknown`. An `agency` row keeps its penalty:
//     the dead zone is the one direction this must not lift, and re-reading a stored title could demote
//     a row for reasons that have nothing to do with this change.
//   - It writes `profile` only to lift `neutral` to `strong`, never the other way.
//   - It never touches `discipline`. The genre is Dan's to correct (#1658/#1533) and is not what this is
//     about.
//   - It skips a row whose classification Dan overrode. That flag is his.
//
// It deliberately does NOT write `fitReason`. An empty reason is a decision (#1600 retired the catch-all
// and put nothing in its place), and `FitReasonRealignment` already owns putting a NON-empty sentence
// back in step with the axes on its own row. Two passes with opposite rules about the same field is how
// they come to contradict each other, so this one stays out of it entirely.
//
// Idempotent by construction rather than by a flag: the condition is "the axes this row's own inputs
// produce differ from the ones stored", and the pass writes those axes, so a second run is a no-op.
enum ActIsThePartyRealignment {

    struct Summary: Equatable {
        var productionLifted = 0
        var profileLifted = 0
        var rescored = 0
    }

    @discardableResult
    static func run(in context: ModelContext, now: Date = Date()) -> Summary {
        var summary = Summary()
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []

        for p in prospects {
            // The rule is about rows with no presenting organisation, through the one definition of that
            // (#1856), so this pass and the classifier cannot disagree about which rows they mean.
            guard OrganiserNaming.onlyTheActIsNamed(presenter: p.presenter) else { continue }
            // #1533: a classification Dan overrode is his, and this pass is not the place to revisit it.
            guard !p.classificationOverriddenByDan else { continue }

            // Re-read through the classifier itself, from what the row holds, exactly as
            // `RoomPresenterSweep` does after it clears a presenter.
            let asStored = ExtractedEvent(title: p.groupName, presenter: p.presenter, venue: p.venue)
            let reread = EventClassifier.classify(asStored)

            let storedProduction = Production(rawValue: p.production) ?? .unknown
            let storedProfile = Profile(rawValue: p.profile) ?? .neutral

            var production = storedProduction
            var profile = storedProfile
            if storedProduction == .unknown, reread.production == .selfProduced {
                production = .selfProduced
                summary.productionLifted += 1
            }
            if storedProfile == .neutral, reread.profile == .strong {
                profile = .strong
                summary.profileLifted += 1
            }
            guard production != storedProduction || profile != storedProfile else { continue }

            p.production = production.rawValue
            p.profile = profile.rawValue

            // Coverage is DERIVED from the other axes and never merged alongside them (#1949), so it
            // moves with them here or it would describe a row nothing saw. The genre it is derived
            // against is the STORED one, deliberately: this pass has no business re-deciding the genre.
            let settled = Discipline(rawValue: p.discipline) ?? .other
            let derived = EventClassifier.derived(discipline: settled, production: production,
                                                  profile: profile, venue: p.venue)
            p.coverage = derived.coverage.rawValue

            let refit = ClassificationOverride.rescored(p, now: now)
            p.fitScore = refit.score
            p.tier = refit.tier.rawValue
            summary.rescored += 1
        }
        return summary
    }
}
