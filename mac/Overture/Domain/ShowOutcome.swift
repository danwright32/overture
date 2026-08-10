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

    // #2251: the same words, cased for use AFTER A NUMBER in a report ("3 never heard back"), where the
    // menu label is written to be picked rather than counted. Deliberately the label's own words rather
    // than a second phrasing of the same fact, which is the #843 trap from the naming direction, and a
    // test asserts the two never drift apart. Only the pitched endings have one, because only those are
    // counted in a lost split today; a never-pitched ending would need its own reading of the same rule.
    var countedPhrase: String {
        switch self {
        case .booked: return "booked"
        case .neverHeardBack: return "never heard back"
        case .theySaidNotNow: return "they said not now"
        case .theySaidNo: return "they said no"
        case .turnedThemDown: return "I turned them down"
        default: return label
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

// MARK: - What Dan is told once an ending is recorded

extension ShowOutcome {
    // #2395: the acknowledgment, beside the words it acknowledges so the two cannot drift.
    //
    // It names the outcome back rather than saying "Saved", because the row Dan pressed it on leaves the
    // stage the instant it lands, so this sentence is the only evidence anything happened at all.
    static func recordedLine(_ outcome: ShowOutcome, org: String) -> String {
        switch outcome {
        case .booked: return "\(org) recorded as booked."
        case .neverHeardBack: return "\(org) closed out: never heard back."
        case .theySaidNotNow: return "\(org) closed out: they said not now."
        case .theySaidNo: return "\(org) closed out: they said no."
        case .turnedThemDown: return "\(org) closed out: you turned them down."
        case .dateConflict: return "\(org) dismissed: date conflict."
        case .hadPaidWork: return "\(org) dismissed: you had paid work."
        case .pitchingOtherShows: return "\(org) dismissed: pitching other shows that night."
        case .tooSoon: return "\(org) dismissed: too soon to pitch it."
        case .notAFit: return "\(org) dismissed: not a fit."
        case .dontWantToShoot: return "\(org) dismissed: you don't want to shoot this."
        case .duplicate: return "\(org) dismissed as a duplicate."
        // Overture's own two are never recorded by hand, so nothing acknowledges them to Dan. They still
        // need words rather than a crash, because a switch that cannot answer for every value is a trap
        // waiting for the first caller who does not know the rule.
        case .wentBy: return "\(org) went by before it was triaged."
        case .tooFar: return "\(org) is in a town you asked not to see."
        }
    }

    // #2395: taking an ending back. Names the ending being removed, because the control that offers this
    // sits on a card showing several facts and "Reopened" alone would not say which one went.
    static func reopenedLine(_ outcome: ShowOutcome, org: String) -> String {
        "\(org) is open again. \"\(outcome.label)\" is no longer recorded against it."
    }

    // What the reopen control is called. A question about the show, not about a contact, because that is
    // where the ending lives now.
    static let reopenLabel = "Reopen this show"

    // #2395: what Dan is told when an ending is refused because the show cannot have reached it. Says
    // which fact decided it, since the answer depends on something not visible in the menu he used: an
    // email either went out for this show or it did not.
    static func refusedLine(_ outcome: ShowOutcome, org: String, wasPitched: Bool) -> String {
        if outcome.isOverturesOwn {
            return "\"\(outcome.label)\" isn't yours to set: Overture writes that one itself. "
                + "\(org) is unchanged."
        }
        return wasPitched
            ? "\(org) was already pitched, so \"\(outcome.label)\" doesn't apply to it. Nothing changed."
            : "Nothing was ever sent for \(org), so \"\(outcome.label)\" doesn't apply to it. "
                + "Nothing changed."
    }
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
    // #2396: how a recorded ending reads as a show's status. The READER side of the fact, replacing the
    // writer-side mirror #2395 used while the surfaces still read contacts: one home for the ending, and
    // every reader goes to it rather than needing a copy written next to them.
    //
    // Nil for the never-pitched seven and for Overture's own two, and that is not a gap: none of them says
    // anything about a pitch, so none may be read as a pitch outcome. Those shows are spoken for by being
    // dismissed, which Archive gives its own bucket.
    var asPerformanceStatus: PerformanceStatus? {
        switch self {
        case .booked: return .booked
        // A silence leaves the door open exactly as a soft no does. A distinct RECORD, so the reporting can
        // tell "they said not now" from "nobody answered", and the same STATUS, because neither is a refusal.
        case .neverHeardBack, .theySaidNotNow: return .lostDoorOpen
        case .theySaidNo: return .lostNotInterested
        case .turnedThemDown: return .stoodDown
        case .dateConflict, .hadPaidWork, .pitchingOtherShows, .tooSoon, .notAFit, .dontWantToShoot,
             .duplicate, .wentBy, .tooFar:
            return nil
        }
    }

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
