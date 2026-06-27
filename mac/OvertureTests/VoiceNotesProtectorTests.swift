import Testing
import Foundation
@testable import Overture

// #251: protect Dan's hand-written notes in overture-voice-guidance.md. The "## Dan's notes" section
// is authoritative and the #242 workflow is told never to touch it, but that is only an instruction.
// This makes the app the safety net: it backs the file up before a Prep run and, after the run,
// restores the notes section from the backup if the run altered or dropped it — while keeping the
// freshly regenerated auto section. So a misbehaving run can never silently wipe Dan's notes.

@Suite("Voice notes protector (#251)")
struct VoiceNotesProtectorTests {
    private let withNotes = """
    ## Dan's notes (authoritative — never auto-edited)

    Lead with the venue. Keep it level.

    ## Observed tendencies (auto-generated; regenerated each run)

    - Dan cuts the second opener sentence.
    """

    @Test func notesSectionExtractsOnlyTheDansNotesBlock() {
        let notes = VoiceNotesProtector.notesSection(of: withNotes)
        #expect(notes.contains("## Dan's notes (authoritative — never auto-edited)"))
        #expect(notes.contains("Lead with the venue. Keep it level."))
        #expect(!notes.contains("Observed tendencies"))            // auto section excluded
        #expect(!notes.contains("Dan cuts the second opener"))
    }

    @Test func unchangedNotesAreLeftAlone() {
        let result = VoiceNotesProtector.protectedContents(current: withNotes, backup: withNotes)
        #expect(result.restored == false)
        #expect(result.contents == withNotes)
    }

    @Test func wipedNotesAreRestoredAndTheFreshAutoSectionIsKept() {
        // The run dropped Dan's notes but regenerated the auto section.
        let afterRun = """
        ## Observed tendencies (auto-generated; regenerated each run)

        - New tendency learned this run.
        """
        let result = VoiceNotesProtector.protectedContents(current: afterRun, backup: withNotes)
        #expect(result.restored == true)
        #expect(result.contents.contains("Lead with the venue. Keep it level."))   // notes back
        #expect(result.contents.contains("- New tendency learned this run."))       // fresh auto kept
    }

    @Test func tamperedNotesAreRestoredFromBackup() {
        let tampered = withNotes.replacingOccurrences(of: "Lead with the venue. Keep it level.",
                                                      with: "Some text the run wrongly wrote here.")
        let result = VoiceNotesProtector.protectedContents(current: tampered, backup: withNotes)
        #expect(result.restored == true)
        #expect(result.contents.contains("Lead with the venue. Keep it level."))
        #expect(!result.contents.contains("Some text the run wrongly wrote here."))
        #expect(result.contents.contains("- Dan cuts the second opener sentence."))  // auto preserved
    }

    @Test func noBackupNotesMeansNoRestore() {
        let backupWithoutNotes = """
        ## Observed tendencies (auto-generated; regenerated each run)

        - Only auto here.
        """
        let result = VoiceNotesProtector.protectedContents(current: withNotes, backup: backupWithoutNotes)
        #expect(result.restored == false)
        #expect(result.contents == withNotes)
    }

    @Test func backupCopiesAnExistingFileAndRestoreReinstatesNotes() throws {
        let dir = FileManager.default.temporaryDirectory
        let fileURL = dir.appendingPathComponent("vg-\(UUID().uuidString).md")
        let backupURL = dir.appendingPathComponent("vg-\(UUID().uuidString).backup.md")
        defer { [fileURL, backupURL].forEach { try? FileManager.default.removeItem(at: $0) } }

        try withNotes.write(to: fileURL, atomically: true, encoding: .utf8)
        VoiceNotesProtector.backup(fileURL: fileURL, backupURL: backupURL)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        // The run rewrites the file and drops Dan's notes.
        try "## Observed tendencies (auto-generated; regenerated each run)\n\n- fresh\n"
            .write(to: fileURL, atomically: true, encoding: .utf8)

        #expect(VoiceNotesProtector.restoreIfNeeded(fileURL: fileURL, backupURL: backupURL) == true)
        let after = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(after.contains("Lead with the venue. Keep it level."))
        #expect(after.contains("- fresh"))
    }

    @Test func restoreIsANoOpWhenNothingChanged() throws {
        let dir = FileManager.default.temporaryDirectory
        let fileURL = dir.appendingPathComponent("vg-\(UUID().uuidString).md")
        let backupURL = dir.appendingPathComponent("vg-\(UUID().uuidString).backup.md")
        defer { [fileURL, backupURL].forEach { try? FileManager.default.removeItem(at: $0) } }

        try withNotes.write(to: fileURL, atomically: true, encoding: .utf8)
        VoiceNotesProtector.backup(fileURL: fileURL, backupURL: backupURL)
        #expect(VoiceNotesProtector.restoreIfNeeded(fileURL: fileURL, backupURL: backupURL) == false)
    }

    @Test func restoreIsANoOpWhenNoBackupExists() {
        let dir = FileManager.default.temporaryDirectory
        let fileURL = dir.appendingPathComponent("vg-\(UUID().uuidString).md")
        let backupURL = dir.appendingPathComponent("nope-\(UUID().uuidString).backup.md")
        #expect(VoiceNotesProtector.restoreIfNeeded(fileURL: fileURL, backupURL: backupURL) == false)
    }
}
