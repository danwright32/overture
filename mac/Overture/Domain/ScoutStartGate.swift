import Foundation

// #2208: may this scout start, and if not, what does Dan need to know?
//
// Pressing Run scout while a previous read was still going swept all 68 sources, fetched and hashed
// them, worked out which had changed, and only then discovered it could not hand them off, reporting "A
// previous run is still reading pages. The pages that changed will be read on the next scout."
//
// Nothing was lost and nothing was spent (the sweep is free), but Dan sat through a run whose main
// purpose could not happen, and the sentence that finally explained it said neither what to do nor when.
// Observed 2026-08-06.
//
// The condition is knowable before the sweep starts: `ScoutExtractService.isRunning` reads the same
// marker that would refuse the hand-off at the end. RootView's own guard already checks
// `readingStartedAt`, but that goes nil once the takeover is hidden and the app has moved on, so it does
// not catch a read still running in the background, which is exactly the case here.
//
// Refusing rather than starting a fetch-only run, deliberately. A run that cannot do the thing it is for
// is not worth several minutes of Dan's attention, and the free daily watch pass has already fetched and
// hashed everything overnight, so a manual fetch-only run adds almost nothing. What he gets instead is a
// sentence naming what is happening and when to press again.
enum ScoutStartGate {
    enum Decision: Equatable {
        case start
        // Do not sweep. The sentence names what is going on and what to do about it.
        case waitForTheReader(String)
    }

    static func decide(readerIsRunning: Bool, depth: ScoutDepth, auto: Bool,
                       remaining: TimeInterval? = nil) -> Decision {
        // The free daily watch pass NEVER hands off (it is fetch and hash only), so a read in flight
        // costs it nothing and it must not be blocked by one. Blocking it would stop the one thing that
        // notices a dead source within a day.
        guard depth == .readChanged else { return .start }
        // A run Dan did not start has no one to tell, and refusing it quietly would be a scheduled run
        // silently not happening (L13). Only a press is refused, because only a press has somebody
        // waiting on the answer.
        guard !auto else { return .start }
        guard readerIsRunning else { return .start }
        return .waitForTheReader(message(remaining: remaining))
    }

    // Says the three things in order: what is happening, why pressing again now would not help, and when.
    //
    // The estimate is included ONLY when the learned pace has one to give. A guessed "about a minute"
    // would be the app claiming something it has not measured (L11), on the one sentence whose entire job
    // is to tell Dan when to come back.
    static func message(remaining: TimeInterval?) -> String {
        let head = "Overture is still reading the pages the last scout found, so a new scout could fetch "
            + "but not read anything."
    //
    // Under a minute is left out for the same reason: the shared duration buckets round it to "0m", and a
    // sentence saying a run has about no time left, next to a button that will not work yet, reads as the
    // app contradicting itself.
        guard let remaining, remaining >= 60 else {
            return head + " Press Run scout again once the reading finishes."
        }
        return head + " It has about \(PrepStatus.duration(seconds: remaining)) left. "
            + "Press Run scout again once it finishes."
    }
}
