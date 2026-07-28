import Foundation

// #1570. Dan's standing geography refusals, carried as ONE value so the question "is this show
// somewhere he would shoot" can be asked on the one predicate every queue surface already goes
// through (StageNavigation), instead of only on the masthead's own path.
//
// LIVE-STORE-CLAIM verified=2026-07-26 measure="untriaged shows the masthead's geo gate and the stage list disagreed about"
// It exists because the gate had two homes and they disagreed. The masthead ran its shows through
// QueueModel.filter with these two sets; the stage list Dan actually triages was built from the raw
// items and applied nothing, so the number and the list under it counted different shows (4 of 588 on
// the live store, 2026-07-26). #1238 had already chosen the other repair for the narrower case, and
// dismisses a REFUSED TOWN's shows outright, which is why the gap only ever showed for the other ways
// a show places out of range.
struct GeoRefusals: Equatable, Sendable {
    // Towns Dan has refused by name (ExcludedTown, lowercased), unioned with EventPlace's seed.
    var userExcludedTowns: Set<String> = []
    // #1221: seed towns he has un-skipped, subtracted back out.
    var allowedSeedTowns: Set<String> = []

    // No refusals of Dan's own. Still applies EventPlace's built-in rules, which is why it is named for
    // the absence of HIS refusals rather than for the absence of a gate.
    static let none = GeoRefusals()

    // The gate. A positive placement out of range hides; anything Overture cannot read keeps, always.
    // That asymmetry is the whole design (#970): a confident wrong place is the only failure here that
    // can lose Dan a real show, so uncertainty is never allowed to hide one.
    func hidesFromQueue(location: String?, discipline: Discipline) -> Bool {
        EventPlace.resolve(location: location, discipline: discipline,
                           userExcludedTowns: userExcludedTowns,
                           allowedSeedTowns: allowedSeedTowns).verdict == .outOfRange
    }

    // Whether this show should be kept off the queue entirely. Only a show Overture has not committed
    // outreach on is its to hide: an approved or contacted show carries live work (a send error, a
    // reply to watch for), and burying that behind a geography rule would lose it silently. Same line
    // ExcludedTownRetirement draws before it dismisses anything, shared here so the two cannot drift.
    func hidesFromQueue(_ p: Prospect) -> Bool {
        guard GeoRefusals.isOvertureToCut(p.status) else { return false }
        return hidesFromQueue(location: p.location,
                              discipline: Discipline(rawValue: p.discipline) ?? .other)
    }

    // new/queued/drafted are Overture's to cut; approved and contacted carry live outreach and are
    // left exactly as they are, and a dismissed show is already gone.
    static func isOvertureToCut(_ status: ReviewStatus) -> Bool {
        switch status {
        case .new, .queued, .drafted: return true
        case .approved, .contacted, .dismissed: return false
        }
    }
}
