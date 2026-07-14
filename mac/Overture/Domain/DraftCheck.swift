import Foundation

// A deterministic self-check over a drafted email (#11): the same brand-voice and stance
// rules the drafter runbook enforces, applied in the app so a draft that slips through
// gets flagged for Dan before approval. Complements (doesn't replace) the agentic
// self-critique in the Prep run.
enum DraftIssue: Equatable, Hashable, Sendable, CaseIterable {
    case performativeEnthusiasm   // AI-tell warmth: "love to", "thrilled", "!", etc.
    case emDash                   // brand voice: no em dashes
    case presumesBooking          // assumes the client already decided to hire him
    case coldHedge                // hedges like a cold pitch at a warm/repeat client
    case asksForKnownFact         // asks the contact for the date/venue Overture already holds (#456)
    case concessionLanguage       // offers a discount or free/complimentary work (#39/#458)
    case nonCanonicalRate         // states a rate other than the canonical $250/hr + tax (#39/#458)
    case foreignLink              // links a host that is not Dan's own site (#789)
    case placeholder              // a template slot the drafter never filled: "[VENUE]" (#789)

    var label: String {
        switch self {
        case .performativeEnthusiasm: return "Performative enthusiasm or an exclamation point"
        case .emDash: return "Contains an em dash"
        case .presumesBooking: return "Presumes the booking instead of handing back the decision"
        case .coldHedge: return "Hedges like a cold pitch at a warm client"
        case .asksForKnownFact: return "Asks for the date or venue Overture already knows"
        case .concessionLanguage: return "Offers a discount or free/complimentary work"
        case .nonCanonicalRate: return "States a rate other than $250 an hour plus tax"
        case .foreignLink: return "Links a site that is not danwrightphotography.com"
        case .placeholder: return "Contains an unfilled placeholder like [VENUE]"
        }
    }

    // #789: a blocking finding stops the send (Recipient.isSendablePending) instead of merely
    // warning; everything else stays advisory. The bar Dan set is that a block must be as close to
    // impossible to false-positive as a text check gets, because the cost of a wrong block is his
    // time and the cost of a missed one is a stranger reading it. Both blockers clear that bar: they
    // are facts about the text, not judgments about its tone.
    //
    // nonCanonicalRate is DELIBERATELY advisory despite #789 proposing it as a blocker. It fires on
    // any dollar figure that is not 250, so a draft that merely mentions a ticket price or a travel
    // figure reads perfectly and would still have been blocked. Same for concessionLanguage, whose
    // matcher fires on the bare word "flexible".
    var isBlocking: Bool {
        switch self {
        case .foreignLink, .placeholder: return true
        case .performativeEnthusiasm, .emDash, .presumesBooking, .coldHedge,
             .asksForKnownFact, .concessionLanguage, .nonCanonicalRate: return false
        }
    }

    // A stable order for the blockers gathered across several recipients, so the warning rows can't
    // reshuffle between redraws (a Set's order would).
    static func orderedBlockers(_ found: Set<DraftIssue>) -> [DraftIssue] {
        allCases.filter { $0.isBlocking && found.contains($0) }
    }
}

enum DraftCheck {

    // #885: the sentence that tells Dan a draft is HELD. It names the actual findings rather than saying
    // "there is a problem", because the whole point is that he can tell at a glance whether it is a
    // foreign link or a leftover placeholder and fix it in one edit. Computed in DraftReviewView's body
    // before, then interpolated into a SECOND sentence in the override confirm, so neither was testable.
    //
    // The empty fallback is not defensive padding: without it a block with nothing to name would read
    // "This draft won't send: ." and tell him nothing at all about what to fix.
    static func blockMessage(blockers: [DraftIssue]) -> String {
        let what = blockers.map(\.label).joined(separator: " and ")
        return "This draft won't send: \(what.isEmpty ? "a blocking issue" : what)."
    }
    private static let performative = ["love to", "thrilled", "so excited", "excited", "can't wait", "delighted", "honored", "thrilled to"]
    private static let booking = ["lock in", "plan to cover", "i'll cover", "i'll be covering", "i'll plan to", "i will cover", "i'll be there to photograph"]
    private static let coldHedges = ["if you haven't arranged", "if you haven't booked", "if you haven't found", "if you haven't hired", "in case you still need", "if you still need a photographer"]

