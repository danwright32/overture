import Foundation

// #4107: how long each pass of one reconcile tick took, recorded on every tick rather than only when
// somebody happens to be sampling.
//
// The freeze sample that opened #4107 could say the tick was 14% of the main thread during one freeze,
// and nothing else could: no running build said which pass cost what, so the only way to ask was to
// catch a tick in a stack sample. This is written once per tick, to the system log through
// `AgentLog.note`, so `log show --predicate 'process == "Overture"'` answers it for any tick after the
// fact.
//
// Two kinds of pass, told apart in the line rather than folded together (L11). A pass that never awaits
// holds the main actor for exactly its duration, so its number IS main actor time. A pass that awaits
// (Gmail, OmniFocus) gives the main actor back while it waits, so its wall time is an UPPER BOUND on what
// it held, and the line marks it `~` so nobody reads a slow Gmail response as a freeze.
struct ReconcileTickTimeline: Equatable, Sendable {
    // Every pass the tick runs, in the order it runs them. CaseIterable so a test can hold that every one
    // is recorded: a pass that is never timed would read as costing nothing (L90).
    enum Phase: String, CaseIterable, Sendable {
        case readRows            // the one whole store read the rest share
        case bookings
        case conflicts
        case feedFreshness
        case retirement
        case replyCheck          // awaits Gmail
        case threadingRepair     // awaits Gmail
        case replyProposals      // awaits Gmail
        case signature           // awaits Gmail
        case omniFocus           // awaits the permission probe and the AppleScript
        case closingRead         // #4250: the fresh read the badge and away alert are counted from, off the
                                 // main actor (awaited) unless the main context held unsaved changes
        case closingCount        // publishing the badge and naming what arrived, from that reading

        var awaits: Bool {
            switch self {
            case .replyCheck, .threadingRepair, .replyProposals, .signature, .omniFocus, .closingRead: return true
            case .readRows, .bookings, .conflicts, .feedFreshness, .retirement, .closingCount: return false
            }
        }
    }

    // `awaited` is the phase's own `awaits` unless the tick says otherwise for THIS run. #4250: the closing
    // read is awaited when it runs off the main actor and a plain hold when it could not, and a hold marked
    // as waiting would drop out of `longestHold`, the one number that says what the tick held (L11).
    struct Entry: Equatable, Sendable {
        let phase: Phase
        let seconds: Double
        let awaited: Bool
    }

    private(set) var entries: [Entry] = []

    mutating func record(_ phase: Phase, seconds: Double, awaited: Bool? = nil) {
        entries.append(Entry(phase: phase, seconds: seconds, awaited: awaited ?? phase.awaits))
    }

    // The longest single stretch the tick is KNOWN to have held the main actor: the slowest pass that
    // never awaits. The awaiting passes are left out on purpose, since their wall time is mostly waiting.
    var longestHold: Entry? {
        entries.filter { !$0.awaited }.max { $0.seconds < $1.seconds }
    }

    // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
    var logLine: String {
        let parts = entries.map { e in
            "\(e.phase.rawValue) \(e.awaited ? "~" : "")\(Self.ms(e.seconds))"
        }
        let hold = longestHold.map { " (longest main actor hold: \($0.phase.rawValue) \(Self.ms($0.seconds)))" } ?? ""
        return "[Overture] reconcile tick, ms per pass, ~ includes waiting: " + parts.joined(separator: ", ") + hold
    }
    // copy-inventory:ignore-end

    private static func ms(_ seconds: Double) -> String { String(Int((seconds * 1000).rounded())) }
}
