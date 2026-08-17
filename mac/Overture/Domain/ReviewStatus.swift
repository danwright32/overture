import Foundation

// Where a prospect sits in Dan's review. The scout writes everything as `.new`;
// Dan moves it to `.queued` (keep), the Prep run fills a contact + draft and marks
// it `.drafted` (ready to review), Dan `.approved` it to send, the send advances it to
// `.contacted` (the pitch went out, #200), or `.dismissed` a no-go.
// Stored on the model as a raw string so SwiftData keeps it simple.
enum ReviewStatus: String, CaseIterable, Sendable {
    case new
    case queued
    case drafted
    case approved
    case contacted
    case dismissed
}

// How a contact was found, weakest-to-strongest mirrored by its confidence.
enum ContactMethod: String, CaseIterable, Sendable {
    case namedDecisionMaker = "named_decision_maker"
    case genericInbox = "generic_inbox"
    case formOrDM = "form_or_dm"
}

enum ContactConfidence: String, CaseIterable, Sendable {
    case high, medium, low

    // #885: the pip's wording, which was a switch inside DraftReviewView's body.
    var label: String {
        switch self {
        case .high: return "high confidence"
        case .medium: return "medium confidence"
        case .low: return "low confidence"
        }
    }
}

// What ultimately happened after Dan reached out. Defaults to `.noResponse` (like
// Dan's booking sheet) so the majority need no touch. `.replied` can be set
// automatically from Gmail reply detection; `.booked` from Downbeat (the canonical
// booking record). The two lost cases are Dan's call: `.lostSoft` (the door is open
// for the future) and `.lostHard` (not interested), which carry through to the
// prior-relationship ranking. Only meaningful once a prospect was sent; feeds the
// fit-score feedback loop (#4).
enum Outcome: String, CaseIterable, Sendable {
    case noResponse = "no_response"
    case replied
    case booked
    case lostSoft = "lost_soft"
    case lostHard = "lost_hard"

    var label: String {
        switch self {
        case .noResponse: return "No response"
        case .replied: return "Replied"
        case .booked: return "Booked"
        case .lostSoft: return "Lost (keep in mind)"
        case .lostHard: return "Lost (not interested)"
        }
    }

    // Legacy booking rows recorded a single ambiguous "passed"; treat those as the soft
    // lost case (the door stays open) so old data keeps a sensible meaning.
    static func fromStored(_ raw: String) -> Outcome {
        if let o = Outcome(rawValue: raw) { return o }
        if raw == "passed" { return .lostSoft }
        return .noResponse
    }
}

// Where an outcome came from, so an automatic signal (Gmail/Downbeat) never
// overwrites a decision Dan made by hand.
enum OutcomeSource: String, CaseIterable, Sendable {
    case auto      // gmail reply / downbeat booking
    case manual    // Dan marked it
}

// The reasons Dan can give when dismissing, mirroring the engine's dismiss_reason set.
// #864: `wentBy` is the one Overture writes for itself, and the only one that is not a decision at all:
// the show's last night passed while it sat untriaged. It is a fact about the calendar, so it must never
// read as a judgement Dan made (it gets its own Archive bucket, and teaches LocalHistory nothing).
enum DismissReason: String, CaseIterable, Sendable {
    case dateConflict = "date_conflict"
    // #940: 'Day doesn't work' (day_doesnt_work) was folded into 'Date conflict' (they behaved
    // identically). DismissReasonMigration rewrites any prospect still carrying the old raw value.
    case notInterested = "not_interested"
    case dontWantToShoot = "dont_want_to_shoot"   // #351: personal taste, distinct from "Not a fit"
    case alreadyBooked = "already_booked"
    case duplicate
    // #1128: a show Dan WOULD want but found out about too late to pitch. Distinct from `dateConflict`
    // (he is free, there just wasn't time) and from `notInterested`/`dontWantToShoot` (he does want it).
    // A missed opportunity, never a bad-fit signal, so it must never be folded into `notInterested`.
    case tooSoon = "too_soon"
    // #1821: Dan reaches out about one show a night, occasionally two, so on a busy night the other good
    // shows are cut because he ran out of nights, not because anything was wrong with them. Every other
    // reason says something untrue about that: `dateConflict` claims the night did not work when he spent
    // it, `alreadyBooked` claims a paid booking held it, and the three judgement reasons blame the show.
    //
    // It is NOT a variation on `dateConflict` and must never be folded into it. Kept apart, Dan can
    // eventually ask how many strong shows he drops purely for want of a night rather than on fit (#16);
    // folded, that question can never be asked afterwards, because the difference was never written down.
    case pitchingOtherShows = "pitching_other_shows"
    case wentBy = "went_by"
    // #1238: Dan blocked the town this show is in ("Never show me shows in <town>"). Like `wentBy`, this
    // is Overture's OWN automatic cut, never a choice in the menu, and it must never teach LocalHistory a
    // thing about the org, since Overture watches out-of-town orgs for their occasional NYC dates (#970).
    case tooFar = "too_far"

    // #2394: the words come from `ShowOutcome`, the one vocabulary, rather than being restated here.
    // Restating them is the duplicate-copy trap from the worse direction (#843): not the same thing said
    // twice, but the same thing said DIFFERENTLY, which reads as two different reasons. It also lands the
    // rename this phase exists for, since "Already booked" meant Dan was busy and read as the client
    // having hired him: this reason now says "I had paid work" everywhere it appears.
    var label: String { asShowOutcome.label }

    // #2685: `DismissReason.danCanChoose` is GONE. It was the menu every dismiss control read from until
    // #2395 put those menus over `ShowOutcome` directly, and it then sat here with no caller at all while
    // reading like the live rule to whoever found it first (L29).
    //
    // What replaced it, so nobody has to go looking: `ShowOutcome.menu(wasPitched:)` is the one place the
    // choice of menu is made, and `ShowOutcome.danCanChoose` is the pair of halves it draws from.
    // `InquiryEnding.danCanChoose` is the inquiry's own narrower list. Neither is this one.
}
