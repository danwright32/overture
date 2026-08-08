import Foundation
import SwiftData

// #1657: put each stored fit reason back in step with the row it describes.
//
// `fitReason` is a SNAPSHOT written when a show was last classified, and a source whose page bytes have
// not changed is skipped entirely, so changing the sentence in `EventClassifier` alone would leave the old
// one sitting on an arbitrary, slowly shrinking subset of the queue for weeks. Dan would see one wording
// on some cards and another on the rest, with nothing on the card to explain the difference. That is
// exactly what `CatchAllFitReasonMigration` was written for, and this is the same shape.
//
// Measured on the live store 2026-07-28, stored `ZFITREASON` by genre word: theater 67, music 29, opera
// 23, music-short 20, other-short 11, other 10, dance 5, choral 1, band 1. The 21 rows naming "other" read
// "Self-produced other group, a strong-fit target", and one row still names "choral", a genre #350 folded
// into music while leaving the sentence behind. Both are the same defect: a sentence that outlived the
// axes it was drawn from.
//
// RECOMPUTED, never pattern-matched. `EventClassifier.derived` is the one place a reason comes from, and
// it takes exactly the four things this row already stores, so a realigned row and a freshly scouted one
// cannot disagree about what the same axes imply. A migration that instead rewrote known strings would be
// a second copy of the templates, drifting from the first the day either changed.
//
// Idempotent BY CONSTRUCTION rather than by a flag: the condition is "the stored sentence differs from the
// one this row's own axes produce", and the pass writes that sentence, so a second run is a no-op.
//
// Deliberately does NOT touch a row whose reason is empty. Empty is a decision (#1600 retired the
// catch-all sentence and put nothing in its place, and the row hides an empty line), so resurrecting a
// sentence there would undo a shipped choice on 499 rows.
enum FitReasonRealignment {

    @discardableResult
    static func run(in context: ModelContext) -> Int {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var changed = 0
        for p in prospects where !p.fitReason.isEmpty {
            let discipline = Discipline(rawValue: p.discipline) ?? .other
            let production = Production(rawValue: p.production) ?? .unknown
            let profile = Profile(rawValue: p.profile) ?? .neutral
            let derived = EventClassifier.derived(discipline: discipline, production: production,
                                                  profile: profile, venue: p.venue)
            guard derived.fitReason != p.fitReason else { continue }
            // Nothing is written where the row's own axes produce no sentence at all: that would be this
            // pass CLEARING a line rather than realigning it, which is a different decision from the one
            // it was given.
            guard !derived.fitReason.isEmpty else { continue }
            p.fitReason = derived.fitReason
            changed += 1
        }
        return changed
    }
}
