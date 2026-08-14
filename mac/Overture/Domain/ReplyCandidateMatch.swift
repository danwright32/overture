import Foundation

// #2714: which of the messages #2713 found could be the presenter answering, and which must never be
// proposed at all.
//
// The draft specified this only by what makes it FIRE. What it must REFUSE is the harder and more
// consequential half, because confirming a proposal writes that address onto the contact and a future
// pitch then goes there by email. A failed identification that falls back to a nearby candidate is
// exactly the defect L75 names, and here the nearby candidate is usually the room.
//
// MEASURED on the live Release store, 2026-08-14, over the five open form and DM pitches. Four of the
// five are at The Green Room 42. Any path by which a venue word can score would put that room's own
// newsletter above the real presenter on four of Dan's five open pitches, every week, for ever. So the
// venue is not merely left out of the token set: every word of it is subtracted from the title tokens,
// and `venueWordsNeverScore` fails if a venue word can ever earn a point.
//
// The same measurement supplies the two strongest signals, neither of which the draft mentioned: four
// of five routes are personal-name domains (caseengaines.com, reevecarney.com, jerrickcavagnaro.com,
// alexsyiek.com) and the fifth is a handle carrying the collective's name, while `Recipient.name`
// holds the person Dan actually pitched on four of five.
@MainActor
enum ReplyCandidateMatch {

    // Why a message was thrown out before anything was ranked. Named cases rather than a bool, because
    // the surface has to be able to say WHICH protection fired if it ever needs to (L11), and because a
    // refusal for the room's sake and a refusal for a bounce are not the same fact.
    enum Refusal: String, Equatable, Sendable {
        case automated
        case theRoomsOwn
        case aPressDesk
        case bulkMail
        case dansOwn
    }

    struct Scored: Equatable, Sendable {
        var message: GmailReplySearch.InboundMessage
        var score: Int
        // What earned each point, so a proposal can be explained and a wrong one can be diagnosed
        // without re-deriving the arithmetic by hand.
        var reasons: [String]
    }

    // Three answers, not two. AMBIGUOUS is its own outcome beside "nothing looks like them" (L11):
    // asking Dan "is this them?" about one of two equally plausible messages is asking him to guess,
    // and a wrong confirmation writes a stranger's address onto the contact.
    enum Verdict: Equatable, Sendable {
        case nothingLooksLikeThem
        case ambiguous(top: [Scored])
        case proposed(Scored)
    }

    // A proposal must clear the floor AND beat the runner-up by the margin. The floor is set at 4 so
    // that no single weak signal can carry a proposal on its own: a title word in a subject line (3) is
    // not enough by itself, while the contact's own name matching the sender (4) is.
    static let floor = 4
    static let margin = 2

    // MARK: refusals

    // Nil when the message may be ranked, a reason when it may not. Applied to every candidate BEFORE
    // any scoring, so a refused message cannot win, cannot be the runner-up, and cannot make a real
    // proposal look ambiguous.
    static func refusal(for m: GmailReplySearch.InboundMessage, venue: String?,
                        selfEmail: String) -> Refusal? {
        if m.fromAddress == ReplyDetection.email(from: selfEmail) { return .dansOwn }
        if ReplyDetection.isAutomated(m.fromAddress) { return .automated }
        // Bulk mail, told by the header bulk senders set rather than by guessing at words. This is what
        // actually protects Dan from the room's newsletter, because `VenueContactGuard` compares the
        // SLUGGED venue against the domain's second-level label and "The Green Room 42" slugs to
        // "thegreenroom42" while greenroom42.com gives "greenroom42", so the leading "The" makes them
        // unequal and the venue guard does not fire on his most common room. That gap is recorded in
        // `theVenueGuardMissesALeadingThe` and filed as its own issue rather than patched here, because
        // widening a guard four other callers depend on is not a rider on this change.
        if let unsubscribe = m.listUnsubscribe?.trimmingCharacters(in: .whitespacesAndNewlines),
           !unsubscribe.isEmpty { return .bulkMail }
        // The two guards that already gate `usableContactFormURLs`, asked here so this new route cannot
        // reach a contact the rest of the product has always refused (#368, #635).
        if VenueContactGuard.looksLikeVenue(email: m.fromAddress, venue: venue) { return .theRoomsOwn }
        if PressContactGuard.looksLikePressContact(email: m.fromAddress, role: nil) { return .aPressDesk }
        return nil
    }

    // MARK: the tokens a message is compared against

    struct Tokens: Equatable, Sendable {
        // The form host's own name, or a social handle: "caseengaines", "vivaceartscollective".
        var routeSlug: String?
        // `Recipient.name`, slugged. The person Dan actually pitched.
        var contactSlug: String?
        var presenterSlug: String?
        // The show's title words, with the venue's words and ordinary stopwords taken out.
        var titleTokens: [String]
    }

