import Foundation

// #2308: what the Sources sheet's Done button must refuse to throw away.
//
// Done carries `.keyboardShortcut(.defaultAction)`, so it is what Return presses ANYWHERE in the sheet
// that does not handle Return itself. The sheet holds four places to type: three inline editors (a
// room's place, a venue's location, a venue's name) and the add-a-source form. Each inline editor
// handles its own Return, so the loss only happened when focus was somewhere else, which is exactly the
// case a person cannot predict by looking at the screen: the sheet took the keypress as "I'm finished"
// and discarded a part-typed edit with no warning and no undo (L9, and Dan's standing rule against
// silently discarding in-progress input).
//
// The rule lives here rather than in the view for the usual reason (#863): a rule stated in a SwiftUI
// body is a rule no test can reach, and this one decides whether typed work survives a keypress.
enum SourcesSheetClose {

    // What is unfinished, in the order Done reports it. Order matters only when two are open at once,
    // which the sheet allows: the inline editors come first because they hold a draft of an EXISTING
    // row's field, so abandoning one silently changes nothing visible, while the add form at least
    // stays on screen with its text in it.
    enum Unsaved: Equatable, Sendable {
        case roomPlace
        case venueLocation
        case venueName
        case newSource
    }

    // Nil means Done may close the sheet, which is the normal case: nothing typed, nothing to lose.
    //
    // `newSourceTyped` is deliberately about the TEXT, not about the form being open. An add form Dan
    // opened and left empty has nothing in it to protect, and refusing to close over one would be a
    // guard that only ever gets in the way (the #928 shape, where the Days off sheet asks only when the
    // form was actually edited).
    static func unsaved(roomPlaceOpen: Bool, venueLocationOpen: Bool, venueNameOpen: Bool,
                        newSourceTyped: Bool) -> Unsaved? {
        if roomPlaceOpen { return .roomPlace }
        if venueLocationOpen { return .venueLocation }
        if venueNameOpen { return .venueName }
        if newSourceTyped { return .newSource }
        return nil
    }

    // Each names the thing that is unfinished and the two ways out of it, because every one of these
    // editors carries its own Save and Cancel: a refusal that did not say where to go would leave Dan
    // pressing Done again.
    static func message(for unsaved: Unsaved) -> String {
        switch unsaved {
        case .roomPlace: return "Save or cancel the room you're placing first."
        case .venueLocation: return "Save or cancel the location you're editing first."
        case .venueName: return "Save or cancel the venue name you're editing first."
        case .newSource: return "Watch the source you've typed, or clear it, before closing."
        }
    }
}
