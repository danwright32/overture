import Foundation

// #722: a lightweight, heuristic backstop for the runbook's own "hard press/media-disqualify
// rule" (#635), the same shape as VenueContactGuard (#388). Checks both the contact's email
// address and their stated role, since a press/media giveaway can show up in either.
enum PressContactGuard {
    private static let keywords = ["press", "media", "publicrelations"]

    static func looksLikePressContact(email: String?, role: String?) -> Bool {
        if let local = localPart(of: email), matches(local) { return true }
        if let role, !role.isEmpty, matches(role) { return true }
        return false
    }

    private static func matches(_ s: String) -> Bool {
        let slugged = slug(s)
        return keywords.contains { slugged.contains($0) }
    }

    private static func localPart(of email: String?) -> String? {
        guard let email, let at = email.firstIndex(of: "@") else { return nil }
        return String(email[..<at])
    }

    private static func slug(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
