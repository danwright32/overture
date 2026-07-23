import Foundation
import SwiftData

// #1238 follow-up: make "Never show me shows in <town>" actually remove the town's shows.
//
// The town refusal was only ever a view-time filter (EventPlace.resolve, read by QueueModel.filter for
// the to-send queue). Since #1134 the stage views are the only navigation, and they never applied that
// filter, so a blocked-town show stayed on screen and every future scout surfaced it again. Rather than
// re-plumb the filter into every stage view, a blocked-town show is now DISMISSED, which the base query
// already hides everywhere.
//
// Mirrors WentByRetirement (#864): Overture's own automatic cut, with a reason of its own (`tooFar`), so
// it never reads as a judgement Dan made. That distinction is load-bearing, not cosmetic: Overture
// watches out-of-town orgs for their occasional NYC dates (#970 point 7), so a blocked-town cut must
// never teach LocalHistory that Dan passed on the org, or it would penalise that org's real NYC date.
// LocalHistory only turns a dismissal into an org signal for `schedulingDismissals` / `dontWantToShoot`,
// and `tooFar` is neither, so the "teaches nothing" guarantee holds by construction (pinned by a test).
enum ExcludedTownRetirement {
    // Pure decision. A show is retired for a blocked town when its location resolves to an excluded town
    // (the built-in seed unioned with Dan's refusals, minus any seed town he has un-skipped, #1221) AND
    // he has not already committed outreach on it. Only new/queued/drafted are Overture's to cut here;
    // approved and contacted carry live outreach and are left exactly as they are.
    static func shouldRetire(status: ReviewStatus, location: String?, discipline: Discipline,
                             userExcludedTowns: Set<String>, allowedSeedTowns: Set<String>) -> Bool {
        switch status {
        case .new, .queued, .drafted: break
        case .approved, .contacted, .dismissed: return false
        }
        // The excluded-town verdict is decided before discipline in EventPlace.resolve, so a town refusal
        // holds for every discipline; the discipline passed here does not affect this branch.
        return EventPlace.resolve(location: location, discipline: discipline,
                                  userExcludedTowns: userExcludedTowns,
                                  allowedSeedTowns: allowedSeedTowns).reason == .excludedTown
    }

    // Returns how many shows it retired, so a caller can report what it actually did. Idempotent: a
    // retired show is dismissed, and dismissed shows are excluded, so a second pass finds nothing.
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        // Fetched directly (not via ExcludedTownEditing's @MainActor helpers) so this stays a nonisolated
        // synchronous pass like WentByRetirement, callable from launch, the scout, and the row action.
        let userExcluded = Set(((try? context.fetch(FetchDescriptor<ExcludedTown>())) ?? []).map(\.town))
        let allowedSeed = Set(((try? context.fetch(FetchDescriptor<AllowedSeedTown>())) ?? []).map(\.town))
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let retire = all.filter {
            shouldRetire(status: $0.status, location: $0.location,
                         discipline: Discipline(rawValue: $0.discipline) ?? .other,
                         userExcludedTowns: userExcluded, allowedSeedTowns: allowedSeed)
        }
        for p in retire {
            p.markDismissed(reason: .tooFar)
        }
        return retire.count
    }

    // Reverse of a single town's retirement, for the "Undo" on the exclude toast. Without this, Undo
    // would un-block the town yet leave its shows stuck dismissed (nothing would ever bring them back),
    // so the Undo would only half-work. Restores only shows THIS town retired (dismissed with `tooFar`),
    // never a cut Dan made himself or a seed-town show he never saw. `town` is the normalized (lowercased)
    // name, matching how ExcludedTownEditing stores and removes it.
    static func restore(town: String, in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        for p in all where p.status == .dismissed && p.dismissReason == .tooFar {
            guard let t = EventPlace.excludableTown(from: p.location)?.lowercased(), t == town else { continue }
            p.clearDismissal()
        }
    }
}
