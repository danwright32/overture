import Foundation

// #2691: the dismiss REASON decides the scope.
//
// Dismissing a multi-night run used to kill every night of it, whatever reason was given, and four of
// the seven reasons on the Dismiss menu are statements about ONE NIGHT rather than about the show. So
// choosing one of them threw away dates Dan actively wanted. Worse, the dismissal followed the show
// forward: when the dropped night left the feed, `ScoutService.matchByAnyRunURL` re-keyed the stored
// dismissed row onto the next opening night deliberately, so the show never came back at all.
//
// Found live 2026-08-13 on `Rachel Sandler's Singer Showcase` at The Green Room 42, one row playing
// Aug 19, Sep 30 and Oct 21, whose Aug 19 is blocked by a day off.
enum RunNightDrop {

    // The four reasons that are statements about one night, in Dan's words (2026-08-13).
    //
    // Listed rather than derived from some property of the reason, because there is no such property:
    // "Too soon" and "Not a fit" are both judgements Dan makes about a card, and only their SUBJECT
    // differs. What is derived is the completeness check (`classified` below), so a reason added to the
    // menu later cannot quietly get no answer at all.
    static let aboutOneNight: Set<ShowOutcome> = [.dateConflict, .hadPaidWork, .pitchingOtherShows,
                                                 .tooSoon]

    // The ones that take the whole run, which is exactly today's behaviour.
    //
    // FOUR, not the three the issue lists. It says `noWayToReachThem` is one of the reasons "the app
    // applies to itself rather than offering on that menu", and that is not what the code does: the
    // card renders `ShowOutcome.menu(wasPitched:)`, which for an unpitched show is
    // `ShowOutcome.neverPitched`, and that includes it. So Dan can choose it, and it needed a scope.
    // The completeness check below is what caught it, which is the whole reason that check exists
    // rather than a list copied out of the issue (L96).
    //
    // Its scope is the SHOW. There being no way to contact the act is not a fact about one night.
    static let aboutTheShow: Set<ShowOutcome> = [.notAFit, .dontWantToShoot, .duplicate,
                                                .noWayToReachThem]

    // Every reason anybody has decided the scope of. `RunNightDropTests.everyMenuReasonIsClassified`
    // fails if the Dismiss menu grows a reason that is in neither set, so the answer cannot be "whatever
    // the code happens to reach" (L96, L113: a lookup keyed by a vocabulary needs its completeness
    // enforced, or a missing entry silently takes the default branch).
    static var classified: Set<ShowOutcome> { aboutOneNight.union(aboutTheShow) }

    static func isAboutOneNight(_ reason: ShowOutcome) -> Bool { aboutOneNight.contains(reason) }

    enum Outcome: Equatable {
        // Nothing to pick apart: a single-night show, a row with no recorded nights, or the last night
        // left. The caller dismisses the whole show carrying that reason, exactly as it does today.
        case wholeShow
        case alreadyDropped
        case moved(to: String)
    }
}

// #2691: a night Dan dropped, and why, and when.
//
// Stored as SELF-DESCRIBING entries on one array rather than as a second array lined up with
// `runNights`, which is the `Prospect.nightStartTimes` precedent (#1699) and for its reason: two
// parallel lists drift the moment one is written without the other, and the drift stays silent
// (L15, L41).
struct DroppedNight: Equatable, Sendable {
    var night: String
    var reason: ShowOutcome
    var at: Date

    // "yyyy-MM-dd|reason_raw|epoch_seconds". The separator is one this data cannot contain: a night is a
    // date, a reason is a lowercase raw value, and the stamp is a number.
    static let separator: Character = "|"

    var stored: String { "\(night)\(Self.separator)\(reason.rawValue)\(Self.separator)\(Int(at.timeIntervalSince1970))" }

    init(night: String, reason: ShowOutcome, at: Date) {
        self.night = night
        self.reason = reason
        self.at = at
    }

