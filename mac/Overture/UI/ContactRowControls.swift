import SwiftUI

// The draft-review contact row's chrome rules, pulled OUT of the view body so they are testable and
// can't quietly drift back (a repo lesson: a rule computed inside a SwiftUI view is invisible to the
// suite). Two issues live here:
//   #1137 - a still-pending contact's leading glyph IS its remove control (the X sits where the person
//           icon used to be); a sent contact keeps a plain, non-interactive person icon.
//   #1139 - the two replied-row controls (record an OUTCOME vs note the in-flight CONVERSATION STATE)
//           set genuinely different things and must never read as the same dropdown, so their
//           distinction (a deliberate icon and a deliberate, distinct accent) is defined here once.
enum ContactRowControls {
    // #1137
    static func leadingIsRemove(sendState: SendState) -> Bool { sendState == .pending }
    static func leadingIcon(sendState: SendState) -> String {
        leadingIsRemove(sendState: sendState) ? "xmark.circle" : "person.crop.circle"
    }

    // #1139: a semantic accent, so the two controls read as a deliberate SYSTEM (forest = a committed
    // outcome, gold = an in-flight/warm conversation), matching Overture's colour language elsewhere,
    // rather than one control being branded and the other left on the system default by accident.
    enum Accent: Equatable {
        case outcome
        case conversationState
        var color: Color {
            switch self {
            case .outcome: return OVColor.forest
            case .conversationState: return OVColor.gold
            }
        }
    }

    // #1139
    enum Kind: Equatable {
        case outcome            // the "Mark…" menu: a terminal commercial outcome for this contact
        case conversationState  // the "Set a state" menu: where the in-flight conversation stands

        var icon: String {
            switch self {
            case .outcome: return "flag.checkered"
            case .conversationState: return "bubble.left.and.bubble.right"
            }
        }
        var accent: Accent {
            switch self {
            case .outcome: return .outcome
            case .conversationState: return .conversationState
            }
        }
    }
}
