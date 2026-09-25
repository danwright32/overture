import Foundation
import SwiftData

// #4136: close a show Dan KEPT whose last night passed before anything was sent.
//
// `WentByRetirement` sweeps an UNTRIAGED show once its run opens (#864, #1540), and deliberately leaves a
// kept one alone, because Dan chose it. Nothing then watched a kept show's date at all, so one whose
// performance was over went on being counted as Prep work, listed, handed to a paid run, and sent. His
// words on 2026-09-21: "if I have shows in the prep queue that have past, that should be obvious so I know
// to get rid of them." Asked on 2026-09-24 whether to offer that clean up or do it, he chose to sweep them
// automatically.
//
// Which shows, derived from the code rather than restated:
//   - `queued`, `drafted` and `approved` are the kept statuses on which nothing has been sent. `contacted`
//     means the pitch went out and is left alone, on the same rule that keeps `WentByRetirement` off
//     shows he pitched (ReachedOutClose.swift says the same of its own sweep).
//   - and never a show that `wasPitched`, which catches the one kept status that can carry a send: an
//     `approved` show with one contact emailed and another still pending. "Went by before it was pitched"
//     would be false of it. It stays in Review, where the send gate now refuses the pending contact and
//     the card says why (`DraftReviewNotes.performancePassed`).
//   - judged on the run's LAST night, never its opening one. A kept run that has opened keeps working
//     (#1540 kept the `underway` urgency for exactly that row), so the line for a kept show is the one the
//     "Performance passed" label is drawn on (`EasternDate.lastNightHasPassed`). An undated show has not
//     passed (#798).
//
// Nothing is deleted. The show is dismissed with `ShowOutcome.wentByUnpitched`, Overture's own ending,
// which is on no menu, in no reported group, and falls through `LocalHistory.records` to nothing, so it
// teaches the ranker nothing about the organisation. Archive files it with the `wentBy` shows and the row
// offers no Restore (`ShowOutcome.isCalendarRetirement`).
enum PassedKeptRetirement {
    // Returns how many shows it closed, so the caller can say what it actually did rather than assume.
    @discardableResult
    static func run(in context: ModelContext, today: String = EasternDate.today()) -> Int {
        let kept = FetchDescriptor<Prospect>(
            predicate: #Predicate { $0.statusRaw == "queued" || $0.statusRaw == "drafted"
                || $0.statusRaw == "approved" }
        )
        guard let candidates = try? context.fetch(kept) else { return 0 }

        // Idempotent by construction: a closed show is dismissed, so a second pass cannot see it.
        let passed = candidates.filter {
            !$0.wasPitched
                && EasternDate.lastNightHasPassed(performanceDate: $0.performanceDate,
                                                  runEndDate: $0.runEndDate, today: today)
        }
        for p in passed {
            p.markDismissed(reason: .wentByUnpitched)
        }
        return passed.count
    }
}
