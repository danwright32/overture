import Foundation

// #1145 Layer 1: a free, always-on reachability heuristic read at Review, before the keep/dismiss
// decision. The expensive question ("what is the email address") is Prep's job; this answers the cheap,
// separate question ("is this org reachable at all") from signals already in hand after the scout, with no
// new fetch and no tokens. It exists to flag the known-dead cases so Dan never dismisses a reachable show
// in favour of a doubly-weak long shot he can't actually pitch.
//
// Deliberately coarse (the honest limit of free data): at Review a prospect has a presenter name and a
// source listing URL, but websiteURL is populated during Prep, so a "real website" can only ever be
// POSITIVE evidence when present, never required. Pure and exhaustively tested (a rule is only as real as
// its detection). Layer 2 (an opt-in per-date probe) upgrades this to a firmer email-found/not-found.
enum Reachability {
    enum Signal: Equatable { case likelyReachable, unclear, hardToReach }

    // #1308 Layer 2 Phase 2: what the Review row actually shows. Before a probe it is the free heuristic,
    // and only the hard case surfaces (a named presenter with no proven site stays silent, `.none`, so the
    // badge never over-promises). Once a probe has run it is the FIRM answer.
    enum Badge: Equatable { case none, hardToReach, noEmailFound, emailFound }

    static func badge(probed: Bool, hasSendableEmail: Bool,
                      presenter: String?, sourceListingURL: String?, websiteURL: String?) -> Badge {
        if probed { return hasSendableEmail ? .emailFound : .noEmailFound }
        switch assess(presenter: presenter, sourceListingURL: sourceListingURL, websiteURL: websiteURL) {
        case .hardToReach: return .hardToReach
        case .likelyReachable, .unclear: return .none
        }
    }

    static func assess(presenter: String?, sourceListingURL: String?, websiteURL: String?) -> Signal {
        // Positive evidence first: a confirmed real (non-social) website means outreach has a live target,
        // even if the listing itself was a social page.
        if let site = websiteURL, isRealWebsite(site) { return .likelyReachable }
        // A social-only source is a verified dead end: a raw fetch of these returns a login wall, and lead
        // intake already refuses them. Hard to reach whatever else is known.
        if let listing = sourceListingURL, isSocialOnly(listing) { return .hardToReach }
        // No presenting org identified, just a venue and a title: there is nothing to email.
        if (presenter ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .hardToReach }
        // A named presenter on a normal listing, but no proven website: Overture cannot cheaply confirm
        // reachability here, so it stays silent rather than over-promising.
        return .unclear
    }

    // Reuses LeadIntake's verified login-walled-host list (#1004) so the two never drift.
    private static func isSocialOnly(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return LeadIntake.knownUnreadableHost(url) != nil
    }

    private static func isRealWebsite(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return false }
        return LeadIntake.knownUnreadableHost(url) == nil
    }
}

// #1145 copy. Kept out of the view (testable, #885) and named so the copy-inventory shows the whole
// sentence Dan reads.
enum ReachabilityCopy {
    static let hardToReachBadge = "Hard to reach"
    static let hardToReachHelp =
        "Overture couldn't spot a way to email this one: no presenting org, or only a social page (which sits behind a login). You can still keep it and add a contact by hand. This is a heads up so you don't dismiss a reachable show in its place."

    // #1308 Layer 2 Phase 2: the firm result once a probe has run.
    static let emailFoundBadge = "Email found"
    static let emailFoundHelp = "A reachability check found a contact you can email for this show."
    static let noEmailFoundBadge = "No email found"
    static let noEmailFoundHelp =
        "A reachability check couldn't find an email for this show. You can still keep it and add a contact by hand."
}

// #1308 Layer 2: the opt-in per-date probe (Layer 2). Kept out of the views (testable, #885), named so the
// copy-inventory shows the whole sentence Dan reads.
enum ReachabilityProbeCopy {
    static let controlLabel = "Check reachability"
    static let controlHelp =
        "Check which of this date's still-open shows are actually emailable, before you keep one and dismiss the rest."

    static func confirmTitle(count: Int) -> String {
        "Check reachability for these \(count) shows?"
    }
    static func confirmMessage(dateLabel: String) -> String {
        "This looks up a real contact for the still-open shows on \(dateLabel), so you can tell which are emailable before you keep one. It spends a little on that lookup, only for the shows you check here."
    }
    static let confirmProceed = "Check"
}
