import Foundation

// #3324, plan section 2: which nights of a run Dan judged, and how.
//
// A run card holds many nights, and "pitch every night" was the only thing the app could record. Dan's
// answers, 2026-09-17: the default is pitch every night and the choice is RECORDED (1); unticking a
// night is NOT a dismissal and never enters his four reasons or the #16 funnel (9). So there are two
// new lists beside `droppedRunNights`, which is untouched and stays the card level dismissal record:
//
//   pitchedRunNights   nights he is offering
//   skippedRunNights   nights he passed on, with no reason and no funnel membership
//
// The picker never calls `RunNightDrop.dropNight`. That function takes a non-optional `ShowOutcome`, and
// a tick box carries none of Dan's reasons: routing through it would either mint a reason he never gave
// or put an untick into the funnel, which is the #2691 defect this whole area exists to prevent.
struct NightDecision: Equatable, Sendable {

    // What a tick MEANS (plan 2.3). With the picker closed, one keypress on a 28 night run writes 28
    // entries, and those must never read back as 28 nights he looked at. So the decision carries how it
    // was made, IN the entry rather than as a flag on the row beside it (L544): a run can be committed
    // closed once and opened later, and only the nights present at each moment are covered by each.
    //
    // Every reader states which it accepts. The drafter takes both. Anything asserting to Dan that he
    // JUDGED a night may use `chosen` only.
    enum Origin: String, Equatable, Sendable, CaseIterable {
        case byDefault = "default"   // committed without the picker being opened
        case chosen                  // he opened it and this is what he left
    }

    var night: String          // yyyy-MM-dd
    var at: Date
    var origin: Origin
    // #3961 / plan 2.5: set only on a PITCHED night that the calendar blocked at the moment he ticked it
    // anyway: the deciding day's key, exactly as `BlockedCalendar.Day.key` spells it. On the #718 pattern,
    // so a clash that CHANGES under him (a different shoot booked over the night) no longer matches what he
    // accepted and blocks that night again. The card's single `conflictClearedKey` cannot hold this: one
    // `String?` for a run where 16 of 89 live runs carry two or more blocked nights would let the second
    // override silently overwrite the first.
    var acceptedClashKey: String?

    init(night: String, at: Date, origin: Origin, acceptedClashKey: String? = nil) {
        self.night = night
        self.at = at
        self.origin = origin
        self.acceptedClashKey = acceptedClashKey
    }

    // MARK: The stored form, and why it is read with a MINIMUM arity
    //
    // "night|epoch|origin", then any number of "name=value" fields. `DroppedNight` beside this requires
    // EXACTLY three fields and returns nil otherwise, which is why this record needed whole new columns
    // rather than a fourth field there (L501, and L255, whose evidence in this repo is
    // `DownbeatBridge.supportedVersions` never getting the version range fix). Cloning that parser as
    // first written would force another column the first time this record needs one more fact.
    //
    // So: at least three fields, and trailing fields are NAMED. An unknown name is ignored rather than
    // refusing the entry, so a value written by a newer build still reads here as the decision it is. The
    // accepted clash key is free text (a shoot's name comes from another app and can hold anything), so
    // its value is percent-encoded and can never be mistaken for a separator.
    //
    // An OLDER build cannot see these columns at all and treats every judged night as simply present.
    // That is a degradation, stated here rather than promised away: nothing written by this build can be
    // honoured by one that predates it (L267).
    static let separator: Character = "|"
    private static let acceptedField = "accepted"

    var stored: String {
        var parts = [night, String(Int(at.timeIntervalSince1970)), origin.rawValue]
        if let acceptedClashKey {
            parts.append("\(Self.acceptedField)=\(Self.encode(acceptedClashKey))")
        }
        return parts.joined(separator: String(Self.separator))
    }

    // Nil on an entry that cannot be read at all, and the night then reads as UNJUDGED. That is the safe
    // direction and it is the one `DroppedNight` reasons its way to as well: Dan is asked again, rather
    // than having a decision invented for him.
    init?(stored raw: String) {
        let parts = raw.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3,
              !parts[0].isEmpty, EasternDate.date(from: parts[0]) != nil,
              let seconds = TimeInterval(parts[1]),
              let origin = Origin(rawValue: parts[2]) else { return nil }
        var accepted: String?
        for field in parts.dropFirst(3) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0] == Self.acceptedField else { continue }   // unknown: ignored
            accepted = String(pair[1]).removingPercentEncoding
        }
        self.init(night: parts[0], at: Date(timeIntervalSince1970: seconds), origin: origin,
                  acceptedClashKey: accepted)
    }

    private static let valueCharacters: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "|=%&")
        return set
    }()

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: valueCharacters) ?? value
    }

    static func all(_ raw: [String]) -> [NightDecision] { raw.compactMap { NightDecision(stored: $0) } }
}

// Plan 2.4: one night, one state.
//
// Four memberships, each independent in storage: `runNights`, the two new lists, and `droppedRunNights`.
// The state space is written out here, rather than inferred at each reader, because the obvious reading
// ("runNights minus the two lists") is right only by accident and an opening-night drop already writes
// OTHER nights into `droppedRunNights` as `.duplicate` releases.
//
// | in runNights | pitched | skipped | dropped | state                                                   |
// | yes          | no      | no      | no      | unjudged                                                |
// | yes          | yes     | no      | no      | pitched                                                 |
// | yes          | no      | yes     | no      | skipped                                                 |
// | any          | any     | any     | yes     | dropped (the writer removes pitch or skip in that write)|
// | no           | either  | either  | no      | gone from the feed, entries RETAINED as evidence (2.6)  |
// | yes          | yes     | yes     | no      | contradictory: refused by the writer, read as unjudged  |
//
// A night in no list and not in `runNights` is not a night of this run at all.
enum NightState: Equatable, Sendable {
    case unjudged
    case pitched(NightDecision)
    case skipped(NightDecision)
    case dropped
    case goneFromFeed(pitched: NightDecision?, skipped: NightDecision?)
    // Both lists hold the night. The writer below refuses to produce this, so it can only come from a
    // store edited by something else. It is its own state rather than folded into either side, and every
    // reader treats it as unjudged, which asks Dan again rather than picking an answer for him.
    case contradictory
    case notInRun
}

