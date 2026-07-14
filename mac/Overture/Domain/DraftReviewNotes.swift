import Foundation

// #885: the sentences on the draft review screen, out of the view body.
//
// This is the screen with the most at stake: the last thing between a draft and a stranger's inbox. It
// tells Dan a draft WON'T send, that a contact is HELD BACK from sending, and that a send went out
// DESPITE a warning he confirmed. Each of those is a claim about what the app is doing, and each was a
// string assembled inside a SwiftUI body, where no test could read it.
//
// Pure functions, never a computation inside the body: a rule computed in a view is a rule no test can
// reach, and two of those have already drifted here under a green suite (#863, #876).
enum DraftReviewNotes {

    // #789's deliberate audit trail. An overridden warning TONES DOWN rather than disappearing, so there
    // is still a visible record that the send happened despite it. A sentence that vanished on override
    // would erase precisely the thing worth keeping.
    static func salutation(needsReview: Bool, overridden: Bool) -> String? {
        guard needsReview else { return nil }
        guard !overridden else { return "Sending despite the greeting warning you confirmed." }
        return "This old draft may still have a name in the greeting Overture couldn't safely remove; "
            + "edit it before sending."
    }

    // The same shape for the draft lint (#789). Blocked names what is holding it; overridden leaves the
    // trail; a clean draft says nothing, because a note that fires on every draft is a note Dan skims.
    static func lint(blocked: Bool, blockers: [DraftIssue]) -> String? {
        if blocked { return DraftCheck.blockMessage(blockers: blockers) }
        guard !blockers.isEmpty else { return nil }
        return "Sending despite the draft warning you confirmed."
    }

    // #792: "Sent" was once the whole story, and a contact held back by a review guard is not sendable,
    // so a show read as fully done while a real person never received anything. This count is what says
    // otherwise, and a count is a promise about rows (#863).
    static func heldContacts(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? "contact" : "contacts") held for a check"
    }

    // The three contact warnings. Each names WHY the contact is suspect and then states the
    // CONSEQUENCE, which is the load-bearing half: this person will not be emailed until Dan says so.
    static func venueSuspect(name: String) -> String {
        "\(name) may be the venue itself, not the act; blocked from sending."
    }

    static func pressSuspect(name: String) -> String {
        "\(name) may be a press/media contact, not the act; blocked from sending."
    }

    static func duplicateSuspect(name: String) -> String {
        "\(name) may already be pitched for a nearby show; blocked from sending."
    }
}
