import Foundation

// Pure aggregation of outreach outcomes, the foundation for the deferred fit-score
// feedback loop (#4) and an outcome-patterns view. Counts only CONTACTED prospects
// (those actually sent), so un-touched ones never skew the numbers. No auto-tuning
// here yet: this just turns recorded outcomes into honest tallies Dan can read.

struct OutcomeTally: Equatable, Sendable {
    var contacted = 0
    var replied = 0
    var booked = 0
    var lost = 0
    var noResponse = 0
    // #2399: never pitched is its OWN group, not folded into lost. Dan: "I don't think we should count
    // scouted but not pitched as 'lost'. I do think it's worth counting though."
    var neverPitched = 0
    // Why each group ended the way it did. Kept apart because the reasons are the report: "they said no"
    // and "nobody answered" are different facts, and how many strong shows Dan drops purely for want of a
    // night (#16) is a question only answerable if that reason stays its own number.
    var neverPitchedReasons: [ShowOutcome: Int] = [:]
    var lostReasons: [ShowOutcome: Int] = [:]
    // The endings Overture wrote for itself: a show whose date passed untriaged, and one in a town Dan
    // blocked. Neither is a judgement he made, so neither belongs in a reported group, but they are counted
    // here rather than dropped: without this the three groups would silently fail to add up to the shows
    // that ended and nobody reading the report could tell.
    var overturesOwn = 0
    // The booked split by where the booking came from (#117): auto-detected from an exact
    // Downbeat match (#99) versus confirmed by Dan himself (#114). Sums to `booked` once every
    // booking carries a source; legacy rows with no recorded source land in neither bucket.
    var bookedAuto = 0
    var bookedManual = 0

    // The rates below are all over `contacted`, which counts shows an email provably went out for, while
    // `booked` and `lost` count every show carrying that ending. Those agree by construction since #2395:
    // `recordOutcome` refuses a pitched ending on a show nothing was sent to, so the only way they can
    // disagree is a legacy row that predates the guard.
    //
    // Booked over contacted. Nil when nothing has been contacted (avoid 0/0 lies).
    var bookingRate: Double? {
        contacted == 0 ? nil : Double(booked) / Double(contacted)
    }
    // The booking rate driven by hard Downbeat matches versus Dan's own calls, both over
    // contacted, so a wrong attribution can't silently distort the headline rate. Nil when
    // nothing has been contacted.
    var autoBookingRate: Double? {
        contacted == 0 ? nil : Double(bookedAuto) / Double(contacted)
    }
    var manualBookingRate: Double? {
        contacted == 0 ? nil : Double(bookedManual) / Double(contacted)
    }
    // Any engagement (replied or booked) over contacted.
    var responseRate: Double? {
        contacted == 0 ? nil : Double(replied + booked) / Double(contacted)
    }
}

// A minimal view of a prospect for tallying, so the stats are testable without
// SwiftData. `wasContacted` is true once it reached approved/sent.
struct OutcomeSample: Sendable {
    var wasContacted: Bool
    var outcome: Outcome
    var dimension: String  // e.g. "agency" / "self", or a discipline, for grouping
    var outcomeSource: OutcomeSource? = nil  // how a booking was counted: auto match vs Dan's call (#117)
    // #2399: how the show ENDED, from the one field (#2394). This is what the groups below are counted
    // from. `outcome` above is the legacy field, still read for the source split and for the replied case
    // while an open pitch has no ending of its own.
    //
    // Nil means the show has not ended, and an ended show is the only kind that can be reported: counting
    // an open pitch would file every live one as closed on the day the report is read.
    var showOutcome: ShowOutcome? = nil
    // Whether anybody wrote back, for an open pitch. A reply is not an ending (Dan may still be mid
    // conversation), but "somebody answered" and "silence" are different states of the same open pitch and
    // the report has always told them apart.
    var aContactReplied: Bool = false
}

enum OutcomeStats {
    static func tally(_ samples: [OutcomeSample]) -> OutcomeTally {
        var t = OutcomeTally()
        for s in samples {
            // The three groups are counted from the RECORDED ending, whatever the send record says, because
            // the report's job is to say what happened rather than to re-judge it. A legacy row can be
            // pitched and still carry a never-pitched reason, since the two used to be recorded
            // independently; it is counted as what it says.
            switch s.showOutcome?.group {
            case .booked:
                t.booked += 1
                switch s.outcomeSource {
                case .auto: t.bookedAuto += 1
                case .manual: t.bookedManual += 1
                case nil: break  // no recorded source (legacy): counted, but unattributed
                }
            case .pitchedAndLost:
                t.lost += 1
                if let o = s.showOutcome { t.lostReasons[o, default: 0] += 1 }
            case .neverPitched:
                t.neverPitched += 1
                if let o = s.showOutcome { t.neverPitchedReasons[o, default: 0] += 1 }
            case nil:
                // Either Overture's own ending, or no ending at all. `group` is nil for both, so they are
                // told apart by whether a value is there: one is a show that ended in a way Dan did not
                // choose, the other is a show that has not ended.
                if s.showOutcome != nil { t.overturesOwn += 1 }
            }

            // The pitched-side rates are about shows an email actually went out for, so they still count on
            // `wasContacted`, and an OPEN pitch is the only thing left to describe here: an ended one has
            // already landed in one of the groups above.
            guard s.wasContacted else { continue }
            t.contacted += 1
            if s.showOutcome == nil {
                if s.aContactReplied || s.outcome == .replied { t.replied += 1 } else { t.noResponse += 1 }
            }
        }
        return t
    }

    // Tally split by a dimension (production type, discipline, tier...), so patterns
    // like "competition recitals: 0 booked of 9 contacted" become visible.
    static func tallyByDimension(_ samples: [OutcomeSample]) -> [String: OutcomeTally] {
        var groups: [String: [OutcomeSample]] = [:]
        for s in samples { groups[s.dimension, default: []].append(s) }
        return groups.mapValues(tally)
    }
}
