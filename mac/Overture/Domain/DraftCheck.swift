import Foundation

// A deterministic self-check over a drafted email (#11): the same brand-voice and stance
// rules the drafter runbook enforces, applied in the app so a draft that slips through
// gets flagged for Dan before approval. Complements (doesn't replace) the agentic
// self-critique in the Prep run.
enum DraftIssue: Equatable, Hashable, Sendable {
    case performativeEnthusiasm   // AI-tell warmth: "love to", "thrilled", "!", etc.
    case emDash                   // brand voice: no em dashes
    case presumesBooking          // assumes the client already decided to hire him
    case coldHedge                // hedges like a cold pitch at a warm/repeat client
    case asksForKnownFact         // asks the contact for the date/venue Overture already holds (#456)

    var label: String {
        switch self {
        case .performativeEnthusiasm: return "Performative enthusiasm or an exclamation point"
        case .emDash: return "Contains an em dash"
        case .presumesBooking: return "Presumes the booking instead of handing back the decision"
        case .coldHedge: return "Hedges like a cold pitch at a warm client"
        case .asksForKnownFact: return "Asks for the date or venue Overture already knows"
        }
    }
}

enum DraftCheck {
    private static let performative = ["love to", "thrilled", "so excited", "excited", "can't wait", "delighted", "honored", "thrilled to"]
    private static let booking = ["lock in", "plan to cover", "i'll cover", "i'll be covering", "i'll plan to", "i will cover", "i'll be there to photograph"]
    private static let coldHedges = ["if you haven't arranged", "if you haven't booked", "if you haven't found", "if you haven't hired", "in case you still need", "if you still need a photographer"]

    // Phrases that ask the CONTACT to supply the date/venue (#456 / #438). Curated to be specific
    // enough that merely stating the fact ("I'll be there on April 12") never trips them — only a
    // request does. Matched as lowercased substrings, like the lists above.
    private static let dateRequests = ["let me know the date", "let me know when", "what date", "what's the date", "what is the date", "which date", "what day", "when is the show", "when's the show", "when is the performance", "when's the performance", "when is the concert", "when's the concert", "when is the event", "when's the event", "confirm the date", "send me the date", "send over the date", "remind me of the date", "remind me when"]
    private static let venueRequests = ["what venue", "which venue", "what's the venue", "what is the venue", "let me know the venue", "name of the venue", "what location", "which location", "what's the location", "what is the location", "let me know the location", "let me know where", "send me the venue", "send me the location", "where is the show", "where's the show", "where is the performance", "where's the performance", "where is the concert", "where's the concert", "where is the event", "where's the event", "where is it being held", "where is it taking place", "where will it be held"]

    // `knownsDate`/`knownsVenue` opt the caller into the #456 known-fact check: the flag fires ONLY
    // when Overture actually holds that fact, since asking is legitimate when it doesn't. Defaulting
    // both to false keeps every existing single-argument call site byte-for-byte unchanged.
    static func findings(in body: String, knownsDate: Bool = false, knownsVenue: Bool = false) -> [DraftIssue] {
        let text = body.lowercased()
        var issues: [DraftIssue] = []
        if body.contains(Typography.emDash) { issues.append(.emDash) }
        if body.contains("!") || performative.contains(where: text.contains) { issues.append(.performativeEnthusiasm) }
        if booking.contains(where: text.contains) { issues.append(.presumesBooking) }
        if coldHedges.contains(where: text.contains) { issues.append(.coldHedge) }
        let asksKnownDate = knownsDate && dateRequests.contains(where: text.contains)
        let asksKnownVenue = knownsVenue && venueRequests.contains(where: text.contains)
        if asksKnownDate || asksKnownVenue { issues.append(.asksForKnownFact) }
        return issues
    }
}
