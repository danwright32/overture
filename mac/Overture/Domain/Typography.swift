import Foundation

// Brand voice forbids typographic dashes in user-facing copy (#343): no em dash as a connector or
// parenthetical break, and no en dash. Hyphens inside a word ("self-produced") are fine. This is the
// single definition reused by DraftCheck (runtime check on generated email bodies) and the build-time
// guard test that scans the app's own static UI strings, so the two never drift.
enum Typography {
    static let emDash: Character = "\u{2014}"   // —
    static let enDash: Character = "\u{2013}"   // –
    static let forbiddenDashes: [Character] = [emDash, enDash]

    static func containsForbiddenDash(_ text: String) -> Bool {
        text.contains { forbiddenDashes.contains($0) }
    }
}
