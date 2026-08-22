import Foundation

// #2629: what Dan can type into Add a contact, and the ONE place that decides it.
//
// The Review card tells him "No email to send to. Add a contact by hand." when a show has no emailable
// contact, and the control that sentence points at offered a single Email field, disabled until the text
// parsed as one address. So on exactly the shows the sentence appears on, the route he actually has (a
// contact form on the producer's own site, or since #2612 an Instagram he will DM) was the one thing the
// control could not accept. He met an instruction that could not be followed, which is L109's shape: the
// refusal and the control disagree, and it is invisible from inside the code because the popover is
// entirely correct about emails.
//
// It cost real data on 2026-08-13: he deleted a show's found contacts wanting to add the producer
// instead, discovered the producer publishes only a form, and could not add it, which left the show with
// no contact at all and a stale reachability verdict (#2664).
//
// Both the button's enabled state and the add itself go through `parse`, so the control cannot look
// enabled on something the add would then refuse, nor refuse something it looks willing to take.
enum ManualContactRoute: Equatable, Sendable {
    // An email address. The route that already worked, unchanged.
    case email(String)
    // A page Dan opens and fills in or writes on by hand: a contact form, or a social profile. Stored on
    // the recipient as `contactFormURL`, which is the SAME field the reachability check writes for a
    // form-only or social-only contact, so a hand-added route and a found one are the same kind of thing
    // to every reader downstream (the card's links, the count above them, the stored verdict).
    case link(String)

    // Nil when the text is not a route at all, which is exactly when the control refuses.
    //
    // Order matters and is deliberate: an address is tried FIRST, because `a@x.org` would otherwise be a
    // plausible-looking host and be filed as a link, which sends nothing and silently loses the one route
    // that can be emailed.
    static func parse(_ raw: String) -> ManualContactRoute? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let one = EmailAddressList.single(trimmed) { return .email(one) }
        return normalizedLink(trimmed).map { .link($0) }
    }

    // A pasted link, with a scheme added when it is missing.
    //
    // The scheme is not cosmetic: every surface that offers one of these builds a `URL` and drops
    // anything with a nil scheme (`Prospect.usableContactFormURLs`, `QueueModel.usableContactFormURL`).
    // So storing `instagram.com/heybaylor` verbatim would create a contact that no card ever shows, which
    // is the same defect this issue is about, one layer further in and harder to see.
    private static func normalizedLink(_ trimmed: String) -> String? {
        // Anything with whitespace inside it is prose, not a link. Checked before the scheme test so
        // "see the form at x.org/contact" is refused rather than half-read.
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        // An ATTEMPTED address is never a link, however URL-shaped it looks. Without this, `,,olga@x.org`
        // and `a@x.org, b@y.org` fall past the address parser (which correctly rejects both) and get a
        // scheme bolted on, so a typo becomes a contact carrying an unopenable route and the person is
        // told it worked. Caught by `AddContactAddressRuleTests`, which already pinned those two refusals
        // and went red: the refusals were right and this arm was quietly overruling them.
        //
        // An `@` in a genuine http URL is userinfo, which nothing Dan pastes here carries, so refusing it
        // costs nothing and keeps the two arms from disagreeing about who owns an address-shaped string.
        guard !trimmed.contains("@"), !trimmed.contains(","), !trimmed.contains(";") else { return nil }
        let withScheme = trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
            ? trimmed
            : "https://" + trimmed
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, host.contains("."),   // a bare word is not a host
              !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        return withScheme
    }

    // What the recipient's stored handle is, through `Recipient.makeId`, which is also what
    // `ContactRefusal` keys a strike on. One function, so a hand-added contact and a refusal of it can
    // never disagree about what names it (the reason #2438 taught both to take a form).
    var recipientId: String? {
        switch self {
        case .email(let address): return Recipient.makeId(email: address, formURL: nil)
        case .link(let url): return Recipient.makeId(email: nil, formURL: url)
        }
    }

    var email: String? {
        if case .email(let address) = self { return address }
        return nil
    }

    var link: String? {
        if case .link(let url) = self { return url }
        return nil
    }
}
