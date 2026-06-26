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
    // The booked split by where the booking came from (#117): auto-detected from an exact
    // Downbeat match (#99) versus confirmed by Dan himself (#114). Sums to `booked` once every
    // booking carries a source; legacy rows with no recorded source land in neither bucket.
    var bookedAuto = 0
    var bookedManual = 0

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
}

enum OutcomeStats {
    static func tally(_ samples: [OutcomeSample]) -> OutcomeTally {
        var t = OutcomeTally()
        for s in samples where s.wasContacted {
            t.contacted += 1
            switch s.outcome {
            case .replied: t.replied += 1
            case .booked:
                t.booked += 1
                switch s.outcomeSource {
                case .auto: t.bookedAuto += 1
                case .manual: t.bookedManual += 1
                case nil: break  // no recorded source (legacy): counted, but unattributed
                }
            case .lostSoft, .lostHard: t.lost += 1
            case .noResponse: t.noResponse += 1
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
