import Foundation

// #2086: which background the draft preview renders the outgoing email on.
//
// The preview existed on ONE background, true white, chosen in #1203 because that is what a Gmail
// signature is authored for. That choice was right and it also made the preview structurally unable to
// show a whole class of defect: styling that is invisible on the background it was authored on and
// glaring on the other. Dan's signature carried three white borders, so it previewed clean on white and
// shipped a hard white outline box to every dark-mode recipient for about two weeks, and no test could
// have caught it because nothing was wrong with what was sent, only with what could be seen (L69).
//
// Two backgrounds, one of which is always a click away, is the fix for the class rather than for the
// instance: it covers the next defect of this shape too, including the ones no detector anticipates.
enum PreviewBackground: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark

    var id: String { rawValue }

    // The label on the preview's own switch.
    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    // The card's surface colour. Light is true white on purpose (#1203): a signature's own divider rules
    // are authored `#fff` to vanish on a white email body, so an off-white card wrongly reveals them as
    // grey lines and the preview would report a defect that no recipient has. Dark is Gmail's own
    // dark-mode message surface, since a Gmail signature read in Gmail's dark mode is the case this
    // stands in for.
    var surfaceCSS: String {
        switch self {
        case .light: return "#ffffff"
        case .dark: return "#202124"
        }
    }

    // The card's default text colour, for the parts of the message that do not set their own. The
    // signature's own inline colours are deliberately left alone on both backgrounds: overriding them
    // would be the preview showing something the recipient will not get.
    var inkCSS: String {
        switch self {
        case .light: return "#111111"
        case .dark: return "#e8eaed"
        }
    }

    // The card's frame. On white it is a faint dark hairline; on dark a faint light one. Neither is
    // near-white enough to be mistaken, by eye, for the signature's own white border: that border is the
    // thing this view exists to reveal, so the card must not draw one just like it around itself.
    var frameCSS: String {
        switch self {
        case .light: return "1px solid rgba(0,0,0,0.12)"
        case .dark: return "1px solid rgba(255,255,255,0.18)"
        }
    }

    // Which background the preview opens on. Light by default, because that is what the signature is
    // authored for and what most readers see. When the #2087 detector has ALREADY judged the signature
    // wrong on dark, it opens on dark instead: at the one moment there is something to look at, the
    // evidence belongs in front of Dan rather than behind a control he has to think to press (L49).
    static func opening(for signatureHTML: String?) -> PreviewBackground {
        guard let signatureHTML, GmailSignatureHealth.darkBackgroundReason(signatureHTML) != nil else {
            return .light
        }
        return .dark
    }
}
