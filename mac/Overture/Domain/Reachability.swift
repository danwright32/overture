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
    // #1626: `contactFormOnly` is a real way through, not a near miss, so it is its own state rather
    // than a shade of "no email". The row prints the link beside it.
    enum Badge: Equatable {
        case none, hardToReach, noEmailFound, weakContactOnly, contactFormOnly, staleProbe, emailFound
    }

    // Dan's call, 2026-07-28, looking at the real cards: the badges' loudness was the exact INVERSE of
    // how much he would act on them. "Contact form only" was the loudest thing on the row, "No email
    // found" next, and "Email found", the one he can act on immediately, was the quietest.
    //
    // The cause is structural, not a bad colour pick: forest green on Overture's dark forest background
    // has almost no contrast, so `.confirmed` is inherently the faintest tone in the app, and the best
    // news therefore read as the least important. Tone now tracks ACTIONABILITY, which is what his
    // standing rule already said about gold (reserved for what he can act on):
    //
    //   emailFound       gold    an address he can write to right now, the loudest thing on the row
    //   noEmailFound     rust    still prominent: deciding to drop a show is also acting on it
    //   contactFormOnly  muted   a real way through, but one that costs him fifteen minutes at their
    //                            site rather than a send, so it is the last thing he picks up. This
    //                            REVERSES the gold it was given two days ago in #1626, on his look at it.
    //   weakContactOnly  muted   same reasoning: a venue front desk is real but not what he acts on first
    //
    // Lives here rather than in the view's switch so the decision is testable at all: a SwiftUI body is
    // not, and this is exactly the "#885, keep the decision out of the view" pattern the copy follows.
    static func tone(for badge: Badge) -> OVPillTone {
        switch badge {
        case .emailFound: return .pending
        case .noEmailFound: return .warning
        case .contactFormOnly, .weakContactOnly, .hardToReach, .staleProbe, .none: return .neutral
        }
    }

    // #1325: how long a probe result is trusted before it reads as possibly out of date (~90 days,
    // roughly the pitch horizon). Past this the badge asks Dan to re-check rather than trusting the old
    // answer.
    static let probeFreshness: TimeInterval = 90 * 24 * 60 * 60

    // A probe result older than the freshness window. Never-probed (nil) is not stale.
    static func probeIsStale(probedAt: Date?, now: Date) -> Bool {
        guard let probedAt else { return false }
        return now.timeIntervalSince(probedAt) > probeFreshness
    }

    // #1596 Phase 3: what a check CONCLUDED, stored on the row rather than re-derived from its recipients
    // every time it draws. Deliberately NOT reusing `Badge`, whose `.none` means "render nothing"; a nil
    // result here means "no check has ever run", and two meanings for one token inside one feature is how
    // the #863 class of bug starts.
    // #1626: `contactFormOnly` is a show with no email whose act takes messages through a form on its
    // OWN site. Measured on the first real multi-date run (#1603): the check identified the act on 14 of
    // 14 shows, and 6 of those published only a form or an Instagram. Every one was stored with the link
    // and rendered "No email found", so Dan was told to give up on shows he could have written to.
    // Dan's rule (2026-07-27): a form on the act's own site counts and he fills it in by hand; an
    // Instagram or other social DM does not and stays a dead end.
    enum ProbeResult: String, Equatable, Sendable, CaseIterable {
        case emailFound = "email_found"
        case weakContactOnly = "weak_contact_only"
        case contactFormOnly = "contact_form_only"
        case noEmailFound = "no_email_found"
    }

    // nil means no check has ever run, which is a different thing from a check that came back empty. The
    // old signature could not tell those apart: it asked whether the row currently has a sendable
    // recipient, so a checked-and-empty show and a never-checked show both answered "no".
    // #1598 Phase 5: `inherited` is an answer paid for on a DIFFERENT show by the same organisation, and
    // it renders IDENTICALLY to one paid for here (Dan's call, 2026-07-27); only the hover text says
    // where it came from. A sixth badge state would be the #843 shape: a second line telling him nothing
    // the first did not. It is consulted only when this show has no answer of its own, and only ever
    // carries a positive, because OrgAnswerLedger refuses to fan out anything else.
    static func badge(result: ProbeResult?, probeIsStale: Bool = false,
                      inherited: ProbeResult? = nil,
                      presenter: String?, sourceListingURL: String?, websiteURL: String?) -> Badge {
        if let result {
            // A stale result (found or not) reverts to "worth re-checking", so it never misleads.
            if probeIsStale { return .staleProbe }
            switch result {
            case .emailFound: return .emailFound
            case .weakContactOnly: return .weakContactOnly
            case .contactFormOnly: return .contactFormOnly
            case .noEmailFound: return .noEmailFound
            }
        }
        // Freshness was already judged when the ledger was built, against the ORIGINAL check's date, so
        // it is not re-derived here: one decision, in one place.
        if inherited == .emailFound { return .emailFound }
        switch assess(presenter: presenter, sourceListingURL: sourceListingURL, websiteURL: websiteURL) {
        case .hardToReach: return .hardToReach
        case .likelyReachable, .unclear: return .none
        }
    }

    static func assess(presenter: String?, sourceListingURL: String?, websiteURL: String?) -> Signal {
        // Dead ends FIRST, so a website can never swallow them (#1335). A website is positive evidence only
        // ALONGSIDE a presenter on a non-social listing, never a standalone override of these known-dead cases.
        // A social-only source is a verified dead end: a raw fetch of these returns a login wall, and lead
        // intake already refuses them. Hard to reach whatever else is known, website or not.
        if let listing = sourceListingURL, isSocialOnly(listing) { return .hardToReach }
        // No presenting org identified, just a venue and a title: there is nothing to email, website or not.
        if (presenter ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .hardToReach }
        // With a presenter in hand and a non-social listing, a confirmed real (non-social) website is
        // positive evidence: outreach has a live target.
        if let site = websiteURL, isRealWebsite(site) { return .likelyReachable }
        // A named presenter on a normal listing, but no proven website: Overture cannot cheaply confirm
        // reachability here, so it stays silent rather than over-promising.
        return .unclear
    }

    // Reuses LeadIntake's verified login-walled-host list (#1004) so the two never drift.
    // #1626 made it internal rather than adding a second list: the question "is this link a social page
    // behind a login" is now asked in two places (the free heuristic here, and whether a contact form is
    // one Dan will actually use), and two lists would eventually disagree about Instagram.
    static func isSocialOnly(_ urlString: String) -> Bool {
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

    // #1598 Phase 5: the same badge, on a show whose answer was paid for on a different show by the same
    // organisation. The provenance lives here and nowhere else on the card, so a reused answer never
    // reads as a claim that this particular show was researched.
    static func inheritedEmailFoundHelp(organisation: String) -> String {
        "A reachability check on another \(organisation) show found this contact, so this show didn't need checking again."
    }
    static let noEmailFoundBadge = "No email found"
    static let noEmailFoundHelp =
        "A reachability check couldn't find an email for this show. You can still keep it and add a contact by hand."

    // #1626: no email, but the act takes messages through a form on its own site. A way through that
    // costs Dan a few minutes rather than a send, so it says what he would have to do.
    static let contactFormOnlyBadge = "Contact form only"
    static let contactFormOnlyHelp =
        "The act takes messages through the form on their own site. You'd fill that in yourself; Overture can't send it for you."

    // #1324: a probe found an address, but only the venue's front desk or a press inbox, not the
    // presenter's own. Real, but weak: worth naming honestly rather than calling it no email at all.
    static let weakContactOnlyBadge = "Weak contact only"
    static let weakContactOnlyHelp =
        "A reachability check found only a venue or press address for this show, not the presenter's own. You can still keep it and add a stronger contact by hand."

    // #1628: printed beside a contact the check itself recorded as a guess, so a guess stops reading like
    // a find. Two words, in the address line's own quiet meta styling, because it qualifies the address
    // rather than competing with Keep and Dismiss.
    //
    // It says "not verified" and not "low confidence": the stored word is the runbook's vocabulary, and
    // what Dan needs is the consequence. The hover text carries the rest.
    //
    // The wording claims ONLY the absence of a verified reading, never that the contact is wrong, and it
    // has to stay that way: the mark goes on every contact that is not an address read off a page naming
    // the act, which includes a generic inbox and a contact form that may well be perfectly correct. A
    // sentence asserting the contact was "inferred" would be false on both of those.
    static let unverifiedContactMark = "not verified"
    static let unverifiedContactHelp =
        "Overture didn't verify this one belongs to this act. Only an address read off a page naming them counts as verified; a generic inbox, a contact form, or an inferred address doesn't. It may still be right, so it's worth a look before you write."

    // #1325: the earlier probe result has aged past the freshness window, so it may no longer be true.
    static let staleProbeBadge = "Reachability may be out of date"
    static let staleProbeHelp =
        "This show was checked over 90 days ago, so that earlier result may have changed. Run Check reachability again to refresh it before you decide."
}