    // Nil on anything that does not parse, so a value written by a future build cannot be read as a
    // drop of some other night. A drop that cannot be read is a night that comes BACK, which is the safe
    // direction: Dan sees the card again and can drop it again, where the other direction silently loses
    // a date he wanted.
    init?(stored raw: String) {
        let parts = raw.split(separator: Self.separator, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let reason = ShowOutcome(rawValue: String(parts[1])),
              let seconds = TimeInterval(parts[2]) else { return nil }
        let night = String(parts[0])
        guard !night.isEmpty else { return nil }
        self.init(night: night, reason: reason, at: Date(timeIntervalSince1970: seconds))
    }

    static func all(on p: Prospect) -> [DroppedNight] {
        p.droppedRunNights.compactMap { DroppedNight(stored: $0) }
    }

    // What the scout's re-fold is allowed to keep. `runNights` is rebuilt from the venue's feed on every
    // run and the feed still lists the dropped night, so without subtracting here a drop lasts until the
    // next scout and then quietly undoes itself (L92: a removal recorded against nothing recurs).
    static func keeping(_ nights: [String], on p: Prospect) -> [String] {
        let dropped = Set(all(on: p).map(\.night))
        guard !dropped.isEmpty else { return nights }
        return nights.filter { !dropped.contains($0) }
    }
}

extension Prospect {

    // Drop one night of this run, or say that there is no run to pick apart.
    //
    // A run card only ever renders under its OPENING night (the queue groups on `performanceDate`), and
    // both controls that choose a reason act on a card, so the night being dropped is always the run's
    // first remaining night. There is no way to reach a middle night from either control, which is why
    // this needs no "which night did he mean" answer.
    @discardableResult
    func dropNight(_ night: String, reason: ShowOutcome, now: Date) -> RunNightDrop.Outcome {
        guard DroppedNight.all(on: self).allSatisfy({ $0.night != night }) else { return .alreadyDropped }
        // An empty `runNights` is a row stored before #1523, where the SPAN is all there is and nobody
        // knows which nights it plays. It is not a run whose nights can be picked off one at a time, and
        // `BlockedCalendar.conflict` already reads an empty list as "fall back to the span" for the same
        // reason.
        //
        // Two checks, not three. A `runNights.count > 1` clause stood here as well and a mutation proved
        // it dead: every case it excluded (no recorded nights, one night, the last night left) is already
        // excluded by one of these two, so nothing could tell whether it was there. An untested condition
        // that cannot change an answer is worse than no condition (L29).
        guard runNights.contains(night) else { return .wholeShow }
        let remaining = runNights.filter { $0 != night }
        guard let opening = remaining.min() else { return .wholeShow }

        droppedRunNights.append(DroppedNight(night: night, reason: reason, at: now).stored)
        runNights = remaining
        performanceDate = opening
        runEndDate = remaining.max()
        // The natural key IS the opening night, so it has to move with it. Re-keyed IN PLACE, keeping
        // this row's whole history, never inserted as a second card beside the old one: the URL arms
        // (`matchByAnyRunURL`) exist so the next scout finds this row again under its new key.
        naturalKey = Prospect.makeNaturalKey(groupName: groupName, performanceDate: opening, venue: venue)
        return .moved(to: opening)
    }

    // Cmd+Z. Puts the night back and restores the key, so an undo leaves the row exactly where it was
    // rather than somewhere that merely looks similar.
    func restoreNight(_ night: String) {
        let kept = DroppedNight.all(on: self).filter { $0.night != night }
        guard kept.count != DroppedNight.all(on: self).count else { return }
        droppedRunNights = kept.map(\.stored)
        guard !runNights.contains(night) else { return }
        runNights = (runNights + [night]).sorted()
        guard let opening = runNights.min() else { return }
        performanceDate = opening
        runEndDate = runNights.max()
        naturalKey = Prospect.makeNaturalKey(groupName: groupName, performanceDate: opening, venue: venue)
    }
}
