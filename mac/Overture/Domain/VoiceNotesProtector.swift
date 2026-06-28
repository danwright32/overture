import Foundation

// Protects Dan's hand-written notes in overture-voice-guidance.md (#251 / #119). The "## Dan's notes"
// section is authoritative and the #242 workflow is told never to touch it, but that is only a prompt
// instruction. This makes the app the safety net: back the file up before a Prep run, and after the
// run restore the notes section from the backup if the run altered or dropped it — while keeping the
// freshly regenerated auto section. A misbehaving run can therefore never silently wipe Dan's notes.

enum VoiceNotesProtector {
    static let notesHeadingPrefix = "## Dan's notes"
    static let autoHeadingPrefix = "## Observed tendencies"

    // The "## Dan's notes" block (heading + body, up to the next `## ` heading or EOF). "" if absent.
    static func notesSection(of contents: String) -> String {
        section(of: contents, headingPrefix: notesHeadingPrefix)
    }

    // The "## Observed tendencies" block (heading + body to EOF). "" if absent.
    static func autoSection(of contents: String) -> String {
        section(of: contents, headingPrefix: autoHeadingPrefix)
    }

    private static func section(of contents: String, headingPrefix: String) -> String {
        let lines = contents.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix(headingPrefix) }) else { return "" }
        var block = [lines[start]]
        for line in lines[(start + 1)...] {
            if line.hasPrefix("## ") { break }
            block.append(line)
        }
        return block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Given the file as it stands after a run (`current`) and the pre-run `backup`, return the
    // contents with Dan's notes guaranteed intact. If the backup has a notes section and the current
    // file's notes differ from it (tampered or dropped), splice the backup's notes back in ahead of
    // the current auto section. Otherwise leave `current` untouched.
    static func protectedContents(current: String, backup: String) -> (contents: String, restored: Bool) {
        let backupNotes = notesSection(of: backup)
        guard hasSubstantiveBody(backupNotes) else { return (current, false) }
        // #254: only restore an actual WIPE (the notes section missing, or emptied to its heading). If
        // the section is still present with content — even if changed — treat it as Dan's own edit,
        // possibly made during an in-flight run, and leave it. (Time-based detection can't help: the
        // run rewrites the whole file every time, so the file is always "modified after run start".)
        guard !hasSubstantiveBody(notesSection(of: current)) else { return (current, false) }

        let auto = autoSection(of: current)
        let rebuilt = [backupNotes, auto].filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
        return (rebuilt, true)
    }

    // True if the notes block has real content beyond its heading (not missing, not heading-only).
    private static func hasSubstantiveBody(_ notesBlock: String) -> Bool {
        guard !notesBlock.isEmpty else { return false }
        let body = notesBlock.components(separatedBy: "\n").dropFirst()
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return !body.isEmpty
    }

    // Copy the guidance file aside before a run, so the post-run restore has a trusted reference.
    static func backup(fileURL: URL, backupURL: URL) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        try? data.write(to: backupURL, options: .atomic)
    }

    // After a run, restore Dan's notes from the backup if the run changed them. Returns whether a
    // restore happened (so the app can tell Dan).
    @discardableResult
    static func restoreIfNeeded(fileURL: URL, backupURL: URL) -> Bool {
        guard let current = try? String(contentsOf: fileURL, encoding: .utf8),
              let backup = try? String(contentsOf: backupURL, encoding: .utf8) else { return false }
        let result = protectedContents(current: current, backup: backup)
        guard result.restored else { return false }
        try? result.contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return true
    }

    static var defaultBackupURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-voice-guidance.backup.md")
    }
}
