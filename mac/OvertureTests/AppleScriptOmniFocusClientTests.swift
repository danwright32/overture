import Testing
import Foundation

// #653: the pure parsing half of the AppleScript client (decoding the raw field/record-separated
// string the script emits into ExistingTask values) is unit-testable without any AppleScript or live
// OmniFocus dependency, unlike the actual `run()` I/O. Covers the new 3-paragraph format and the
// one-time transition handling for a legacy (pre-#653) 2-paragraph note.
@Suite("AppleScript OmniFocus client parsing")
struct AppleScriptOmniFocusClientTests {
    private let notePrefix = OmniFocusSync.notePrefix
    private let contactPrefix = OmniFocusSync.contactNotePrefix
    private let duePrefix = OmniFocusSync.dueNotePrefix
    private let fieldSep = "|||"
    private let recordSep = "@@@"

    private func parse(_ raw: String) -> [OmniFocusSync.ExistingTask] {
        AppleScriptOmniFocusClient.parseExistingTasks(raw, notePrefix: notePrefix, contactPrefix: contactPrefix,
                                                      duePrefix: duePrefix, fieldSep: fieldSep, recordSep: recordSep)
    }

    @Test func parsesANewFormatRecordWithItsRecipientAndDueDay() {
        let raw = "\(notePrefix)aurora-strings\(fieldSep)\(contactPrefix)jane@x.com\(fieldSep)\(duePrefix)2026-07-15\(recordSep)"
        let tasks = parse(raw)
        #expect(tasks.count == 1)
        #expect(tasks.first?.naturalKey == "aurora-strings")
        #expect(tasks.first?.recipientId == "jane@x.com")
    }

    // #653's one-time transition: a task written before this shipped has only 2 paragraphs (no
    // contact line). It must still parse -- tagged with legacyRecipientId, which OmniFocusSync.
    // reconcile can never match against a real desired task, so it's always cleaned up as stale.
    @Test func parsesALegacyTwoParagraphRecordAsTheLegacySentinel() {
        let raw = "\(notePrefix)old-show\(fieldSep)\(AppleScriptOmniFocusClient.legacyRecipientId)\(fieldSep)\(duePrefix)2026-07-15\(recordSep)"
        let tasks = parse(raw)
        #expect(tasks.count == 1)
        #expect(tasks.first?.naturalKey == "old-show")
        #expect(tasks.first?.recipientId == AppleScriptOmniFocusClient.legacyRecipientId)
    }

    @Test func parsesMultipleRecordsSeparately() {
        let raw = "\(notePrefix)a\(fieldSep)\(contactPrefix)x@e.com\(fieldSep)\(duePrefix)2026-07-15\(recordSep)"
            + "\(notePrefix)a\(fieldSep)\(contactPrefix)y@e.com\(fieldSep)\(duePrefix)2026-07-16\(recordSep)"
        let tasks = parse(raw)
        #expect(tasks.count == 2)
        #expect(Set(tasks.map(\.recipientId)) == ["x@e.com", "y@e.com"])
    }

    @Test func skipsARecordWithNoRecognizableContactField() {
        // Neither the legacy sentinel nor a real "Overture contact: " line: unrecognized shape,
        // skip rather than guess.
        let raw = "\(notePrefix)a\(fieldSep)garbage\(fieldSep)\(duePrefix)2026-07-15\(recordSep)"
        #expect(parse(raw).isEmpty)
    }

    @Test func skipsAMalformedRecordMissingAField() {
        let raw = "\(notePrefix)a\(fieldSep)\(contactPrefix)x@e.com\(recordSep)"   // only 2 fields, no due line
        #expect(parse(raw).isEmpty)
    }

    @Test func skipsEmptyInput() {
        #expect(parse("").isEmpty)
    }
}
