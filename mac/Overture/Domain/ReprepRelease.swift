import Foundation
import SwiftData

// #1940: what happens to a re-prep request when the run carrying it ends without serving it.
//
// A queued re-prep now takes a show OUT of the Review count (StageNavigation), which is only safe if the
// show genuinely comes back. PrepImporter brings it back the ordinary way: it clears both flags for every
// key the results file names, served or skipped. The hole is the run that names nothing at all, which
// DetachedRunOutcome calls `finishedEmpty`, plus the run that dies and the run Dan cancels. Nothing clears
// those requests, so without this the draft would sit out of Review for as long as the flag stood.
//
// So the request is released when its run ends. "Its run" is the point: the release acts only on shows
// stamped `reprepHandedToRun` by the launch, so a request Dan queued by hand that no run has picked up yet
// is left exactly where it is, still waiting, still under Prep. The two look identical in the flags alone,
// which is why the stamp exists.
//
// The cooldown is deliberately NOT stamped (`reprepLastServedAt` is left alone): nothing was researched
// and nothing was written, so asking again must not be treated as asking twice.
@MainActor
enum ReprepRelease {
    // Release every re-prep request the finished run was carrying and did not serve. Returns the keys it
    // released, so a caller can say what the run left undone.
    @discardableResult
    static func release(in prospects: [Prospect]) -> [String] {
        var released: [String] = []
        for p in prospects where p.reprepHandedToRun {
            p.reprepHandedToRun = false
            // A served request has already had its flags cleared by PrepImporter, so there is nothing to
            // give back and nothing to report as left undone.
            guard p.isReprepQueued else { continue }
            p.reprepDraftRequested = false
            p.reprepContactsRequested = false
            released.append(p.naturalKey)
        }
        return released
    }

    // The same thing over the whole store, which is what a finished run has in front of it. Saving is part
    // of it: a release that is not persisted leaves the show out of Review until something else happens to
    // save, which is the defect this exists to prevent.
    @discardableResult
    static func releaseAfterRun(in context: ModelContext) -> [String] {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let released = release(in: all)
        guard !released.isEmpty else { return released }
        try? context.save()
        return released
    }
}
