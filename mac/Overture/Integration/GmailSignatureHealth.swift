import Foundation

// #1253: an obviously-corrupt Gmail signature must never be silently cached or attached to a real pitch
// ("fail loud, not silent"). On 2026-07-20 the cache held a stale signature carrying literal `\240` octal
// escapes (broken non-breaking spaces) that Gmail's sendAs returned; it would have shipped on every send,
// and only #1203's draft preview surfaced it by luck when Dan happened to look.
//
// This is the deterministic detector: valid signature HTML uses a real non-breaking space or `&nbsp;`,
// never a literal backslash-octal text run. Host resolution (a dead <img> host, the other symptom that
// day) is deliberately NOT checked here: it needs a network round trip that would make the pure store and
// read paths flaky, and the octal-escape tell alone catches the corruption that actually shipped.
enum GmailSignatureHealth {
    // A literal C-style octal byte escape: a backslash followed by three octal digits (e.g. \240 = a
    // non-breaking space). The leading digit is capped at 0-3 so the value stays a real byte (\000-\377).
    private static let literalOctalEscape = try! NSRegularExpression(pattern: #"\\[0-3][0-7][0-7]"#)

    // A human-readable reason the signature looks corrupt, or nil when it looks fine. The reason is a
    // developer/diagnostic string, not the app's own voice.
    static func corruptionReason(_ html: String) -> String? {
        let range = NSRange(html.startIndex..., in: html)
        if literalOctalEscape.firstMatch(in: html, range: range) != nil {
            // copy-inventory:ignore-start  developer diagnostic reason (log/badge detail), not the app's own voice (#915)
            return "contains a literal octal escape run (a broken non-breaking space), a corrupted-signature tell"
            // copy-inventory:ignore-end
        }
        return nil
    }
}
