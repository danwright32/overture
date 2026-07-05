import Foundation

// #297: one home for the reply/booking wording. Both the manual "Run reconcile now" acknowledgment
// (ReconcileSummary) and the automatic while-away notification (AwayAlert) format the same events, so
// they format them HERE; otherwise the same reply or booking can read two different ways across the
// two surfaces. Each helper names the orgs (Dan works by name) and returns nil when there is nothing to
// say, so callers can simply drop a nil fragment.
enum OutreachEventPhrasing {
    static func replyPhrase(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "\(names.count) new repl\(names.count == 1 ? "y" : "ies") (\(names.joined(separator: ", ")))"
    }

    static func bookingPhrase(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "\(names.count) new booking\(names.count == 1 ? "" : "s") (\(names.joined(separator: ", ")))"
    }
}
