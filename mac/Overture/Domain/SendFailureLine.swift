import Foundation

// #316: one source of truth for the inline "this send failed" line shown next to a lead. Driven by
// the persisted Prospect.sendError that SendService writes on a real failure (and clears on success),
// so the indicator is durable — it survives a closed sheet and can't be hidden by a later success's
// transient banner. Used by both the Follow-ups rows and DraftReviewView so the wording matches.
enum SendFailureLine {
    static func text(for sendError: String?) -> String? {
        guard let raw = sendError?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return "Send failed: \(raw)"
    }
}
