import Foundation

// One implementation of log rotation, shared by every append-only log the app keeps (#608). It was
// written for the resident agent's stdout/stderr (#295) and then needed again for the store-backup
// log, so it lives here rather than being copied.
//
// A long-lived app cannot grow a log without limit, and the logs that bite are precisely the ones too
// small to notice: the backup log gains a few dozen bytes per launch, which is nothing until it is
// years of launches and nobody ever looked.
//
// #3789: it now REPORTS, and a caller cannot drop the report by accident. Five call sites cover eight
// files between them (the agent's four, the store backup log, the prep run log, the feed movement log
// and the card divergence log), and every one of them used to invoke `cap` as a bare statement under a
// `@discardableResult`. So a rotation that moved a whole file's history into a `.1` and a launch where
// nothing happened at all left the same trace, which is none (L98, L11). The attribute is gone: the
// compiler now makes each caller say what it does with the answer, which is the only form of this rule
// that survives the next call site being added (L621, L27).
enum LogRotation {

    // What one rotation COST, measured as it happened rather than inferred afterwards.
    //
    // `discardedBytes` is the number this report exists for. The mechanism keeps exactly ONE previous
    // generation, so a second rotation deletes the `.1` the first one wrote, and nothing recorded that
    // those bytes had ever existed. It is nil when there was no previous generation, which is a
    // different fact from a previous generation of zero bytes and is kept apart from it.
    struct Rotation: Equatable {
        let file: URL
        let backup: URL
        let movedBytes: Int
        let discardedBytes: Int?
    }

    // A file over its cap that was LEFT ALONE, and why. Its own outcome rather than silence, because a
    // file under the cap and a file that could not be rotated are different states and only one of them
    // needs looking at (L11).
    struct Refusal: Equatable {
        enum Reason: Equatable {
            // The `.1` copy did not land, so emptying the live file would have destroyed content held
            // nowhere else.
            case backupCouldNotBeWritten
            // The `.1` copy landed, but the live file could not be emptied, so it is still over its cap
            // and the same bytes are now in both files.
            case liveFileCouldNotBeEmptied(movedBytes: Int)
        }

        let file: URL
        let reason: Reason
    }

    struct Report: Equatable {
        var rotated: [Rotation] = []
        var refused: [Refusal] = []

        var isEmpty: Bool { rotated.isEmpty && refused.isEmpty }

        // Whether anything was actually LOST, as opposed to moved. The first roll of a diagnostic log
        // loses nothing (every byte of it is in the `.1`), so this is what separates "a log rolled",
        // which is these logs working as designed, from "a generation is gone", which is not. The
        // surfaces that interrupt Dan speak on this and stay silent otherwise, which is the rule
        // `FreezeHousekeepingCopy` already states for the freeze log's own bookkeeping.
        var lostSomething: Bool {
            rotated.contains { $0.discardedBytes != nil } || !refused.isEmpty
        }

        // One sentence per event, in the order they happened, for a caller to write into the log itself.
        var notes: [String] { rotated.map(note(for:)) + refused.map(note(for:)) }

        // Only the events that LOST something. Separate from `notes` because the two have different
        // audiences: the log itself records every rotation, since a reader of a truncated file needs to
        // know it is truncated either way, while a surface that interrupts Dan speaks only about what is
        // gone. A caller handed `notes` where it wanted these would raise the menu bar nudge on every
        // ordinary roll (L36).
        var lossNotes: [String] {
            rotated.filter { $0.discardedBytes != nil }.map(note(for:)) + refused.map(note(for:))
        }
    }

    // copy-inventory:ignore-start  lines written INTO a diagnostic log file, never the app's voice on screen
    static func note(for rotation: Rotation) -> String {
        let moved = "moved \(rotation.movedBytes) bytes into \(rotation.backup.lastPathComponent)"
        guard let discarded = rotation.discardedBytes else {
            return "log rotation: \(moved). Nothing older was being kept, so nothing was lost."
        }
        return "log rotation: \(moved), and deleted the \(discarded) bytes it was holding from the "
            + "rotation before. That older content is gone."
    }

    static func note(for refusal: Refusal) -> String {
        switch refusal.reason {
        case .backupCouldNotBeWritten:
            return "log rotation: this file is over its cap, but the copy beside it could not be "
                + "written, so it was left alone rather than emptied. It will keep growing until that works."
        case .liveFileCouldNotBeEmptied(let movedBytes):
            return "log rotation: \(movedBytes) bytes were copied aside, but this file could not be "
                + "emptied, so it is still over its cap and those bytes are now in both files."
        }
    }
    // copy-inventory:ignore-end

