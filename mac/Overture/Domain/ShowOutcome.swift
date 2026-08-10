import Foundation

// #2394, phase 1 of docs/plans/2026-08-09-one-outcome-vocabulary.md.
//
// The ONE vocabulary for how a show ended, replacing the seven separate lists Overture used to pick a
// disposition from (`DismissReason`, `ConversationState`, `ReachedOutClose.Outcome`, the full card's
// "Mark..." menu, `InquiryLostReason`, `StandDownCopy`, and the show-level `Outcome`): about 28 options
// describing roughly a dozen actual facts. One field, one column to report on, one list to read.
//
// Twelve values Dan picks, split into two halves, plus two Overture writes for itself. Which half is
// offered depends on whether anything was SENT, which is a fact about the send record and is
// deliberately NOT encoded in the words: `ShowOutcome.menu(wasPitched:)` is the only place that
// decision is made, so an impossible option ("Never heard back" on a show nobody emailed, "Date
// conflict" on one already pitched) cannot reach a menu.
//
// Three defects in the old spread are made unrepresentable here rather than merely fixed:
//   - #2388, "Declined" and "Closed (not now)" writing one stored value under two names, one line
//     apart on the same row. With one list there is nowhere for a second name to live, and
//     ShowOutcomeTests asserts no two values ever read the same.
//   - "Booked" meaning two opposite things: Dan was busy, and the client hired him. The first is now
//     `hadPaidWork` ("I had paid work"), which is the rename that kills the collision.
//   - An option offered on a show it cannot apply to, which the two disjoint halves prevent.
//
// Terminal by construction: carrying a value AT ALL means the show is over and no more work is owed on
// it. There is no "open" case, because the absence of a value is what open means, and giving open a
// spelling of its own is how "still waiting to hear" and "they never answered" became the same record.
enum ShowOutcome: String, CaseIterable, Equatable, Hashable, Sendable {

    // The seven for a show nothing was ever sent to. Every one of them is a statement about DAN'S
    // side or about the show, never about a person's answer, because nobody was asked.
    case dateConflict = "date_conflict"
    // The rename of `DismissReason.alreadyBooked`. "Already booked" meant Dan was busy and read as the
    // client having hired him, which is the exact opposite fact and the one that made the funnel
    // unreadable. Named for what actually held the night.
    case hadPaidWork = "had_paid_work"
    // #1821: Dan pitches about one show a night, so on a busy night the other good shows are cut for
    // want of a night, not for anything wrong with them. Must never be folded into `dateConflict`,
    // which claims the night did not work when in fact he spent it.
    case pitchingOtherShows = "pitching_other_shows"
    // #1128: a show he WOULD want, found too late to pitch. A missed opportunity, never a bad-fit
    // signal, so it must never be folded into `notAFit`.
    case tooSoon = "too_soon"
    case notAFit = "not_a_fit"
    // #351: personal taste, deliberately distinct from `notAFit`, which is a judgement about the show.
    case dontWantToShoot = "dont_want_to_shoot"
    case duplicate

    // The five for a show that WAS pitched. Four of them are somebody's answer, or the absence of one;
    // the fifth is Dan's.
    case booked
    // A silence, not a refusal. Distinct from having no value at all, which means nothing has happened
    // yet: the difference between "still waiting to hear" and "they never answered, I am closing this"
    // can only be captured at the moment Dan closes it.
    case neverHeardBack = "never_heard_back"
    case theySaidNotNow = "they_said_not_now"
    case theySaidNo = "they_said_no"
    // Replaces the stored `stoodDown`, whose wording was "You stopped working this". Dan rejected that
    // framing outright: "I will never stop working something without closure. Either they didn't
    // respond/turned me down or I turned them down." So it is an active refusal, not an abandonment.
    case turnedThemDown = "turned_them_down"

    // The two Overture writes for itself, never offered as a choice. `wentBy` is not a decision at all:
    // the show's last night passed while it sat untriaged, which is a fact about the calendar and must
    // never read as a judgement Dan made. `tooFar` is the consequence of blocking a town, a separate
    // action rather than a per-show ending.
    case wentBy = "went_by"
    case tooFar = "too_far"

    // MARK: the words Dan reads