// #1308 Layer 2: the opt-in per-date probe (Layer 2). Kept out of the views (testable, #885), named so the
// copy-inventory shows the whole sentence Dan reads.
enum ReachabilityProbeCopy {
    static let controlLabel = "Check reachability"
    // #1595, then Dan's walk of the Debug build (2026-07-27): the callout had TWO headlines, one naming how
    // many shows compete for the date and one telling him to re-check a stale result. Both are gone with the
    // rest of the callout chrome. The control sits on all 169 of his dates, so a sentence there is noise on
    // 169 rows to earn its keep on one; and the stale sentence was a second telling of what the row's own
    // "Reachability may be out of date" badge already says beside it (#843).
    // #1323: shown while a Prep or another probe already holds the single run slot, so the greyed-out
    // control explains itself instead of failing after the tap.
    static let controlBusyHelp =
        "A run is already in progress. This will be available once it finishes."

    // #1334: reads for a single show (a lone stale re-check) as well as several, rather than "these 1 shows".
    static func confirmTitle(count: Int) -> String {
        count == 1 ? "Check reachability for this show?" : "Check reachability for these \(count) shows?"
    }
    static func confirmMessage(dateLabel: String, count: Int) -> String {
        count == 1
            ? "This looks up a real contact for the still-open show on \(dateLabel), so you can tell whether it's still emailable before you keep it. It spends a little on that lookup, only for the show you check here."
            : "This looks up a real contact for the still-open shows on \(dateLabel), so you can tell which are emailable before you keep one. It spends a little on that lookup, only for the shows you check here."
    }
    static let confirmProceed = "Check"
}
