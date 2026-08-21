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
    case galleryPathLink          // deep-links one gallery instead of the site itself (#1832)
    case venueHistoryCount        // states how MANY times Dan has shot the room (#1887)
    case hedgedEffectClaim        // weakens the claim that the audience doesn't notice him (#2722)
    case asksForNothing           // admires the show and requests nothing (#1889, #2531)
    case repeatedSentenceShape    // two sentences in a row built the same way (#2807)
    case restatesItself           // a sentence that says one thing twice, or padding (#2949)
    case repeatsOneWord           // one word carrying the same idea across too many sentences (#2949)

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
        case .galleryPathLink: return "Links one gallery instead of the portfolio itself"
        case .venueHistoryCount: return "Says how many times Dan has shot the venue"
        case .hedgedEffectClaim: return "Hedges the claim that the audience doesn't notice Dan"
        case .asksForNothing: return "Asks for nothing: no request about their photography plans"
        case .repeatedSentenceShape: return "Two sentences in a row are built the same way"
        case .restatesItself: return "A sentence says the same thing twice"
        case .repeatsOneWord: return "One word is doing the same job in too many sentences"
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
        // #1832: a gallery deep link clears the same bar the other two do. It is an exact comparison
        // against five known paths, so there is nowhere for a false positive to come from, and the thing
        // it prevents is a choice made on the recipient's behalf that Dan does not want made.
        // #1887: a count of past shoots clears the same bar. The app deliberately sends the drafter a
        // BAND and no number, so a number in this shape was invented, and it is a claim about Dan's own
        // history made to someone who works at that venue. The matcher is narrow enough to have nowhere
        // for a false positive to come from: see hasVenueHistoryCount.
        case .foreignLink, .placeholder, .galleryPathLink, .venueHistoryCount: return true
        // #2722: advisory, deliberately. It is a rule about TONE rather than a fact about the
        // text, which is the bar #789 set for a blocker, and it reads a hedge from a word
        // sitting in the same sentence as the claim, so a body can pair them innocently. The
        // cost of a wrong block is Dan's time on a draft that reads perfectly.
        // #2531: advisory for the same reason. Whether a sentence ASKS for something is a judgment about
        // wording, and the runbook instructs the run to reword the ask every time, so the phrasing this
        // rule has never seen is the ordinary case rather than the exception.
        // #2807: advisory, and settled by the precedent above rather than reopened. Cadence is a rule
        // about TONE, not a fact about the text, which is the bar #789 set for a blocker. It reads a
        // CONSTRUCTION out of punctuation and connector words, and English lets a perfectly good pair of
        // sentences land on the same one; the cost of a wrong block is Dan's time on a draft that reads
        // fine.
        // #2949: both advisory, for the reason above them. They are judgements about WORDING, which is
        // not the bar #789 set for a blocker, and the cost of a wrong block is Dan's time on a draft that
        // reads fine.
        case .performativeEnthusiasm, .emDash, .presumesBooking, .coldHedge,
             .asksForKnownFact, .concessionLanguage, .nonCanonicalRate,
             .hedgedEffectClaim, .asksForNothing, .repeatedSentenceShape,
             .restatesItself, .repeatsOneWord: return false
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
    // copy-inventory:ignore-start  draft lint needles: phrases the linter HUNTS FOR, never words it says (#915)
    //
    // The distinction the inventory turns on: Overture never says "thrilled to" to Dan, it says
    // "Performative enthusiasm or an exclamation point" (the reasons above, which ARE in the list).
    // These are search terms, and there are sixty-odd of them against nine reasons, so counting them as
    // copy would have made one file's needles a tenth of everything the app appears to say.

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

    // #2722: words that WEAKEN the audience-doesn't-notice claim. Dan, 2026-08-14, reading "most
    // audiences don't notice I'm there at all" in his own outgoing pitch: "It implies that some
    // audiences *do* notice." A hedge invites the reader to picture the audiences that DID notice,
    // which is the exact objection a presenter has about letting a photographer into a performance,
    // and "at all" over-corrects on the other end, so one short claim carries a hedge and an
    // intensifier at once.
    //
    // The multiword entries are the ones whose bare word is too common to hunt alone: "some" and
    // "many" are ordinary English until they are attached to the audience, where they become the
    // quantifier this rule exists to catch.
    private static let effectHedges = [
        "usually", "generally", "typically", "often", "rarely", "hardly", "barely", "seldom",
        "mostly", "really", "most", "for the most part", "tend to", "tends to", "tend not to",
        "pretty much", "by and large", "in general", "at all",
        "some audiences", "many audiences", "some people", "many people",
    ]

    private static let venueRequests = ["what venue", "which venue", "what's the venue", "what is the venue", "let me know the venue", "name of the venue", "what location", "which location", "what's the location", "what is the location", "let me know the location", "let me know where", "send me the venue", "send me the location", "where is the show", "where's the show", "where is the performance", "where's the performance", "where is the concert", "where's the concert", "where is the event", "where's the event", "where is it being held", "where is it taking place", "where will it be held"]
    // #2949: the two new rules' needles, here rather than beside their matchers, because a
    // copy-inventory region opened inside this one would close it early and leak every sentence after it.
    private static let paddingPhrases = ["other rooms around the city", "plenty of other rooms"]
    private static let familiarityClaim = "familiar with"
    private static let roomWords = ["room", "rooms", "space", "spaces"]
    // The other half of the restatement: a claim in the same sentence that he has already worked there.
    // Both verbs, since the runbook's own wordings use both.
    private static let historyClaims = ["photograph", "shot ", "shoot at"]
    // copy-inventory:ignore-end

    // `knownsDate`/`knownsVenue` opt the caller into the #456 known-fact check: the flag fires ONLY
    // when Overture actually holds that fact, since asking is legitimate when it doesn't. Defaulting
    // both to false keeps every existing single-argument call site byte-for-byte unchanged.
    // #2531: `isColdPitch` opts the caller into the ask check, and it is opt-IN for the same reason
    // `knowns*` are. The rule is a COLD pitch rule: the runbook's CTA section is about opening a
    // conversation with a stranger. A warm or returning-client note is a different register and the eval
    // gates the identical check behind its own `wordingRules` flag.
    //
    // Not theoretical. `DraftCheckTests.passesTheVersionDanActuallySent` holds a real email Dan sent to a
    // returning client ("If you'd like me to photograph this year's event as well, just say the word"),
    // which asks for nothing by this rule and is exactly right for who it went to. The first version of
    // this check applied to every body and flagged it, and that test is what caught it.
    static func findings(in body: String, title: String? = nil,
                         knownsDate: Bool = false, knownsVenue: Bool = false,
                         isColdPitch: Bool = false) -> [DraftIssue] {
        let text = body.lowercased()
        var issues: [DraftIssue] = []
        if body.contains(Typography.emDash) { issues.append(.emDash) }
        // #1141: an exclamation point inside the show's OWN title (e.g. "...Glee!") is part of its name,
        // not enthusiasm the drafter added, so strip the known title before hunting for a stray "!". A
        // performative word anywhere still fires (the title never licenses "thrilled"), and with no title
        // supplied (the blocking path, legacy call sites) this is byte-for-byte the old check.
        if hasStrayExclamation(bodyOutsideTitle(body, title: title))
            || performative.contains(where: text.contains) {
            issues.append(.performativeEnthusiasm)
        }
        if booking.contains(where: text.contains) { issues.append(.presumesBooking) }
        if coldHedges.contains(where: text.contains) { issues.append(.coldHedge) }
        let asksKnownDate = knownsDate && dateRequests.contains(where: text.contains)
        let asksKnownVenue = knownsVenue && venueRequests.contains(where: text.contains)
        if asksKnownDate || asksKnownVenue { issues.append(.asksForKnownFact) }
        if hasConcession(text) { issues.append(.concessionLanguage) }
        if hasNonCanonicalRate(text) { issues.append(.nonCanonicalRate) }
        if hasForeignLink(body) { issues.append(.foreignLink) }
        if hasPlaceholder(body) { issues.append(.placeholder) }
        if hasGalleryPathLink(body) { issues.append(.galleryPathLink) }
        if hasVenueHistoryCount(body) { issues.append(.venueHistoryCount) }
        if hasHedgedEffectClaim(text) { issues.append(.hedgedEffectClaim) }
        if restatesItself(text) { issues.append(.restatesItself) }
        if repeatsOneWord(text) { issues.append(.repeatsOneWord) }
        if hasRepeatedSentenceShape(body) { issues.append(.repeatedSentenceShape) }
        if isColdPitch, !asksAboutPhotographyPlans(body) { issues.append(.asksForNothing) }
        return issues
    }

    // #2531: does the body actually REQUEST something, and does the request presuppose they have
    // photography plans for this show?
    //
    // #1889 put this rule behind the eval, which scores PRODUCED output only, so a draft Dan writes or
    // edits by hand never met it: a pitch that admires the show and asks for nothing could be sent. The
    // draft warnings already read his own text rather than exempting it, so it belongs here.
    //
    // ADVISORY, not blocking. #789's bar for a blocker is a FACT about the text rather than a judgment
    // about its wording, and this is a judgment: the runbook tells the run to reword the ask every time,
    // so an unusual but perfectly good phrasing is exactly the thing a wording rule gets wrong. The cost
    // of a wrong block is Dan's time on the draft he actually wants to send.
    //
    // ONE judgment shared with the TypeScript eval (`prepEval.asksAboutPhotographyPlans`), through the
    // corpus at `fixtures/draft-ask/cases.json` that both sides are tested against (L26). The patterns
    // below are the same three, and `DraftAskCasesTests` is what stops them drifting: 34 of its cases are
    // real compliant drafts, which word the ask nine different ways, because the accept side is the half
    // that protects a good draft (L104).
    //
    // Sentence-scoped, so naming their plans somewhere and asking something somewhere else is not an ask.
    static func asksAboutPhotographyPlans(_ body: String) -> Bool {
        for sentence in body.split(whereSeparator: { ".!?\n".contains($0) }) {
            let s = String(sentence)
            if s.range(of: photographyPlans, options: [.regularExpression, .caseInsensitive]) != nil,
               s.range(of: askCue, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    private static let photographyPlans =
        #"\b(?:photography|photo|picture)\s+plans\b|\bplan(?:s|ned|ning)\s+for\s+(?:photography|photos|pictures|coverage)\b|\bphotograph(?:y|s)\s+(?:is\s+|already\s+)?(?:sorted|arranged|planned|booked)\b"#
    private static let askCue = #"\b(?:talk|speak|discuss|hear|ask|asking|tell me|chat|learn|know)\b"#

    // #789: only the findings that BLOCK the send. Deliberately takes no `knowns*` context: a
    // blocker must be judgeable from the text alone, so this is safe to call anywhere the body is
    // known (the send gate, the queue, the UI) without threading the prospect's facts through.
    static func blockingFindings(in body: String) -> [DraftIssue] {
        findings(in: body).filter(\.isBlocking)
    }

    // #1906: an exclamation mark is allowed in the CLOSING line, and nowhere else.
    //
    // Dan's call, 2026-07-31, after this check flagged his own sign-off: he edited a real draft to end
    // "I look forward to hearing from you!" and kept it. The rule was written for performative warmth
    // in the body of an email, and it was catching the one place he uses a mark deliberately.
    //
    // Exactly one, and only in the last sentence. A body ending in a run of them is performative again,
    // which is what the rule is for. The performative WORD list is unaffected and still fires anywhere,
    // including in the closing line, so "I'd be thrilled to hear from you!" is still caught.
    private static func hasStrayExclamation(_ text: String) -> Bool {
        let marks = text.filter { $0 == "!" }.count
        guard marks > 0 else { return false }
        guard marks == 1 else { return true }
        guard let idx = text.lastIndex(of: "!") else { return true }
        // Nothing but whitespace may follow it: that is what makes it the closing line rather than a
        // mid-email flourish.
        guard text[text.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return true }
        // And there has to be an actual email in front of it. Without this, a body that is nothing
        // BUT an exclamation ("Come see the show!") reads as its own closing line and walks straight
        // through, which is precisely the performative shape the rule was written for. Two existing
        // tests caught this; the exemption is for a sign-off, not for any sentence that ends a string.
        return !text[..<idx].contains { $0 == "." || $0 == "?" }
    }

    // #1141: the body with the show's own title removed, so an exclamation point (or other punctuation)
    // that belongs to the title can't trip a text check. Case-insensitive because the drafter may recase
    // the title; a blank or absent title changes nothing. Only the "!" check reads this: every other
    // check still sees the whole body.
    private static func bodyOutsideTitle(_ body: String, title: String?) -> String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return body }
        return body.replacingOccurrences(of: title, with: " ", options: .caseInsensitive)
    }

    private static func hasConcession(_ text: String) -> Bool {
        if concession.contains(where: text.contains) { return true }
        // "free" as a standalone word, but not the warm phrase "feel free".
        return text.range(of: #"(?<!feel )\bfree\b"#, options: .regularExpression) != nil
    }

    // #789. The ONLY host a draft may link is Dan's own site: there is no pricing page and no
    // client-gallery host to point at, so any other host is something the drafter invented. A 404 (or
    // someone else's site) in a cold pitch is exactly the unforced error that costs the lead.
    static let allowedLinkHost = "danwrightphotography.com"

    // #1832: the five galleries the site keeps. A draft links the SITE and lets the reader click into
    // whichever of these they want (Dan, 2026-07-30), so a deep link into one of them is a choice made on
    // their behalf. Listed here rather than matched loosely, so a page that is not one of the five (an
    // about or contact page Dan links deliberately) is untouched.
    static let galleryPaths = ["music", "bands", "comedy", "dance", "performing-arts"]

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

    // #1832: a link into one of the five galleries rather than the site itself. Emails are stripped
    // first, exactly as the foreign-link scan does, so an address at Dan's own domain is never read as a
    // path. The path must be the whole first segment, so a hypothetical /music-notes page would not match
    // a rule that is about the five galleries and nothing else.
    private static func hasGalleryPathLink(_ body: String) -> Bool {
        let text = body.replacingOccurrences(of: emailPattern, with: " ", options: .regularExpression)
        let host = allowedLinkHost.replacingOccurrences(of: ".", with: "\\.")
        return galleryPaths.contains { path in
            let pattern = "(?i)(?:https?://)?(?:www\\.)?\(host)/\(path)(?![A-Za-z0-9-])"
            return text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    // A template slot the drafter left unfilled ("Hi [NAME]", "at [VENUE]"). Square brackets carry no
    // ordinary meaning in Dan's prose, so their mere presence is the signal; no vocabulary to keep
    // in sync with whatever the drafter happens to name its slots.
    private static func hasPlaceholder(_ body: String) -> Bool {
        body.range(of: #"\[[^\]\n]{1,60}\]"#, options: .regularExpression) != nil
    }

    // #1887: the draft states HOW MANY times Dan has shot this room.
    //
    // Dan's rule is that a pitch never claims an exact number, and the app enforces it by sending the
    // drafter a BAND and no count at all (PrepQueueItem.venueHistory). A number in this shape was
    // therefore invented, which makes it a fabricated fact about Dan's own history, told to somebody
    // who works at the venue. That is why it BLOCKS rather than warns.
    //
    // Deliberately narrow, so it clears the "nowhere for a false positive to come from" bar:
    //   1. a PAST-TENSE, first-person shooting phrase ("I've shot", "I have photographed", ...), which
    //      is what keeps it away from an offer about the show being pitched. "I'll be photographing
    //      your three performances" is a perfectly good sentence and must not be blocked.
    //   2. a numeral or number word, or a standalone count word ("twice", "a couple"),
    //   3. within a few words of a countable noun for an occasion (show, time, concert, night, ...).
    //
    // What it deliberately does NOT catch is the sanctioned band wording: "a few shows there" carries
    // no number, and the Carnegie tenure credential ("close to ten years") is a number attached to
    // YEARS, not to a countable occasion, so neither trips it.
    // #2722: a hedge sitting in the SAME SENTENCE as the audience-doesn't-notice claim.
    //
    // A SHAPE rather than a string, deliberately. The drafter can weaken this claim fifty ways, and a
    // needle for the one phrasing seen in the wild would pass on every paraphrase while reading as
    // protection (L96). Matching any hedge co-occurring with the claim is wider than that and still
    // narrow enough to stand somewhere.
    //
    // Sentence-scoped, which is the whole of what keeps it usable. Asked of the body as a whole it would
    // fire on any pitch that says "most of my work is concert" in one paragraph and "the audience doesn't
    // notice me" in another, which is a correct draft, and a check that fires on the common case gets
    // switched off within a day (L93). The wording every shipped fixture uses, "the audience doesn't
    // notice me and the performance isn't disturbed", carries no hedge and is asserted unflagged.
    //
    // What it CANNOT do is judge the other effect claims (no flash, the performance not disturbed,
    // documentary rather than posed), because those have no single word to key on. The runbook and the
    // brand voice skill state the rule for all of them; this is the tripwire for the one already met.
    // #2949: a sentence that says one thing twice, and the padding that says nothing at all.
    //
    // Dan, 2026-08-16, on a real cold pitch: "I've photographed a few shows in that room, so I'm familiar
    // with the space." The second half restates the first, costing a beat and adding nothing. Same class
    // as the audience-half rule above, on a different pair.
    //
    // Narrow on purpose, and MEASURED: "familiar with" appears in none of the 70 compliant bodies this
    // repo holds, so a sentence that both claims the history and then claims familiarity is not a shape
    // Dan's own drafts produce. The padding phrase is here rather than in its own case because its defect
    // is the same one, a clause that adds nothing, and it appears in none of them either.
    private static func restatesItself(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if paddingPhrases.contains(where: { lowered.contains($0) }) { return true }
        for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")) {
            let s = sentence.lowercased()
            guard s.contains(familiarityClaim) else { continue }
            if historyClaims.contains(where: { s.contains($0) }) { return true }
        }
        return false
    }

    // #2949: one word doing the same job in too many sentences.
    //
    // Dan counted "room", "space" and "rooms" inside four sentences of one draft. Not a cadence problem,
    // so `repeatedSentenceShape` cannot see it.
    //
    // THREE is the threshold, and it comes from the real distribution rather than from taste (L172).
    // Measured across all 70 compliant bodies in `fixtures/prep-eval` and `fixtures/draft-ask`: 22 never
    // mention the room, 40 mention it in one sentence, 8 in two, and NONE in three. So three is one clear
    // of everything Dan's own drafts do, and the draft he objected to had four.
    //
    // Counted per SENTENCE, not per occurrence: twice in one sentence is the restatement rule's business,
    // and counting occurrences would make a single compound sentence look like a pattern.
    private static let mostSentencesOneWordMayCarry = 2

    private static func repeatsOneWord(_ text: String) -> Bool {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let carrying = sentences.filter { sentence in
            roomWords.contains { containsWord($0, in: sentence) }
        }
        return carrying.count > mostSentencesOneWordMayCarry
    }

    private static func hasHedgedEffectClaim(_ text: String) -> Bool {
        for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")) {
            guard sentence.contains("notice") else { continue }
            if effectHedges.contains(where: { hedge in
                hedge.contains(" ") ? sentence.contains(hedge) : containsWord(hedge, in: sentence)
            }) {
                return true
            }
        }
        return false
    }

    // #2807: two sentences in a row built the same way.
    //
    // Dan, 2026-08-16, on a real cold pitch: "this draft is a lot of short sentences and doesn't feel
    // great". Three of its sentences were long, so length was not it. What he was hearing was three
    // consecutive sentences of one shape (independent clause, comma, "and"/"so", trailing clause), two of
    // them ending on the same "so ..." effect tail. Every sentence was individually compliant: every
    // drafting rule is scoped to ONE sentence and each supplies its own canonical phrasing, so used back
    // to back they stack. Nothing governed variety WITHIN one email.
    //
    // THE DETECTOR THAT LOOKS RIGHT AND IS NOT. Counting first-person sentence openings is the first
    // instinct (six of the eight sentences began with I, I'm, I've or My). Scored against Dan's OWN proven
    // cold pitch, which the brand voice skill keeps as the reference, that rule REFUSES it: five of its six
    // sentences open in first person, three of them consecutively, a higher rate than the draft he
    // complained about. A lint that blocks Dan's own text is a defect this repo has shipped before. Both
    // texts are in `DraftCadenceTests`, the bad one as the case that must be caught and his as the case
    // that must pass, so a later "improvement" cannot quietly re-derive the pronoun rule.
    //
    // What separates them is CONSTRUCTION. Dan's pitch alternates: compound, simple, compound,
    // fronted-subordinate, compound, simple, and no two neighbours are built the same way. So: inside one
    // paragraph, no two consecutive sentences may carry the same connector construction.
    //
    // PARAGRAPH-SCOPED, and that is load-bearing. #2807's own reference rewrite, the shape it holds up as
    // correct, keeps two "so" tails and splits them across a paragraph break. A break resets the cadence
    // for the reader, and paragraphing is the other half of what the issue asks for, so a draft clears this
    // finding either by varying the construction or by breaking the block, and both are the fix.
    //
    // There is deliberately NO check on paragraph LENGTH, though the runbook and the skill both ask for
    // short paragraphs. Dan's reference pitch is one block of six sentences, so any rule capping sentences
    // per paragraph refuses it, exactly the way the pronoun rule does.
    static func hasRepeatedSentenceShape(_ body: String) -> Bool {
        for paragraph in paragraphs(of: body) {
            let shapes = sentences(in: paragraph).map(sentenceShape)
            for i in shapes.indices.dropLast() where shapes[i] != nil && shapes[i] == shapes[i + 1] {
                return true
            }
        }
        return false
    }

    // A blank line starts a new paragraph, which is what a reader sees. A single newline does not: Dan's
    // reference pitch puts its greeting on the line directly above the first sentence.
    private static func paragraphs(of body: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        for line in body.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { out.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n")) }
        return out
    }

    // The sentences of one paragraph.
    //
    // A greeting line ("Hi Emma,") and a routing line ("Attn: ..., Director of Marketing") are dropped
    // first, because they end in punctuation that is not a sentence end and would otherwise be glued onto
    // the sentence below, donating a comma that invents a construction the sentence does not have.
    //
    // The split needs whitespace AND a capital after the mark, because the one link every draft carries
    // ends in ".com" and a naive split on "." cuts it in half.
    private static func sentences(in paragraph: String) -> [String] {
        let lines = paragraph
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix(",") && !$0.hasSuffix(":") }
        let text = lines.joined(separator: " ")
        guard !text.isEmpty,
              let re = try? NSRegularExpression(pattern: #"[.!?]["')\]]*\s+(?=[A-Z"(])"#) else {
            return text.isEmpty ? [] : [text]
        }
        let ns = text as NSString
        var out: [String] = []
        var start = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let end = m.range.location + m.range.length
            out.append(ns.substring(with: NSRange(location: start, length: end - start)))
            start = end
        }
        if start < ns.length { out.append(ns.substring(from: start)) }
        return out
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // copy-inventory:ignore-start  cadence lint needles: connector and subordinator words MATCHED in a draft, never words Overture says (#2807)

    // The connectors that join a trailing clause after a comma. "so" is on it because the doubled
    // "so ..." effect tail is the pair Dan actually heard; it needs no special case, it is one value.
    private static let clauseConnectors = ["and", "so", "but", "which", "though", "while", "or", "yet",
                                           "because", "since"]
    // A sentence that opens on one of these, with a comma in it, is a fronted subordinate clause.
    private static let subordinators: Set<String> = ["if", "when", "while", "since", "because",
                                                     "although", "though", "after", "before", "once",
                                                     "unless", "whenever", "as"]
    // What a real clause starts with, used ONLY to tell a clause join from an Oxford comma. Without it
    // "Madison Square Garden, Lincoln Center, and Radio City Music Hall" reads as a connector, and since
    // that exact list is in Dan's own reference pitch the rule would refuse his text (L104: test the
    // matcher against what it must PRESERVE, not only against what it must catch).
    private static let clauseSubjects: Set<String> = ["i", "i'm", "i've", "i'd", "i'll", "it", "it's",
                                                      "we", "you", "they", "he", "she", "there", "that",
                                                      "my", "the", "his", "her", "their", "your"]
    // copy-inventory:ignore-end

    // The construction of one sentence, or nil for a sentence that joins no clause. A nil NEVER pairs:
    // Dan's complaint was explicitly not about length, so two short plain sentences side by side are not
    // this defect and must not be reported as it.
    private static func sentenceShape(_ sentence: String) -> String? {
        if isFrontedSubordinate(sentence) { return "fronted" }
        if let connector = commaJoinedConnector(sentence) { return "comma-" + connector }
        return nil
    }

    private static func isFrontedSubordinate(_ sentence: String) -> Bool {
        guard sentence.contains(",") else { return false }
        let first = sentence.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz'").inverted)
            .first { !$0.isEmpty } ?? ""
        return subordinators.contains(first)
    }

    // The FIRST comma-joined connector whose trailing text reads as a clause rather than as the last item
    // of a list. Only "and" and "or" need that test: no list is written "x, so y".
    private static func commaJoinedConnector(_ sentence: String) -> String? {
        let pattern = #",\s+("# + clauseConnectors.joined(separator: "|") + #")\s+([a-z']+)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let ns = sentence as NSString
        for m in re.matches(in: sentence, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 1)).lowercased()
            let next = ns.substring(with: m.range(at: 2)).lowercased()
            if (word == "and" || word == "or") && !clauseSubjects.contains(next) { continue }
            return word
        }
        return nil
    }

    // A whole-word containment test, so "most" does not fire on "almost" and "often" does not fire on
    // "soften". The needle lists above are matched as substrings by design; this one cannot be, because
    // its words are short and common enough to sit inside other words.
    private static func containsWord(_ word: String, in sentence: String) -> Bool {
        let parts = sentence.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return parts.contains(word)
    }

    private static func hasVenueHistoryCount(_ body: String) -> Bool {
        // copy-inventory:ignore-start  Words MATCHED in a draft, never shown to Dan (#1887)
        let pastTenseShooting =
            #"(?i)\bI(?:'ve| have)?\s+(?:have\s+)?(?:shot|photographed|covered|worked)\b"#
        let numberWord =
            #"(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|dozen|dozens|"#
            + #"several|numerous|countless|multiple|many)"#
        let occasion = #"(?:show|shows|time|times|concert|concerts|performance|performances|"#
            + #"night|nights|gig|gigs|event|events|occasion|occasions)"#
        // "twice"/"three times" and "a couple of" are counts written as words rather than digits.
        let standaloneCount = #"(?i)\b(?:twice|thrice|a\s+couple(?:\s+of)?)\b"#
        // copy-inventory:ignore-end

        for sentence in body.components(separatedBy: CharacterSet(charactersIn: ".!?\n")) {
            guard sentence.range(of: pastTenseShooting, options: .regularExpression) != nil else {
                continue
            }
            if sentence.range(of: standaloneCount, options: .regularExpression) != nil { return true }
            let counted = #"(?i)\b"# + numberWord + #"\b(?:\s+\w+){0,2}\s+"# + occasion + #"\b"#
            if sentence.range(of: counted, options: .regularExpression) != nil { return true }
        }
        return false
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
