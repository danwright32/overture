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

    var label: String {
        switch self {
        case .performativeEnthusiasm: return "Performative enthusiasm or an exclamation point"
        case .emDash: return "Contains an em dash"
        case .presumesBooking: return "Presumes the booking instead of handing back the decision"
        case .coldHedge: return "Hedges like a cold pitch at a warm client"
        }
    }
}

enum DraftCheck {
    private static let performative = ["love to", "thrilled", "so excited", "excited", "can't wait", "delighted", "honored", "thrilled to"]
    private static let booking = ["lock in", "plan to cover", "i'll cover", "i'll be covering", "i'll plan to", "i will cover", "i'll be there to photograph"]
    private static let coldHedges = ["if you haven't arranged", "if you haven't booked", "if you haven't found", "if you haven't hired", "in case you still need", "if you still need a photographer"]

    static func findings(in body: String) -> [DraftIssue] {
        let text = body.lowercased()
        var issues: [DraftIssue] = []
        if body.contains(Typography.emDash) { issues.append(.emDash) }
        if body.contains("!") || performative.contains(where: text.contains) { issues.append(.performativeEnthusiasm) }
        if booking.contains(where: text.contains) { issues.append(.presumesBooking) }
        if coldHedges.contains(where: text.contains) { issues.append(.coldHedge) }
        return issues
    }
}
