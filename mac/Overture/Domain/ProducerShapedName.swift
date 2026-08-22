import Foundation

// #2259: one answer to "does this phrase name a producing company, or is it marketing?"
//
// Two places have to ask it now: the VenueTix feed's marketing supertitle (`VenueTixCalendar`) and the
// credit standing in front of the show's title on its own listing page (`ListingOrganiser`). They are the
// same question about the same rooms, and a second spelling of it is how one surface starts pitching a
// slogan while the other refuses it.
//
// CALIBRATED against the live VenueTix feed rather than invented (L48). Fetched 2026-08-07: 229 events,
// 141 distinct supertitles. A first rule (possessive ending, or any of Productions / Company /
// Entertainment / Collective / Theatre / Studio) matched 34 and was wrong on several, taking
// "A Jennings Vocal Studio NYC Cabaret" and a twelve-word marketing line. This one matches 25, and every
// one of those reads as a real producer.
//
// The length caps are what separate a NAME from a SENTENCE, and they are the load-bearing part: an
// organisation's name is short, marketing runs on.
enum ProducerShapedName {

    // The company this phrase names, or nil when the phrase is marketing rather than a credit.
    static func from(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = normalisingSpaces(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // #2554: an explicit credit answers this outright, whoever it names, and it is read through the ONE
        // credit rule rather than a second spelling of it here (#2452, L89). Measured on the live VenueTix
        // feed 2026-08-13: four of the 148 distinct supertitles carry a producing credit and every one was
        // refused. Asked FIRST, because a supertitle that says who produced the show has answered the
        // question, and the shape rules are only what to do when nothing says so.
        if let credited = billedInProse(trimmed) { return credited }
        return shapedLikeAnOrganisation(trimmed)
    }

    // The shape rules, unchanged since the 2026-08-07 calibration: what to conclude from a phrase that
    // states no credit at all. Split out of `from` by #2554 so the credit rule can call it without the two
    // calling each other, and so the boundary that calibration set stays one readable block.
    private static func shapedLikeAnOrganisation(_ trimmed: String) -> String? {
        // A connector names the company after it ("Hosted by Vivace Arts Collective"). The connector is
        // not part of the name, so it goes; but a phrase that needed one is no longer a bare possessive,
        // which is why the possessive arm below refuses a stripped string.
        // copy-inventory:ignore-start  parser tokens matched against a ticketing feed, never Overture's voice
        let connectors = ["from ", "featuring ", "hosted by ", "based on ", "presented by ",
                          "starring ", "celebrating "]
        // copy-inventory:ignore-end
        var core = trimmed
        var hadConnector = false
        for lead in connectors where core.lowercased().hasPrefix(lead) {
            core = String(core.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
            hadConnector = true
            break
        }
        guard !core.isEmpty else { return nil }
        let words = core.split(separator: " ").count

        let endsPossessive = ["\u{2019}s", "'s", "s\u{2019}", "s'"].contains { core.hasSuffix($0) }
        if endsPossessive, !hadConnector, words <= 5 { return withoutPossessive(core) }

        let organisationWords = ["production", "productions", "company", "entertainment",
                                 "collective", "media"]
        let isOrganisation = core.split(separator: " ").contains { word in
            organisationWords.contains(word.lowercased().trimmingCharacters(
                in: CharacterSet.alphanumerics.inverted))
        }
        if isOrganisation, words <= 6 { return withoutPossessive(core) }
        return nil
    }

    // #2452: the ONE entry point every feed adapter uses to decide who presents a row.
    //
    // Four call sites answered "does this credit line name a producing company?" independently, and gave
    // it three different readings: VenueTix read its supertitle through the rule above, OvationTix folded
    // the same field into the show's document and left the room as the presenter, and TicketTailor named
    // the room unconditionally. Each file reads as correct alone, which is why nothing caught it; two
    // readers writing one field are one vocabulary and have to be reconciled against each other (L89).
    //
    // `credit` is whatever the feed prints ABOVE the show's title, and is nil both when the row credits
    // nobody and when the feed publishes no such field at all. `fallback` is whoever's calendar this is,
    // which is what the row has always been attributed to and what it keeps when no company is named.
    static func presenter(creditedAbove credit: String?, orElse fallback: String) -> String {
        from(credit) ?? fallback
    }

    // #2262: the producer a listing BILLS inside its own description, which is how a RENTAL ROOM credits
    // the company putting the show on. The room's name leads the page, so there is nothing in front of
    // the title to read; the credit sits in the blurb ("Produced by Productions by Stephan, Re-Arranged
    // is a one-night-only celebration").
    //
    // MEASURED against all 61 listings reachable from https://54below.org/calendar/ on 2026-08-11: 17
    // bill a producer this way, ONE of them a company and 16 individuals, and a bare personal name is
    // not producer-shaped, so this returns nothing on those 16 rather than reaching for them.
    //
    // Only an ADJACENT "produced by" / "presented by" counts. That is the whole difference between a
    // credit and prose: the same pages carry "Hayley Trapp presents The Bubbling Cabaret" (the act
    // introducing her own show), "the Showpeople Theatre Collective returns to New York City" and
    // "Developed with the historic Apollo Theater and Drama Club Camp Productions" (where a musical was
    // written), none of which names who is producing tonight.
    static func billedInProse(_ prose: String) -> String? {
        let text = normalisingSpaces(prose)
        guard let mark = attachedCredit(in: text) else { return nil }

        let candidate = text[mark.upperBound...]
            .prefix { !creditStops.contains($0) }
            .split(separator: " ")
            .prefix(creditWordCeiling)
            .joined(separator: " ")

        // A credit names somebody, and a name starts with a capital. Without this, "produced by the
        // company that staged it" reads as an organisation, because `company` is one of the words the
        // rule below looks for and the phrase is short enough to pass.
        guard let first = candidate.first, first.isUppercase else { return nil }
        // #2554: the CREDIT is what establishes this is a producer, so the name behind it does not also
        // have to look like a company. That second requirement is what refused all 16 individuals billed
        // on 54 Below's own listings and all four credit-bearing supertitles in the VenueTix feed, on a
        // rental room where the individual IS the person who hired the room and would hire a photographer.
        return shapedLikeAnOrganisation(candidate) ?? creditedName(candidate)
    }

    // #2554: WHERE the credit attaches, which is what separates this show's producer from a credit inside
    // a performer's biography. Measured across the 23 listing texts in the prep run archives, every
    // "produced by" in them falls into one of two shapes:
    //
    //   the show's own       ". Produced by Amy Sapp", "this concert is produced and directed by Corin Hale"
    //   somebody's past      "\"Ghouls Just Wanna Have Fun!\" produced by Moore Productions",
    //                        "a compilation produced by Tito Pingolinis"
    //
    // The real ones open a sentence or follow a linking verb, because they are a statement about THIS show.
    // The false ones hang off another work, a quoted title or an album. So the test is what the credit
    // attaches to, and deliberately not how far into the page it sits: a distance bound would have worked
    // on this corpus (real credits at 656 to 1050 characters past the title, false ones at 1250 and 1555)
    // and would be a threshold fitted to one snapshot and then trusted as a contract (L48, L56).
    //
    // This makes the rule STRICTER for companies as well as wider for people. "produced by Moore
    // Productions" is accepted today, out of a bio, and the runbook has to warn the run about exactly that
    // class; refusing it here is the same fix, one step earlier.
    private static func attachedCredit(in text: String) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for phrase in creditConnectors {
            var searchFrom = text.startIndex
            while let found = text.range(of: phrase, options: [.caseInsensitive],
                                         range: searchFrom..<text.endIndex) {
                if attaches(to: text[..<found.lowerBound]) {
                    if best == nil || found.lowerBound < best!.lowerBound { best = found }
                    break
                }
                searchFrom = found.upperBound
                if searchFrom >= text.endIndex { break }
            }
        }
        return best
    }

    // Nothing before it (the whole phrase IS the credit, which is the supertitle case), a finished
    // sentence, or a linking verb whose subject is the show.
    private static func attaches(to before: Substring) -> Bool {
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return true }
        if sentenceEnds.contains(last) { return true }
        let lastWord = trimmed.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        return linkingVerbs.contains(lastWord.lowercased())
    }

