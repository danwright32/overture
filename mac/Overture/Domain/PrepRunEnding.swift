import Foundation

// #1613: how a detached run ENDED, which is a different question from whether one is running.
//
// The runner removes its own marker on the way out, so the marker's state at the moment a run stops
// being live already carries the answer, and DetachedRunner.heartbeat already reads it: ABSENT means the
// runner reached its exit and tidied up after itself, STALE means it stopped somewhere it never got to.
// Reusing that one reading rather than introducing a second liveness signal (a pid file, a second
// timestamp) is deliberate: two sources of truth about whether a process is alive can disagree, and a
// check whose two sides come from different lookups is the only kind that can actually be wrong in a way
// anyone notices (L70).
//
// This matters because the two endings deserve opposite treatment. A clean ending is reported by what
// the run produced. A death has produced nothing more and never will, so the honest thing is to say so
// and clear up, instead of offering Cancel, which writes a sentinel that only a LIVE runner ever reads
// and which therefore cannot do anything at all.
enum PrepRunEnding: Equatable, Sendable {
    case finished
    case died

    // nil while the run is still beating: it has not ended, and sweeping it here would kill a real
    // multi-prospect batch mid-write.
    static func of(heartbeat: RunHeartbeat) -> PrepRunEnding? {
        switch heartbeat {
        case .beating: return nil
        case .absent:  return .finished
        case .stale:   return .died
        }
    }
}

// What a swept dead run leaves to report. Kept as a value rather than a bare Bool so the paid half is
// carried with it: a check that died still researched shows Dan paid for, and dropping that silently is
// the thing #1809 exists to prevent.
struct DeadRunOutcome: Equatable, Sendable {
    // The settled check, when the dead run was a reachability check rather than a Prep. nil for a Prep.
    var probeReport: ReachabilityRunReport?
}
