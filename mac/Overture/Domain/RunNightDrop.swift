import Foundation
import SwiftData

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
        // #2997: the run landed on a free opening. `releasing` names the nights it gave up on the way,
        // because another card already holds them, and it is empty on the ordinary drop.
        case moved(to: String, releasing: [String])
        // #2997: every night this row had left is already on another card, so it carries nothing of its
        // own. The caller closes it; the nights are still in Dan's queue, on those cards.
        case fullyCovered(releasing: [String])
        // #2754: the store could not answer whether that night is free. Nothing is written at all, and
        // it stays its own answer rather than folding into the release above: a release is a card this
        // code has SEEN, and a message may claim only what its check measured (L11).
        case cannotCheck
    }

    // What the store said about a candidate key. Three answers rather than a Bool, so the caller can tell
    // a refusal it can explain from one it cannot.
    enum KeyAvailability: Equatable {
        case free
        case taken
        case unreadable
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

    // #2754: may this row take that key, or does another card already hold it?
    //
    // Asked of the STORE rather than of whatever array the screen is rendering: a card holding the
    // candidate key is routinely one the queue is not showing (dismissed, archived, outside the date
    // window), and a check answered by the visible list would report those as free (L119).
    //
    // THREE answers, not two. A read that fails refuses, the same direction as a taken key, because
    // treating an unreadable store as an empty one merges two cards and destroys one of them (L105,
    // L42). But it is a DIFFERENT refusal: "another card has Oct 3" is a claim about a card this code
    // never saw, and a message may only claim what its check actually measured (L11). Naming the wrong
    // reason would send Dan looking for a card that does not exist.
    func keyAvailability(_ key: String, lookup: (String) throws -> Prospect?) -> RunNightDrop.KeyAvailability {
        do {
            guard let holder = try lookup(key) else { return .free }
            return holder === self ? .free : .taken
        } catch {
            return .unreadable
        }
    }

    // The store is the lookup on every shipping path. The seam exists so the unreadable branch above can
    // be exercised at all: a healthy in-memory store never throws, so a test that only ever asks one
    // proves nothing about the branch that matters most (L140).
    func keyAvailability(_ key: String, in context: ModelContext) -> RunNightDrop.KeyAvailability {
        keyAvailability(key, lookup: { try Prospect.stored(key: $0, in: context) })
    }

    // Drop one night of this run, or say that there is no run to pick apart.
    //
    // A run card only ever renders under its OPENING night (the queue groups on `performanceDate`), and
    // both controls that choose a reason act on a card, so the night being dropped is always the run's
    // first remaining night. There is no way to reach a middle night from either control, which is why
    // this needs no "which night did he mean" answer.
    @discardableResult
    func dropNight(_ night: String, reason: ShowOutcome, now: Date,
                   in context: ModelContext) -> RunNightDrop.Outcome {
        dropNight(night, reason: reason, now: now,
                  lookup: { try Prospect.stored(key: $0, in: context) })
    }

    @discardableResult
    func dropNight(_ night: String, reason: ShowOutcome, now: Date,
                   lookup: (String) throws -> Prospect?) -> RunNightDrop.Outcome {
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
        guard !remaining.isEmpty else { return .wholeShow }

        // #2754: settled BEFORE the first write, so a refusal leaves the row exactly as it was rather
        // than describing a run it no longer carries. MEASURED on the live store 2026-08-15: 8 of 98
        // multi-night runs would land on a key another card already holds, because a weekly series is
        // stored both as a run carrying every night and as separate cards for individual nights.
        //
        // Writing it anyway does NOT throw, which was the hopeful reading. Measured the same day against
        // an in-memory store: `save()` succeeds and SwiftData MERGES the two rows into one, taking some
        // fields from each, so a card's keep decision, its contacts and its outreach record go with no
        // error raised anywhere (L5).
        //
        // #2997: a taken night is RELEASED rather than refused, and the walk goes on to the next one.
        // That night is not lost, it is on the card that holds it, which is exactly why the key is
        // taken. Refusing instead left all four one-night reasons permanently dead on such a card and
        // gave Dan nothing he could act on (L109).
        //
        // Walked one night at a time rather than judged on the first, because the 9 live runs in this
        // state are two different shapes (measured 2026-08-19): 6 have nothing of their own left, and 3
        // keep nights a close-the-run answer would have destroyed, one of them 14 of them.
        var released: [String] = []
        var landing: String?
        for opening in remaining.sorted() {
            let candidate = Prospect.makeNaturalKey(groupName: groupName, performanceDate: opening,
                                                    venue: venue)
            switch keyAvailability(candidate, lookup: lookup) {
            // Fails closed on ANY night of the walk, not just the first: a read that dies half way
            // through has measured nothing about the rest, and the write below is all or nothing.
            case .unreadable: return .cannotCheck
            case .taken: released.append(opening)
            case .free: landing = opening
            }
            if landing != nil { break }
        }

        // The first write. Everything above is lookups.
        //
        // Dan's reason goes on HIS night and on no other. A released night is recorded as `.duplicate`,
        // which is what it is: this row's claim on it duplicates a card that already holds it. Writing
        // Dan's reason across all of them is the #2691 defect, and #16 reads these records (L163).
        droppedRunNights.append(DroppedNight(night: night, reason: reason, at: now).stored)
        droppedRunNights.append(contentsOf: released.map {
            DroppedNight(night: $0, reason: .duplicate, at: now).stored
        })

        // Nothing of this row's own is left. The key does NOT move: there is no free night to move it
        // to, and the whole point of the walk was that those nights belong to other cards. The caller
        // closes the row (`ProspectMutations`), so the decision about Dan's data stays where every other
        // status write lives rather than being made here.
        guard let opening = landing else {
            runNights = []
            runEndDate = nil
            return .fullyCovered(releasing: released)
        }

        let kept = remaining.filter { !released.contains($0) }
        runNights = kept
        performanceDate = opening
        runEndDate = kept.max()
        // The natural key IS the opening night, so it has to move with it. Re-keyed IN PLACE, keeping
        // this row's whole history, never inserted as a second card beside the old one: the URL arms
        // (`matchByAnyRunURL`) exist so the next scout finds this row again under its new key.
        naturalKey = Prospect.makeNaturalKey(groupName: groupName, performanceDate: opening, venue: venue)
        return .moved(to: opening, releasing: released)
    }

    // Cmd+Z. Puts the night back and restores the key, so an undo leaves the row exactly where it was
    // rather than somewhere that merely looks similar.
    //
    // #2754: the way back can collide too, and for a reason the drop's own collision does not need. The
    // feed still lists the dropped night (`DroppedNight.keeping` is what subtracts it from this row), so
    // a scout run between the drop and the undo can mint a separate card on exactly that night. Answers
    // whether the night came back, so a caller cannot report a restore that did not happen (L12).
    @discardableResult
    func restoreNights(_ nights: [String], in context: ModelContext) -> Bool {
        restoreNights(nights, lookup: { try Prospect.stored(key: $0, in: context) })
    }

    // #2997: SEVERAL nights, put back in ONE operation, because one dismiss can release several and they
    // have to come back together. Restoring them one at a time cannot work: each call recomputes the
    // opening and its key, so the released night would be offered its own date first, which is precisely
    // the date another card holds, and the undo would refuse the very night it exists to give back.
    @discardableResult
    func restoreNights(_ nights: [String], lookup: (String) throws -> Prospect?) -> Bool {
        let all = DroppedNight.all(on: self)
        let wanted = Set(nights)
        let kept = all.filter { !wanted.contains($0.night) }
        guard kept.count != all.count else { return false }
        let restored = (runNights + nights.filter { !runNights.contains($0) }).sorted()
        guard let opening = restored.min() else { return false }
        let candidate = Prospect.makeNaturalKey(groupName: groupName, performanceDate: opening,
                                                venue: venue)
        // Checked before ANY of the four writes below, the same order as the drop: a half-undo that
        // cleared the dropped-night record without moving the row would lose the record of the drop AND
        // leave the night out of the run, which no later press could put right.
        //
        // Taken and unreadable are one answer HERE, unlike in the drop, because an undo has no message of
        // its own to be wrong in: the caller reports how many rows came back, and a row that did not is
        // counted the same either way.
        guard keyAvailability(candidate, lookup: lookup) == .free else { return false }
        droppedRunNights = kept.map(\.stored)
        runNights = restored
        performanceDate = opening
        runEndDate = restored.max()
        naturalKey = candidate
        return true
    }
}
