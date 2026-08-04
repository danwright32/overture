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

    // #2087, from #2086: a signature that is intact and perfectly sendable, and still defective for part
    // of its audience. Dan's carried three wrapper divs styled `border:1px solid #fff`. On the white
    // background Gmail authors signatures for, and on the white card the draft preview renders (#1203),
    // a white border is invisible; to every recipient reading in a dark-mode mail client it is a hard
    // white outline box around the whole signature. It went out on real pitches for about two weeks and
    // nothing in the product could show it, because the only surface that renders the signature renders
    // it on the one background that hides it.
    //
    // Deliberately a WARNING and not a refusal, unlike corruptionReason above. The signature sends fine
    // and every light-mode reader sees what Dan intended, so taking it off the wire would make the
    // product worse for the whole audience to spare part of it a border (L54).
    //
    // Returns a developer/diagnostic reason, not the app's own voice; the sentence Dan reads is
    // GmailCopy's.
    static func darkBackgroundReason(_ html: String) -> String? {
        for value in borderValues(in: html) {
            guard drawsAVisibleLine(value), let colour = nearWhiteColour(in: value) else { continue }
            // copy-inventory:ignore-start  developer diagnostic reason (log/badge detail), not the app's own voice (#915)
            return "draws a near-white border (\(colour)), invisible on white and an outline box on a dark background"
            // copy-inventory:ignore-end
        }
        return nil
    }

    // The value of every `border` / `border-top` / `border-right` / `border-bottom` / `border-left`
    // declaration. Anchored on the colon, so `border-radius`, `border-collapse` and `border-spacing`
    // cannot match, and so the HTML attribute spelling (`border="0"`, which the real signature carries
    // three times on its social icons) cannot either.
    private static let borderDeclaration = try! NSRegularExpression(
        pattern: #"border(?:-(?:top|right|bottom|left))?\s*:\s*([^;"']+)"#, options: [.caseInsensitive])

    private static func borderValues(in html: String) -> [String] {
        let range = NSRange(html.startIndex..., in: html)
        return borderDeclaration.matches(in: html, range: range).compactMap { match in
            Range(match.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    // Line styles that actually paint something. `none` and `hidden` are absent from this list on
    // purpose, and so is a declaration carrying no style at all: `border:0px` in the real signature
    // paints nothing, and treating it as a border would flag every clean signature Dan will ever have.
    private static let paintingStyles = ["solid", "double", "dashed", "dotted", "groove", "ridge",
                                         "inset", "outset"]

    private static func drawsAVisibleLine(_ value: String) -> Bool {
        let lower = value.lowercased()
        guard paintingStyles.contains(where: { lower.contains($0) }) else { return false }
        // An explicit zero width paints nothing whatever the style says. No width at all is the CSS
        // default (`medium`), which does paint, so the absence of a number is not the absence of a line.
        return !zeroWidth(lower)
    }

    private static let lengthToken = try! NSRegularExpression(
        pattern: #"(?<![\w.])(\d*\.?\d+)\s*(px|pt|em|rem|ex|ch|vh|vw|cm|mm|in|pc|%)?(?![\w(])"#)

    private static func zeroWidth(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        for match in lengthToken.matches(in: value, range: range) {
            guard let r = Range(match.range(at: 1), in: value), let n = Double(value[r]) else { continue }
            if n == 0 { return true }
        }
        return false
    }

    // Near-white means near-white ENOUGH TO HIDE on a white background, which is the whole mechanism:
    // a border nobody can see where it is authored and reviewed, and everybody can see where it is read.
    // 245 of 255 on every channel is that threshold; a colour any darker shows up in the preview too,
    // and a border someone can see is a border someone chose.
    private static let nearWhiteFloor = 245.0

    private static let rgbFunction = try! NSRegularExpression(
        pattern: #"rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)"#,
        options: [.caseInsensitive])
    private static let hexColour = try! NSRegularExpression(
        pattern: #"#([0-9a-f]{3}|[0-9a-f]{6})\b"#, options: [.caseInsensitive])

    private static func nearWhiteColour(in value: String) -> String? {
        let range = NSRange(value.startIndex..., in: value)

        if let m = rgbFunction.firstMatch(in: value, range: range) {
            let channels = (1...3).compactMap { i -> Double? in
                Range(m.range(at: i), in: value).flatMap { Double(value[$0]) }
            }
            // A fully transparent border paints nothing, so it is not this defect.
            let alpha = Range(m.range(at: 4), in: value).flatMap { Double(value[$0]) } ?? 1
            if channels.count == 3, alpha > 0.05, channels.allSatisfy({ $0 >= nearWhiteFloor }),
               let text = Range(m.range, in: value).map({ String(value[$0]) }) {
                return text
            }
        }

        if let m = hexColour.firstMatch(in: value, range: range),
           let r = Range(m.range(at: 1), in: value) {
            let digits = String(value[r])
            let expanded = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : digits
            let channels = stride(from: 0, to: 6, by: 2).compactMap { i -> Double? in
                let start = expanded.index(expanded.startIndex, offsetBy: i)
                let end = expanded.index(start, offsetBy: 2)
                return UInt8(expanded[start..<end], radix: 16).map(Double.init)
            }
            if channels.count == 3, channels.allSatisfy({ $0 >= nearWhiteFloor }) { return "#\(digits)" }
        }

        // CSS keywords Gmail emits for the same colour.
        let lower = value.lowercased()
        for keyword in ["white", "snow", "ivory", "floralwhite", "ghostwhite"] where
            lower.range(of: #"\b\#(keyword)\b"#, options: .regularExpression) != nil {
            return keyword
        }
        return nil
    }
}
