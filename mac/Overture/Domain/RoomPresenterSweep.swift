import Foundation
import SwiftData

// #1845: the room-as-presenter guard, applied to rows ALREADY in the store.
//
// ExtractedEventGuard.presenterThatIsNotTheRoom (#1766/#1788) strips a room's name out of the presenter
// field, but it is a BOUNDARY guard: it runs as a show is read, so it has never reached a row written
// before it, and a hash-gated scout may not re-read a given show for weeks. That leaves the wrong fact
// sitting on Dan's screen in the meantime, and it is not a cosmetic one. The presenter field decides:
//
//   - the producer axes, since a name in it reads as a self-producing organisation, worth 8 points, which
//     is the whole of #1845's headline gap between two copies of one show;
//   - the genre, because the classifier reads "title + presenter" for its genre word, which is why a folk
//     music venue whose name contains "Theatre" had its shows stored as theater;
//   - and the PAID contact hunt, which is aimed at that field, so a room's name in it spends Dan's money
//     looking for a building's own inbox and comes home reading like an honest "nobody is reachable".
//
// LIVE-STORE-CLAIM verified=2026-08-02 measure="stored rows whose presenter reduces to their own venue under ProducerGate.key, and what they score"
// 101 of 723 rows on the live store carry a presenter this guard would strip today, among them Chain
// Theatre at 28, The Joyce Theater at 9 and The Players Theatre at 8, each ranked as a strong
// self-producing organisation when the name is the room's.
//
// Idempotent BY CONSTRUCTION rather than by a flag: the condition is "the presenter names this row's own
// venue", and the pass clears the presenter, so a swept row can never match again. Runs every launch for
// the same reason the merges do, since a later scout can write the name back.
//
// Deliberately reuses BOTH shipped paths rather than restating either: the guard itself decides what
// counts as the room (so this cannot drift from the boundary's own rule, or from ProducerGate's idea of
// when a name IS the room), and EventClassifier re-reads the axes (so a swept row and a freshly scouted
// one cannot disagree about what the same three facts imply).
enum RoomPresenterSweep {
    struct Summary: Equatable {
        var cleared = 0
    }

    @discardableResult
    static func run(in context: ModelContext, now: Date = Date()) -> Summary {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var summary = Summary()

        for p in prospects {
            guard let named = p.presenter, !named.isEmpty else { continue }
            let asRead = ExtractedEvent(title: p.groupName, presenter: named, venue: p.venue)
            let cleaned = ExtractedEventGuard.presenterThatIsNotTheRoom(asRead)
            guard cleaned.presenter == nil else { continue }

            // #2453: through the one write seam, so the provenance goes with the name. A room's name is
            // wrong in this field whoever wrote it, so this pass still clears a deliberate answer, but it
            // may not leave a stamp standing over an empty field claiming an answer is there.
            p.setPresenter(nil, from: .sweep)
            p.presenterWasTheRoom = true

            // Re-read from the row as the boundary now leaves it. Every axis the presenter fed has to
            // move with it: leaving `production` saying "self" under a presenter that is gone would keep
            // the 8 points the name earned and leave nothing on the row to explain them.
            let reread = EventClassifier.classify(cleaned)
            // #1533: a genre Dan corrected is his, and this pass is about the producer, not about
            // re-reading a decision he already made.
            if !p.classificationOverriddenByDan {
                GenreVisibility.write(reread.discipline, to: p)   // #1658
            }
            p.production = reread.production.rawValue
            p.profile = reread.profile.rawValue
            let settled = Discipline(rawValue: p.discipline) ?? reread.discipline
            let derived = EventClassifier.derived(discipline: settled,
                                                  production: reread.production,
                                                  profile: reread.profile,
                                                  venue: p.venue)
            p.coverage = derived.coverage.rawValue
            p.fitReason = derived.fitReason

            let refit = ClassificationOverride.rescored(p, now: now)
            p.fitScore = refit.score
            p.tier = refit.tier.rawValue
            summary.cleared += 1
        }

        return summary
    }
}