    var label: String {
        switch self {
        case .dateConflict: return "Date conflict"
        case .hadPaidWork: return "I had paid work"
        case .pitchingOtherShows: return "Pitching other shows that night"
        case .tooSoon: return "Too soon"
        case .notAFit: return "Not a fit"
        case .dontWantToShoot: return "Don't want to shoot this"
        case .duplicate: return "Duplicate"
        case .booked: return "Booked"
        case .neverHeardBack: return "Never heard back"
        case .theySaidNotNow: return "They said not now"
        case .theySaidNo: return "They said no"
        case .turnedThemDown: return "I turned them down"
        case .wentBy: return "Went by"
        case .tooFar: return "Too far"
        }
    }

    // MARK: the two halves

    // In the order Dan meets them on the menu, so the order is a property of the vocabulary rather
    // than something each view re-decides.
    static let neverPitched: [ShowOutcome] = [.dateConflict, .hadPaidWork, .pitchingOtherShows,
                                              .tooSoon, .notAFit, .dontWantToShoot, .duplicate]

    static let pitched: [ShowOutcome] = [.booked, .neverHeardBack, .theySaidNotNow,
                                         .theySaidNo, .turnedThemDown]

    static var danCanChoose: [ShowOutcome] { neverPitched + pitched }

    // Overture's own, never in a menu. Derived from the two halves rather than listed a third time, so
    // a value added to either half cannot also be silently treated as automatic.
    var isOverturesOwn: Bool { !ShowOutcome.danCanChoose.contains(self) }

    // The ONE place the choice of menu is made. Takes the send record's answer as a parameter and is
    // not defaulted, so a caller that has not worked out whether the show was pitched cannot compile.
    static func menu(wasPitched: Bool) -> [ShowOutcome] { wasPitched ? pitched : neverPitched }

    // MARK: how it is reported

    // Three groups, not two. Dan: "I don't think we should count scouted but not pitched as 'lost'. I
    // do think it's worth counting though." Named here so phase 6's reporting reads the split off the
    // vocabulary instead of re-deriving it from a list of raw values, which is how a value added later
    // ends up counted in the wrong column or in none.
    //
    // nil for Overture's own two: neither is a judgement Dan made nor a pitch that failed, so neither
    // belongs in any reported group, and `wentBy` in particular must teach the history nothing.
    var group: ShowOutcomeGroup? {
        if isOverturesOwn { return nil }
        if self == .booked { return .booked }
        return ShowOutcome.neverPitched.contains(self) ? .neverPitched : .pitchedAndLost
    }
}

// The three groups a season report counts, kept apart from the vocabulary itself so a reader can ask
// which group a value belongs to without knowing every value.
enum ShowOutcomeGroup: String, CaseIterable, Equatable, Sendable {
    case neverPitched = "never_pitched"
    case booked
    case pitchedAndLost = "pitched_and_lost"
}

// MARK: - The bridge to the vocabulary being replaced
//
// TEMPORARY, and #2395 is the issue that removes it: phase 2 puts the menus over `ShowOutcome`
// directly, at which point `DismissReason` and everything here goes. It exists so phase 1 can move the
// STORAGE to one field without also rewriting every surface that still speaks in dismiss reasons, which
// would make one reviewable change into two unreviewable ones.
//
// Total both ways for the nine never-pitched values, and that is what makes it safe to convert at a
// boundary: nothing is lost in either direction. `DismissReasonBridgeTests` asserts the round trip.

extension DismissReason {
    var asShowOutcome: ShowOutcome {
        switch self {
        case .dateConflict: return .dateConflict
        case .notInterested: return .notAFit
        case .dontWantToShoot: return .dontWantToShoot
        case .alreadyBooked: return .hadPaidWork
        case .duplicate: return .duplicate
        case .tooSoon: return .tooSoon
        case .pitchingOtherShows: return .pitchingOtherShows
        case .wentBy: return .wentBy
        case .tooFar: return .tooFar
        }
    }
}

extension ShowOutcome {
    // Nil for the five pitched endings, which is correct rather than a gap: a show that was closed out
    // after a pitch was never dismissed, so it has no dismiss reason to report.
    var asDismissReason: DismissReason? {
        switch self {
        case .dateConflict: return .dateConflict
        case .notAFit: return .notInterested
        case .dontWantToShoot: return .dontWantToShoot
        case .hadPaidWork: return .alreadyBooked
        case .duplicate: return .duplicate
        case .tooSoon: return .tooSoon
        case .pitchingOtherShows: return .pitchingOtherShows
        case .wentBy: return .wentBy
        case .tooFar: return .tooFar
        case .booked, .neverHeardBack, .theySaidNotNow, .theySaidNo, .turnedThemDown: return nil
        }
    }
}
