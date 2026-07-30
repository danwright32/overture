import Foundation

// #1824: what the Prep run understood the show to BE, and the honest reason when it could not tell.
//
// The run is handed the readable text of the show's own listing page (`PrepQueueItem.showListing`, rendered
// by the app because the detached run's tools cannot render a JavaScript-drawn page). This is what it says
// back. Two purposes, and both matter: the instruction leaves a CHECKABLE TRACE rather than living only in
// the prompt (L27, a rule with no deterministic record of having been followed is a hope), and Dan can see
// on the card whether the draft beside it was grounded in anything at all.
//
// Why an absence has its own vocabulary rather than just being a missing summary: "there was no listing
// page", "we could not read the page" and "the page publishes no description of this show" are three
// different facts, and only the last one is a statement about the show. Collapsed into one, the app would
// be claiming more than it measured (L11), which is the same defect this whole issue is about.
enum ShowSummaryAbsence: String, Equatable, Sendable, CaseIterable {
    // The item carried no `showListing` at all: the prospect has no listing URL, so there was never a page.
    case noListingPage = "no_listing_page"
    // The app rendered the page and could not read it (it did not load, or nothing came back). Says nothing
    // about the show, only about our reach.
    case pageUnreadable = "page_unreadable"
    // The page WAS read and does not describe this show. Includes the common case where the listing URL
    // points at a season calendar or an index rather than this one show's own page.
    case noDescriptionPublished = "no_description_published"
}

enum ShowSummaryCopy {
    // What the card shows, or nil for nothing to say.
    //
    // A real summary always wins over a reason: it is the line that carries information, and the two side
    // by side would contradict each other. An empty or whitespace-only summary is not a summary, which
    // matters because a run emitting `""` would otherwise blank the line AND suppress the honest reason.
    static func line(summary: String?, absence: ShowSummaryAbsence?) -> String? {
        let trimmed = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return absenceLine(absence)
    }

    // nil for nil, deliberately. Every draft written before this feature existed carries no reason, and a
    // line on all of them would be noise asserting something nobody measured.
    static func absenceLine(_ absence: ShowSummaryAbsence?) -> String? {
        switch absence {
        case .noListingPage: return "No listing page for this show"
        case .pageUnreadable: return "Its listing page couldn't be read"
        case .noDescriptionPublished: return "Its listing publishes no description"
        case nil: return nil
        }
    }
}
