import Foundation

// #4170: what Overture says when Dan pitches somebody ELSE on a show he has already sent.
//
// Its own enum beside the other card vocabularies rather than literals in the view, so every sentence
// is in the copy inventory and can be read cold, and so the menu item and the panel that opens from it
// cannot drift into describing different acts.
enum RePitchCopy {
    // The menu item, under the separator in "Close this out" beside the reply link, because it is not an
    // ending: everything above it closes the pitch and this one keeps it alive with somebody new. Named
    // for what it does rather than for the field it opens (Dan's call on the control's home, 2026-09-23).
    static let menuLabel = "Pitch someone else"

    // The panel's own title, which IS the menu item's words rather than a second copy of them: the thing
    // he pressed and the thing that opened must say the same act, and two constants holding one sentence
    // is how they stop (L118).
    static var panelTitle: String { menuLabel }

    // What the panel is FOR, in one line: the case it was built from, without naming a company or a
    // person, because it appears on every sent show and most of them have no autoresponse behind them.
    //
    // It names PREP as what writes the draft, rather than saying Overture writes one, because nothing is
    // written when this panel closes: the show joins the prep queue and the next run drafts it. The first
    // wording claimed the draft into existence and would have had him waiting for a card that no run had
    // been asked for (L12).
    static let panelHelp = "Add a contact on a show you have already pitched. The next Prep run writes them a fresh first-contact draft, and the original conversation carries on untouched."

    static let addAction = "Add and draft"

    // The acknowledgement, which says the TWO things that happened rather than only the visible one: a
    // contact was added, and the show is now queued for a draft it does not have yet. Saying only the
    // first would leave him waiting for a send that nothing has written (L12).
    static func queued(name: String?, route: String?, org: String) -> String {
        let who = [name, route].compactMap { $0 }.first { !$0.isEmpty } ?? "that contact"
        return "\(who) added to \(org). Run Prep to write their draft."
    }
}
