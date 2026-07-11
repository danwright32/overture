import Foundation

// One implementation of log rotation, shared by every append-only log the app keeps (#608). It was
// written for the resident agent's stdout/stderr (#295) and then needed again for the store-backup
// log, so it lives here rather than being copied.
//
// A long-lived app cannot grow a log without limit, and the logs that bite are precisely the ones too
// small to notice: the backup log gains a few dozen bytes per launch, which is nothing until it is
// years of launches and nobody ever looked.
enum LogRotation {
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
    // left alone: a log that cannot be rotated is not worth failing a launch over. Returns the files
    // actually rotated, so a caller that wants to report or assert on it can.
    @discardableResult
    static func cap(files: [URL], maxBytes: Int, fileManager: FileManager = .default) -> [URL] {
        var rotated: [URL] = []
        for file in files {
            guard let size = try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int,
                  size > maxBytes else { continue }
            let backup = file.appendingPathExtension("1")
            try? fileManager.removeItem(at: backup)
            try? fileManager.copyItem(at: file, to: backup)
            guard let handle = try? FileHandle(forWritingTo: file) else { continue }
            defer { try? handle.close() }
            guard (try? handle.truncate(atOffset: 0)) != nil else { continue }
            rotated.append(file)
        }
        return rotated
    }
}
