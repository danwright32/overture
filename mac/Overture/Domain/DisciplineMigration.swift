import Foundation
import SwiftData

// #350: Choral folded into Music, one editorial taxonomy decision, not a scoring change for
// already-queued items. One-time, idempotent: guarded by "any prospect still stored as choral",
// so a no-op on every launch after the first real migration. Deliberately does NOT recompute
// fitScore/tier (Dan's call): existing prospects keep their historical score, only newly scouted
// events use Music's updated point value (Ranker.disciplinePoints).
enum DisciplineMigration {
    static func run(in context: ModelContext) {
        let descriptor = FetchDescriptor<Prospect>(predicate: #Predicate { $0.discipline == "choral" })
        guard let matches = try? context.fetch(descriptor), !matches.isEmpty else { return }
        for p in matches { p.discipline = "music" }
    }
}
