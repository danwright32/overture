import Foundation

// #2575: the two rules the editable send sheet turns on, out of the view so a test can reach them at all
// (#863: logic inside a SwiftUI body is logic nothing can exercise).
//
// Dan, at the closing-note send sheet on 2026-08-13: "I have no way to edit closing notes." Follow-ups
// and the post-event closing note were the only two outbound paths with no text box: both are composed
// end to end by Overture and were drawn as read-only text, so he read a message he could not change and
// then either sent it as written or cancelled. His rule from #2010 is "whatever is in the text box that I
// see is what's sent", and here there was no box.
enum SendConfirmEditing {

    // An emptied box is not a message. The send refuses it too (the same predicate, at the other end), so
    // this is what keeps the button from offering an act the send would decline, rather than the only
    // thing standing between an empty email and Dan's name on it (L109: the gate and the reason it shows
    // come from one place).
    static func bodyIsSendable(_ body: String) -> Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // The contact picker (#2017) and the editor are mutually exclusive BY CONSTRUCTION, not by the two
    // never happening to be set together. Ticking a different contact rebuilds the confirmation, and the
    // rebuilt body would silently replace whatever Dan had typed (L5). The two paths that edit send to one
    // contact and offer no choice, so nothing is lost by making it impossible.
    static func offersChoice(hasRebuild: Bool, candidates: Int, isEditable: Bool) -> Bool {
        hasRebuild && candidates > 1 && !isEditable
    }
}
