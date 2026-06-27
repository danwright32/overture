import Testing
import Foundation
@testable import Overture

// #250: read/save backing for the in-app voice-guidance editor. The guidance file lives in
// Application Support where Dan can't easily find it; this lets the app open it, show a sensible
// starter when it doesn't exist yet (so he can seed his notes before any Prep run), and save edits.

@Suite("Voice guidance store (#250)")
struct VoiceGuidanceStoreTests {
    @Test func loadReturnsAStarterTemplateWhenTheFileIsMissing() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).md")
        let text = VoiceGuidanceStore.load(from: url)
        // The starter has both sections so Dan edits the right structure from the first run.
        #expect(text.contains("## Dan's notes"))
        #expect(text.contains("## Observed tendencies"))
    }

    @Test func loadReturnsTheFileContentsWhenPresent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vg-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = "## Dan's notes (authoritative — never auto-edited)\n\nLead with the venue.\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        #expect(VoiceGuidanceStore.load(from: url) == body)
    }

    @Test func saveWritesTheFileCreatingTheDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vg-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("overture-voice-guidance.md")
        defer { try? FileManager.default.removeItem(at: dir) }

        let edited = "## Dan's notes (authoritative — never auto-edited)\n\nKeep it level.\n"
        #expect(VoiceGuidanceStore.save(edited, to: url) == true)
        #expect(VoiceGuidanceStore.load(from: url) == edited)   // round-trips
    }
}
