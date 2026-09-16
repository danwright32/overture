import Foundation

// #3763: what Dan is told about the bookkeeping on his freeze log, as opposed to about the freezes
// themselves, which is `FreezeNoticeCopy`'s job.
//
// SEPARATE from the freeze notice on purpose. That one answers "did Overture stop responding" and this
// answers "what happened to the record of it", and they are different subjects. Folding this in as a fifth
// state would let a routine bookkeeping line displace a warning, which is the defect milestone #54 exists
// for.
//
// SILENT unless something was LOST or something REFUSED. A compaction that archived 200 records lost
// nothing and there is nothing to act on, so it says nothing: a notice that speaks on every launch is the
// noise that teaches a person to stop reading notices.
//
// COLD READ, 2026-09-11, each sentence rendered and read in the order a person meets it, and two of them
// were rewritten by it:
//
//   "The log will keep growing until that works" began as "until this clears", which describes a condition
//   clearing itself and this one does not: the archive keeps failing until somebody looks at why.
//
//   The prune's singular began as one sentence with a count in it and read "1 freeze records were deleted,
//   recorded between Aug 1, 2025 and Aug 1, 2025". Wrong twice: a plural with a 1 in it, and a span over a
//   set of one. It is its own sentence now, the same finding the cold read on `FreezeNoticeCopy.report`
//   made about a single freeze.
enum FreezeHousekeepingCopy {

    // Every applicable sentence, in a fixed order, most consequential first. Composed rather than chosen,
    // because an archive that failed and a prune that deleted are two different facts about one launch and
    // returning only the worse of them would leave a permanent deletion unsaid (L11).
    static func notice(_ done: FreezeLog.Housekeeping) -> String? {
        var sentences: [String] = []
        switch done.compaction {
        case .nothingToArchive, .archived:
            break
        case .archiveFailed:
            sentences.append(archiveFailed)
        }
        switch done.prune {
        case .nothingToRemove:
            break
        case .refused(let lines):
            sentences.append(pruneRefused(lines: lines))
        case .removed(let count, let earliest, let latest):
            sentences.append(pruned(count: count, earliest: earliest, latest: latest))
            // ITS OWN SENTENCE, appended here rather than interpolated into the one above. Glued in as
            // `\(kept)` it reached `docs/copy-inventory.md` as a line of Swift, so the cold read that file
            // exists for could not be done on it, which is the finding #2570 and #2548 already recorded
            // about exactly this shape.
            sentences.append(keepsAMonth)
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    static let archiveFailed =
        "Overture could not set aside the oldest freeze records, so it left the log alone rather than lose them. "
        + "The log will keep growing until that works."

    static func pruneRefused(lines: Int) -> String {
        if lines == 1 {
            return "A line in the freeze archive could not be read, so nothing was deleted from the archive."
        }
        return "\(lines) lines in the freeze archive could not be read, so nothing was deleted from the archive."
    }

    // ONE and SEVERAL are different sentences. A single record has no span, and "1 records" reads as a
    // plural somebody forgot to fix.
    static let keepsAMonth = "Overture keeps a month of them."

    static func pruned(count: Int, earliest: Date, latest: Date) -> String {
        if count == 1 {
            return "One freeze record was deleted from the archive, recorded on \(EasternDate.dayLabelWithYear(earliest))."
        }
        return "\(count) freeze records were deleted from the archive, recorded between "
            + "\(EasternDate.dayLabelWithYear(earliest)) and \(EasternDate.dayLabelWithYear(latest))."
    }
}
