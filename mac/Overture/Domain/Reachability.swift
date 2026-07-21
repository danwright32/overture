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
    // #1324: `weakContactOnly` is a probed show whose only found address is a venue front desk or a press
    // inbox (held by the venue/press guard, so not sendable). An email exists, so "No email found" would
    // be untrue; this names the weak result honestly without pretending it is sendable.
    // #1325: `staleProbe` is a probe whose result is older than the freshness window. The org may have
    // moved since, so the firm answer becomes a distinct "worth re-checking" state instead of a stale
    // firm claim.
    enum Badge: Equatable { case none, hardToReach, noEmailFound, weakContactOnly, staleProbe, emailFound }

    // #1325: how long a probe result is trusted before it reads as possibly out of date (~90 days,
    // roughly the pitch horizon). Past this the badge asks Dan to re-check rather than trusting the old
    // answer.
    static let probeFreshness: TimeInterval = 90 * 24 * 60 * 60

    // A probe result older than the freshness window. Never-probed (nil) is not stale.
    static func probeIsStale(probedAt: Date?, now: Date) -> Bool {
        guard let probedAt else { return false }
        return now.timeIntervalSince(probedAt) > probeFreshness
    }

    static func badge(probed: Bool, hasSendableEmail: Bool, hasWeakContactEmail: Bool = false,
                      probeIsStale: Bool = false,
                      presenter: String?, sourceListingURL: String?, websiteURL: String?) -> Badge {
        if probed {
            // A stale result (found or not) reverts to "worth re-checking", so it never misleads.
            if probeIsStale { return .staleProbe }
            if hasSendableEmail { return .emailFound }
            return hasWeakContactEmail ? .weakContactOnly : .noEmailFound
        }
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

    // #1324: a probe found an address, but only the venue's front desk or a press inbox, not the
    // presenter's own. Real, but weak: worth naming honestly rather than calling it no email at all.
    static let weakContactOnlyBadge = "Weak contact only"
    static let weakContactOnlyHelp =
        "A reachability check found only a venue or press address for this show, not the presenter's own. You can still keep it and add a stronger contact by hand."

    // #1325: the earlier probe result has aged past the freshness window, so it may no longer be true.
    static let staleProbeBadge = "Reachability may be out of date"
    static let staleProbeHelp =
        "This show was checked over 90 days ago, so that earlier result may have changed. Run Check reachability again to refresh it before you decide."
}

// #1308 Layer 2: the opt-in per-date probe (Layer 2). Kept out of the views (testable, #885), named so the
// copy-inventory shows the whole sentence Dan reads.
enum ReachabilityProbeCopy {
    static let controlLabel = "Check reachability"
    static let controlHelp =
        "Check which of this date's still-open shows are actually emailable, before you keep one and dismiss the rest."
    // #1323: shown while a Prep or another probe already holds the single run slot, so the greyed-out
    // control explains itself instead of failing after the tap.
    static let controlBusyHelp =
        "A run is already in progress. This will be available once it finishes."

    static func confirmTitle(count: Int) -> String {
        "Check reachability for these \(count) shows?"
    }
    static func confirmMessage(dateLabel: String) -> String {
        "This looks up a real contact for the still-open shows on \(dateLabel), so you can tell which are emailable before you keep one. It spends a little on that lookup, only for the shows you check here."
    }
    static let confirmProceed = "Check"
}