    // Phrases that ask the CONTACT to supply the date/venue (#456 / #438). Curated to be specific
    // enough that merely stating the fact ("I'll be there on April 12") never trips them; only a
    // request does. Matched as lowercased substrings, like the lists above.
    private static let dateRequests = ["let me know the date", "let me know when", "what date", "what's the date", "what is the date", "which date", "what day", "when is the show", "when's the show", "when is the performance", "when's the performance", "when is the concert", "when's the concert", "when is the event", "when's the event", "confirm the date", "send me the date", "send over the date", "remind me of the date", "remind me when"]
    // Concession language banned in a cold pitch (#39/#458). "free" is handled separately with a
    // word boundary so "feel free" (natural warm phrasing) doesn't trip it.
    private static let concession = ["discount", "complimentary", "flexible"]

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
        if hasConcession(text) { issues.append(.concessionLanguage) }
        if hasNonCanonicalRate(text) { issues.append(.nonCanonicalRate) }
        if hasForeignLink(body) { issues.append(.foreignLink) }
        if hasPlaceholder(body) { issues.append(.placeholder) }
        return issues
    }

    // #789: only the findings that BLOCK the send. Deliberately takes no `knowns*` context: a
    // blocker must be judgeable from the text alone, so this is safe to call anywhere the body is
    // known (the send gate, the queue, the UI) without threading the prospect's facts through.
    static func blockingFindings(in body: String) -> [DraftIssue] {
        findings(in: body).filter(\.isBlocking)
    }

    private static func hasConcession(_ text: String) -> Bool {
        if concession.contains(where: text.contains) { return true }
        // "free" as a standalone word, but not the warm phrase "feel free".
        return text.range(of: #"(?<!feel )\bfree\b"#, options: .regularExpression) != nil
    }

    // #789. The ONLY host a draft may link is Dan's own site: the runbook maps each discipline onto
    // one of its five galleries and there is no pricing page and no client-gallery host to point at,
    // so any other host is something the drafter invented. A 404 (or someone else's site) in a cold
    // pitch is exactly the unforced error that costs the lead.
    static let allowedLinkHost = "danwrightphotography.com"

    // Deliberately NOT a general URL grammar. Prose is full of things that look like hosts once you
    // relax the rules ("the performing arts.The show", "e.g. no flash"), and a false block costs Dan
    // an override on text that was already fine. So a token only counts as a link when it is
    // unmistakable: it carries a scheme, or a `www.` prefix, or it ends in a real TLD.
    private static let linkPatterns = [
        #"(?i)https?://([A-Za-z0-9.-]+)"#,
        #"(?i)\bwww\.([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)"#,
        #"(?i)\b([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:com|org|net|io|co|us|nyc|info|edu|gov))\b"#,
    ]
    // An email address is not a link: it cannot 404, Dan's own appears in a signature, and a foreign
    // one may be a contact he was told to write to. Stripped BEFORE the link scan so the host inside
    // it ("tickets@carnegiehall.org") is never read as a link to that site.
    private static let emailPattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#

    private static func hasForeignLink(_ body: String) -> Bool {
        let text = body.replacingOccurrences(of: emailPattern, with: " ",
                                             options: .regularExpression)
        for pattern in linkPatterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var host = ns.substring(with: m.range(at: 1)).lowercased()
                if host.hasPrefix("www.") { host.removeFirst(4) }
                while host.hasSuffix(".") { host.removeLast() }
                if host != allowedLinkHost { return true }
            }
        }
        return false
    }

    // A template slot the drafter left unfilled ("Hi [NAME]", "at [VENUE]"). Square brackets carry no
    // ordinary meaning in Dan's prose, so their mere presence is the signal; no vocabulary to keep
    // in sync with whatever the drafter happens to name its slots.
    private static func hasPlaceholder(_ body: String) -> Bool {
        body.range(of: #"\[[^\]\n]{1,60}\]"#, options: .regularExpression) != nil
    }

    // The canonical rate is "$250 an hour plus tax, one-hour minimum" (#39). Any other dollar
    // figure in the body is a non-canonical rate; stating $250 itself is fine.
    private static func hasNonCanonicalRate(_ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: #"\$\s?(\d[\d,]*)"#) else { return false }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let amount = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
            if amount != "250" { return true }
        }
        return false
    }
}
