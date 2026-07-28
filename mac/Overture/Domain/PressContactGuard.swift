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

    // #1636: the same question asked of a contact FORM's link, the sibling of #1629's venue check.
    // #1626 made a form a way through and nothing kept a press office's page out of that, so a check
    // returning one produced a card sending Dan to a press desk, against the runbook's hard press and
    // media disqualify rule (#635). The live case is a Bryant Park show whose form was
    // carnegiehall.org/About/Press/Ticket-and-Media-Guidelines, which #1629's venue guard cannot catch
    // because carnegiehall.org is not that show's room; it is a third party's press office.
    //
    // THE PATH ONLY, and that is the careful part. The email rule reads the LOCAL PART and ignores the
    // domain, so "press@carnegiehall.org" is a press contact while "booking@pressplayrecords.com" is
    // not. The faithful analogue for a link is its path. Pointing the email rule's own substring check
    // at a whole URL would be actively wrong: "espresso" contains "press" and "multimedia" contains
    // "media".
    //
    // WHOLE PATH COMPONENTS, not substrings, for the same reason: a component is slugged (its hyphens
    // and punctuation removed) and must then EQUAL a keyword. Splitting any finer would miss
    // "/public-relations", which slugs to one word; splitting any coarser would match "/espresso-bar".
    //
    // KNOWN RESIDUAL RISK, recorded rather than guessed at: an act's own press-kit page (its site's
    // "/press") would be flagged, and for a small act that could be the only way through. Nothing in the
    // store lets this tell that apart from a press office, because it would need to know the act's own
    // domain and `websiteURL` is empty on all 575 untriaged rows. No such form exists in the store today
    // (measured 2026-07-27, 14 forms, 1 press page), so the rule is not shaped around a case that has
    // never occurred. If one turns up, that is the signal to revisit, not this comment.
    static func looksLikePressContact(formURL: String?) -> Bool {
        guard let formURL, !formURL.isEmpty,
              let url = URL(string: formURL.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return url.path
            .split(separator: "/")
            .contains { keywords.contains(slug(String($0))) }
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