    // #2554: the name behind a credit, whoever it belongs to. Bounded the same way `from` is, because the
    // ceiling is what separates a NAME from a SENTENCE, and that was always the load-bearing part.
    private static func creditedName(_ candidate: String) -> String? {
        let core = candidate.trimmingCharacters(in: .whitespaces)
        guard let first = core.first, first.isUppercase else { return nil }
        let words = core.split(separator: " ")
        guard (1...6).contains(words.count) else { return nil }
        // Every word capitalised, or joined by the small words a name runs through ("Christophe Desorbay
        // and Emily Currie"). Prose that got this far ("the company that staged it" cannot, it fails the
        // capital above) stops here.
        guard words.allSatisfy({ word in
            word.first?.isUppercase == true || nameInternalWords.contains(word.lowercased())
        }) else { return nil }
        return withoutPossessive(core)
    }

    // copy-inventory:ignore-start  parser tokens matched against a listing page, never Overture's voice
    // The small words a name runs through. "and" is here because a show is routinely produced by two
    // people ("Produced by Christophe Desorbay and Emily Currie", one of 54 Below's 16).
    private static let nameInternalWords: Set<String> = ["and", "of", "the", "for", "by", "&"]
    // No dash here, and not because the style gate objects: `UserFacingDashGuardTests` reads escapes too,
    // and more to the point no measured credit needed one. `creditStops` makes the same choice for the same
    // reason, and says so.
    private static let sentenceEnds: Set<Character> = [".", "!", "?", ";", ":"]
    private static let linkingVerbs: Set<String> = ["is", "was", "are", "were", "being", "been"]
    // copy-inventory:ignore-end

