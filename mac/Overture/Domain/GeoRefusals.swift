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

    // #1962: verdicts this pass has already worked out, keyed by the place and discipline they were
    // worked out for. Derived, never part of what this value IS: see the Equatable conformance below.
    //
    // Resolving a place is the single most expensive thing the queue's rebuild did. Three sweeps in one
    // rebuild each asked about every show and none reused the others' answer, about 1,270 of 14,856
    // main-thread samples on the live store. The verdict is a pure function of the place, the discipline
    // and the two refusal sets, so asking it twice can only ever produce the same answer twice.
    private var resolvedPlaces: [String: Bool] = [:]

    // Spelled out rather than synthesised, because the memo above is private and a private stored property
    // makes the memberwise initialiser private with it. Every caller still builds one exactly as before.
    init(userExcludedTowns: Set<String> = [], allowedSeedTowns: Set<String> = []) {
        self.userExcludedTowns = userExcludedTowns
        self.allowedSeedTowns = allowedSeedTowns
    }

    // No refusals of Dan's own. Still applies EventPlace's built-in rules, which is why it is named for
    // the absence of HIS refusals rather than for the absence of a gate.
    static let none = GeoRefusals()

    // #1962: what this value IS, which is Dan's two sets of towns. The table is a memo of a pure function
    // of exactly those, so two gates carrying the same refusals ARE the same gate whether or not one of
    // them has done some work. One of them is read as a render fingerprint, and a derived difference there
    // would report as a change nobody made.
    static func == (lhs: GeoRefusals, rhs: GeoRefusals) -> Bool {
        lhs.userExcludedTowns == rhs.userExcludedTowns && lhs.allowedSeedTowns == rhs.allowedSeedTowns
    }

    // A copy carrying the verdict for every distinct place these shows sit in. Built once per render pass
    // and shared by every sweep in it.
    func resolving(_ prospects: [Prospect]) -> GeoRefusals {
        var copy = self
        for p in prospects {
            let discipline = Discipline(rawValue: p.discipline) ?? .other
            let key = GeoRefusals.placeKey(location: p.location, discipline: discipline)
            guard copy.resolvedPlaces[key] == nil else { continue }
            copy.resolvedPlaces[key] = copy.resolveVerdict(location: p.location, discipline: discipline)
        }
        return copy
    }

    // How many distinct places this value has already answered for. The win #1962 claims, stated as a
    // number a test can hold the code to rather than a timing.
    var resolvedPlaceCount: Int { resolvedPlaces.count }

    // Discipline first, because a place can be in range for one and not another, and a nil location is
    // deliberately its own key rather than folding onto the empty string: the two reach EventPlace as
    // different inputs and it is not this table's business to decide they agree.
    private static func placeKey(location: String?, discipline: Discipline) -> String {
        "\(discipline.rawValue)\u{1}\(location ?? "\u{0}")"
    }

    private func resolveVerdict(location: String?, discipline: Discipline) -> Bool {
        EventPlace.resolve(location: location, discipline: discipline,
                           userExcludedTowns: userExcludedTowns,
                           allowedSeedTowns: allowedSeedTowns).verdict == .outOfRange
    }

    // The gate. A positive placement out of range hides; anything Overture cannot read keeps, always.
    // That asymmetry is the whole design (#970): a confident wrong place is the only failure here that
    // can lose Dan a real show, so uncertainty is never allowed to hide one.
    func hidesFromQueue(location: String?, discipline: Discipline) -> Bool {
        // #1962: from this pass's table when it holds this place, and worked out the same way as ever when
        // it does not. A miss costs what the whole thing used to cost and can never change an answer,
        // which is what lets the memo be an optimisation rather than a second rule.
        if let known = resolvedPlaces[GeoRefusals.placeKey(location: location, discipline: discipline)] {
            return known
        }
        return resolveVerdict(location: location, discipline: discipline)
    }

    // Whether this show should be kept off the queue entirely. Only a show Overture has not committed
    // outreach on is its to hide: an approved or contacted show carries live work (a send error, a
    // reply to watch for), and burying that behind a geography rule would lose it silently. Same line
    // ExcludedTownRetirement draws before it dismisses anything, shared here so the two cannot drift.
    func hidesFromQueue(_ p: Prospect) -> Bool {
        guard GeoRefusals.isOvertureToCut(p.status) else { return false }
        // #1658: a row this app was showing, whose GENRE then moved it onto the stricter rule, is judged
        // by the loose rule it was already being judged by. Dan's call: re-reading a genre must never be
        // what takes a show away from him. His own town refusals are untouched by this, because they hide
        // a row under the loose rule too.
        if p.keptVisibleAfterGenreChange {
            return hidesFromQueue(location: p.location, discipline: .other)
        }
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
