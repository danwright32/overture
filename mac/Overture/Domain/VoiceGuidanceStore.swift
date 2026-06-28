import Foundation

// Read/save backing for the in-app voice-guidance editor (#250 / #119). The guidance file lives in
// Application Support; this lets the app open it, show a sensible starter when it doesn't exist yet
// (so Dan can seed his notes before any Prep run), and save his edits. Same file the loop reads and
// the #251 protector guards.

enum VoiceGuidanceStore {
    // Shown when no guidance file exists yet: the two-section skeleton the runbook expects, so Dan
    // edits the right structure from the start. His section is authoritative; the auto section fills
    // in after the loop has edits to learn from.
    static let starterTemplate = """
    ## Dan's notes (authoritative, never auto-edited)

    Write any voice guidance you want every draft to follow. This section is yours; Prep runs never change it.

    ## Observed tendencies (auto-generated; regenerated each run)

    _Nothing learned yet. This fills in after you've edited and sent some drafts._
    """

    static func load(from url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? starterTemplate
    }

    @discardableResult
    static func save(_ contents: String, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    static var defaultURL: URL { VoiceGuidanceGuard.defaultURL }
}