    // Where the credit ENDS. The credit runs into the sentence that carries it, and these are the marks
    // the real pages separate it with ("Produced by Amanda Negrete . Music direction by Elijah Cox .").
    // All 17 measured credits are punctuated this way; where one is not, the candidate takes the next
    // word or two with it and `from`'s six-word ceiling is what stops it becoming a sentence. The dash a
    // page may separate a clause with is deliberately not on this list, because the app's source may not
    // hold one at all (`UserFacingDashGuardTests`), and its absence can only make this narrower.
    // copy-inventory:ignore-start  parser tokens matched against a listing page, never Overture's voice
    // #2554 adds the combined credit. It is not a variation worth skipping: "this concert is produced and
    // directed by Corin Hale" is the exact line Dan hit, and searching for "produced by " inside it
    // matches nothing at all. Listed longest first so the fuller phrase wins, which also matters to the
    // attachment test: matching "Produced by" inside "Directed & Produced by Desirée Dabney" would leave
    // it reading "&" and refusing a credit that opens its own line.
    private static let creditConnectors = ["directed and produced by ", "directed & produced by ",
                                           "produced and directed by ", "produced & directed by ",
                                           "produced by ", "presented by "]
    private static let creditStops: Set<Character> = [",", ".", ";", ":", "!", "?", "(", ")", "\"",
                                                      "\u{201C}", "\u{201D}"]
    // copy-inventory:ignore-end

    // `from` refuses anything longer than six words anyway. This only stops the candidate being the rest
    // of the page when a sentence happens to carry no punctuation at all.
    private static let creditWordCeiling = 8

    // The trailing possessive belongs to the show title that followed it, never to the company, so it is
    // removed from what gets stored. Left on, every later search for this organisation would carry a stray
    // apostrophe, which is exactly the over-qualified query that buried ICB Productions under a Norwegian
    // firm and a retail chain.
    // #2554: the pages this reads write a non-breaking space inside a credit, as the HTML entity and as the
    // character. Measured in the prep run archives: two of the four real credits are "Produced by&nbsp;
    // <name>", so without this the rule matches nothing on exactly the pages it exists for, and would look
    // correct on every hand-written fixture.
    private static func normalisingSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ", options: [.caseInsensitive])
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    static func withoutPossessive(_ s: String) -> String {
        for suffix in ["\u{2019}s", "'s", "\u{2019}", "'"] where s.hasSuffix(suffix) {
            return String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}