    // Words that identify nobody. Deliberately short: the venue subtraction below does the heavy work,
    // and a long list would start removing real names.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "with", "at", "of", "for", "in", "on", "or", "to", "by", "from",
        "presents", "present", "featuring", "feat", "live", "show", "concert", "night", "sings",
        "celebration", "anniversary", "th", "st", "nd", "rd",
    ]

    static func tokens(for r: Recipient, on p: Prospect) -> Tokens {
        // Every word of the venue, so a title that happens to repeat the room's name cannot smuggle it
        // back in through the title tokens.
        let venueWords = Set(words(in: p.venue ?? ""))
        let title = words(in: p.groupName).filter { !venueWords.contains($0) && !stopwords.contains($0) }
        return Tokens(routeSlug: routeSlug(from: r.formOutreachURL ?? r.contactFormURL),
                      contactSlug: nonEmptySlug(r.name),
                      presenterSlug: nonEmptySlug(p.presenter),
                      titleTokens: title)
    }

    // The identifying half of the route. A social profile puts it in the PATH (every act on Instagram
    // shares the domain and is told apart by its handle), which is `VenueContactGuard`'s own reasoning
    // for reading a link's path rather than its host on a social URL.
    static func routeSlug(from raw: String?) -> String? {
        guard let raw, let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        if Reachability.isSocialOnly(raw) {
            return url.path.split(separator: "/").first.map { slug(String($0)) }.flatMap(nonEmpty)
        }
        guard let host = url.host else { return nil }
        let parts = host.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nonEmpty(slug(host)) }
        return nonEmpty(slug(String(parts[parts.count - 2])))
    }

    // MARK: scoring

    // Every point a message earns, and what earned it. Pure, so the whole table can be driven from a
    // test without a mailbox.
    static func score(_ m: GmailReplySearch.InboundMessage, tokens t: Tokens) -> Scored {
        // The three places a sender's identity can be written, all slugged the same way so one
        // comparison can take any of them.
        let nameSlug = slug(m.fromName ?? "")
        let localSlug = slug(String(m.fromAddress.split(separator: "@").first ?? ""))
        let domainSlug: String = {
            let parts = m.fromAddress.split(separator: "@").last?.split(separator: ".") ?? []
            guard parts.count >= 2 else { return "" }
            return slug(String(parts[parts.count - 2]))
        }()
        let senderSlugs = [nameSlug, localSlug, domainSlug].filter { !$0.isEmpty }
        let subjectWords = Set(words(in: m.subject))
        let nameWords = Set(words(in: m.fromName ?? ""))

        var score = 0
        var reasons: [String] = []
        func award(_ points: Int, _ why: String) {
            score += points
            reasons.append(why)
        }

        // Deliberately NOT filtered against a list of mail providers. One was written here first and
        // then removed: no route slug or contact name in the live store is a provider's name, so the
        // list could never change an answer, and an untested rule that cannot fire is worse than no
        // rule at all (L29, and L144, which this file's own venue note is the other half of).
        let identifying = senderSlugs

        // copy-inventory:ignore-start  the reasons behind a score, for diagnosing a wrong proposal.
        // NOT the app's own voice: nothing renders these today, and #2718 owns the sentence Dan
        // actually reads when it asks "is this them?". Named here rather than left as a bare
        // exemption, because an exclusion with no reviewer named is how copy ends up with no reader
        // at all (L129).
        if let route = t.routeSlug, identifying.contains(route) {
            award(5, "the sender is the form's own name: \(route)")
        } else if let route = t.routeSlug, route.count >= 5,
                  identifying.contains(where: { $0.contains(route) }) {
            award(3, "the sender carries the form's own name: \(route)")
        }

        if let contact = t.contactSlug, identifying.contains(contact) {
            award(4, "the sender is the contact Dan pitched")
        } else if let contact = t.contactSlug, contact.count >= 5,
                  identifying.contains(where: { $0.contains(contact) }) {
            award(3, "the sender carries the name of the contact Dan pitched")
        }

        if let presenter = t.presenterSlug, presenter != t.contactSlug, identifying.contains(presenter) {
            award(2, "the sender is the presenter")
        }

        // The title, minus the venue and the stopwords. A single distinctive word is worth less than a
        // name match on purpose: it is the weakest of these signals and the easiest to hit by accident.
        let inSubject = t.titleTokens.filter { subjectWords.contains($0) }
        if !inSubject.isEmpty {
            award(3, "the subject names the show: \(inSubject.joined(separator: " "))")
        }
        let inName = t.titleTokens.filter { nameWords.contains($0) }
        if !inName.isEmpty {
            award(1, "the sender's name carries a word from the show's title")
        }

        // copy-inventory:ignore-end
        return Scored(message: m, score: score, reasons: reasons)
    }

    // MARK: the verdict

    static func judge(_ candidates: [GmailReplySearch.InboundMessage], for r: Recipient, on p: Prospect,
                      selfEmail: String) -> Verdict {
        let t = tokens(for: r, on: p)
        let ranked = candidates
            .filter { refusal(for: $0, venue: p.venue, selfEmail: selfEmail) == nil }
            .map { score($0, tokens: t) }
            .filter { $0.score >= floor }
            // Sorted by score, then by message id, so a run is reproducible and two equal scores do not
            // change places between ticks.
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.message.messageId < $1.message.messageId }

        guard let top = ranked.first else { return .nothingLooksLikeThem }
        guard let runnerUp = ranked.dropFirst().first else { return .proposed(top) }
        guard top.score - runnerUp.score >= margin else {
            // Everything within the margin of the top, so Dan is shown the field rather than one
            // arbitrary member of it.
            return .ambiguous(top: ranked.filter { top.score - $0.score < margin })
        }
        return .proposed(top)
    }

    // MARK: slugging

    private static func slug(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func nonEmptySlug(_ s: String?) -> String? {
        guard let s else { return nil }
        return nonEmpty(slug(s))
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    // Lowercased words, punctuation dropped, so "Song & Word" gives ["song", "word"].
    private static func words(in s: String) -> [String] {
        s.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
