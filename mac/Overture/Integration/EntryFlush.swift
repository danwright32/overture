import Foundation

// #4338 (A10): what one entry flush (`ScoutService.flushBeforeLanding`) did. Three answers rather than the
// refusal alone, because the landing that ran it counts the flushes that SAVED something on its record
// (`LandingRun.entryFlushSaves`), and "nothing was pending" is not a save.
enum EntryFlush: Equatable, Sendable {
    case nothingPending
    case saved
    case refused(LandingStop)

    var refusal: LandingStop? {
        if case .refused(let stop) = self { return stop }
        return nil
    }
}