extension Prospect {

    var pitchedNightDecisions: [NightDecision] { NightDecision.all(pitchedRunNights) }
    var skippedNightDecisions: [NightDecision] { NightDecision.all(skippedRunNights) }

    func nightState(_ night: String) -> NightState {
        if DroppedNight.all(on: self).contains(where: { $0.night == night }) { return .dropped }
        let pitched = pitchedNightDecisions.last { $0.night == night }
        let skipped = skippedNightDecisions.last { $0.night == night }
        let playing = playingNights.recordedNights ?? []
        guard playing.contains(night) else {
            if pitched == nil && skipped == nil { return .notInRun }
            return .goneFromFeed(pitched: pitched, skipped: skipped)
        }
        switch (pitched, skipped) {
        case (nil, nil): return .unjudged
        case (let p?, nil): return .pitched(p)
        case (nil, let s?): return .skipped(s)
        case (_?, _?): return .contradictory
        }
    }

    // The nights of this run nobody has judged yet, in date order. ENUMERABLE rather than merely
    // countable (L507), because Phase 5's new-nights marker has to name them and offer them for judging.
    var unjudgedNights: [String] {
        (playingNights.recordedNights ?? []).filter {
            switch nightState($0) {
            case .unjudged, .contradictory: return true
            default: return false
            }
        }
    }

    enum NightDecisionRefusal: Error, Equatable {
        case notANightOfThisRun(String)   // not in `runNights`, so there is nothing to judge
        case dropped(String)              // dismissed at card level; the dismissal decides, not a tick
        case decidedTwice(String)         // the same night in one commit twice: pitched AND skipped
    }

    // The one writer of both lists (plan 2.4: precedence enforced at WRITE time, not resolved at read).
    //
    // All or nothing. Every decision is checked before the first write, so a refusal leaves the row
    // exactly as it was rather than half committed (the #2754 order `dropNight` already keeps).
    //
    // A night decided again REPLACES its entry in both lists, so a night moved from pitched to skipped is
    // in exactly one of them afterwards, and re-committing the same choice does not grow the list. Nights
    // this commit does not mention are left alone: a night that has left the feed keeps its entry as
    // evidence of a decision already made (2.6).
    func recordNightDecisions(pitched: [NightDecision], skipped: [NightDecision]) throws {
        let playing = Set(playingNights.recordedNights ?? [])
        let dropped = Set(DroppedNight.all(on: self).map(\.night))
        var seen = Set<String>()
        for decision in pitched + skipped {
            guard seen.insert(decision.night).inserted else {
                throw NightDecisionRefusal.decidedTwice(decision.night)
            }
            guard !dropped.contains(decision.night) else { throw NightDecisionRefusal.dropped(decision.night) }
            guard playing.contains(decision.night) else {
                throw NightDecisionRefusal.notANightOfThisRun(decision.night)
            }
        }
        // The first write. Everything above is checks.
        pitchedRunNights = pitchedRunNights.filter { raw in
            NightDecision(stored: raw).map { !seen.contains($0.night) } ?? true
        } + pitched.map(\.stored)
        skippedRunNights = skippedRunNights.filter { raw in
            NightDecision(stored: raw).map { !seen.contains($0.night) } ?? true
        } + skipped.map(\.stored)
    }

    // Plan 3.8 / L574: an undo restoring fewer fields than the action changed is not its inverse. A night
    // drop removes that night's decision entries, so the drop's undo has to put them back, and it can only
    // do that from what the lists held BEFORE the drop. Restored whole: the entry's `stillApplies`
    // precondition has already established that the row is as the drop left it.
    func restoreNightDecisions(_ lists: NightDecisionLists) {
        pitchedRunNights = lists.pitched
        skippedRunNights = lists.skipped
    }

    // Plan 2.4, the dropped row: a night that is dismissed at card level loses any pitch or skip entry IN
    // THE SAME WRITE, so a night can never be pitched and dropped at once. Called from `dropNight` for
    // Dan's own night and for every night the walk released to another card.
    func forgetNightDecisions(for nights: [String]) {
        let gone = Set(nights)
        guard !gone.isEmpty else { return }
        pitchedRunNights = pitchedRunNights.filter { raw in
            NightDecision(stored: raw).map { !gone.contains($0.night) } ?? true
        }
        skippedRunNights = skippedRunNights.filter { raw in
            NightDecision(stored: raw).map { !gone.contains($0.night) } ?? true
        }
    }
}

// Both lists as they stood at one moment, for an undo to put back (plan 3.8). Values only, never the
// model, for the reason `QueueUndoEntry` gives.
struct NightDecisionLists: Equatable, Sendable {
    let pitched: [String]
    let skipped: [String]

    @MainActor
    init(_ p: Prospect) {
        pitched = p.pitchedRunNights
        skipped = p.skippedRunNights
    }
}