    // Bound each file to maxBytes, logrotate "copytruncate" style: when a file is over the cap, copy
    // it to a single ".1" backup (replacing any prior one), then truncate the LIVE file in place to
    // zero.
    //
    // Truncating in place rather than renaming is load-bearing for the agent's logs: launchd opens
    // them in append mode before the agent starts and holds them open for its whole life, so the
    // agent keeps writing to the same inode and resumes at the new end after truncation. A rename
    // would orphan every subsequent write onto the backup file, where nobody would ever read it.
    //
    // Best-effort and idempotent. A file that is missing, or one this process cannot open, is simply
    // left alone: a log that cannot be rotated is not worth failing a launch over.
    //
    // #3789: what it will NOT do any more is empty a file whose backup did not land. The copy was a
    // `try?` whose failure was swallowed and the truncation ran regardless, so the one case where the
    // backup matters most (a directory gone read-only, a full disk) was the case that destroyed the
    // content outright with no copy of it anywhere (L5, L105). Measured on this Mac, 2026-09-11, with
    // the containing directory at 0o500 and a 4,096 byte log over a 1,024 byte cap: the live file came
    // back 0 bytes and no `.1` existed. The copy is now confirmed present and the same size as the
    // source before anything is emptied, which is the order #3763 settled on for the freeze archive:
    // write the copy, and abandon the rewrite when it failed.
    //
    // WHO READS A `.1`. `scripts/what-the-log-lost.sh`, shipped with this change, and that is the whole
    // answer: nothing in the APP reads one, deliberately, because none of these logs is a file the app
    // itself consults. They are read by a person diagnosing something afterwards, and the store backup
    // log (the record of whether Dan's live store was copied) has twice been read days after the
    // incident it covers. A preserved copy with no reader is a write-only file (L46), so the reader
    // ships here rather than being left to whoever remembers the convention.
    static func cap(files: [URL], maxBytes: Int, fileManager: FileManager = .default) -> Report {
        var report = Report()
        for file in files {
            guard let live = byteSize(of: file, fileManager), live > maxBytes else { continue }
            let backup = file.appendingPathExtension("1")
            let incoming = backup.appendingPathExtension("incoming")
            // A leftover `incoming` is always a DUPLICATE of content that still exists somewhere: the
            // live file is emptied only after the backup is in place, so a run interrupted before that
            // left the live file whole, and one interrupted after it left no `incoming` at all. That is
            // what makes removing it safe without reading it.
            try? fileManager.removeItem(at: incoming)
            try? fileManager.copyItem(at: file, to: incoming)
            // The copy's size READ BACK OFF DISK. `copyItem` not throwing is not the same fact as a
            // complete copy sitting there, and this is the only check standing between the rotation and
            // the content it is about to clear.
            guard byteSize(of: incoming, fileManager) == live else {
                try? fileManager.removeItem(at: incoming)
                report.refused.append(Refusal(file: file, reason: .backupCouldNotBeWritten))
                continue
            }
            // Measured BEFORE the removal, because afterwards the only record of what that generation
            // held is gone, which is the loss this report exists to name.
            let discarded = byteSize(of: backup, fileManager)
            try? fileManager.removeItem(at: backup)
            try? fileManager.moveItem(at: incoming, to: backup)
            guard byteSize(of: backup, fileManager) == live else {
                report.refused.append(Refusal(file: file, reason: .backupCouldNotBeWritten))
                continue
            }
            guard let handle = try? FileHandle(forWritingTo: file) else {
                report.refused.append(Refusal(file: file,
                                              reason: .liveFileCouldNotBeEmptied(movedBytes: live)))
                continue
            }
            let emptied = (try? handle.truncate(atOffset: 0)) != nil
            try? handle.close()
            guard emptied else {
                report.refused.append(Refusal(file: file,
                                              reason: .liveFileCouldNotBeEmptied(movedBytes: live)))
                continue
            }
            report.rotated.append(Rotation(file: file, backup: backup, movedBytes: live,
                                           discardedBytes: discarded))
        }
        return report
    }

    private static func byteSize(of file: URL, _ fileManager: FileManager) -> Int? {
        (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
    }
}
