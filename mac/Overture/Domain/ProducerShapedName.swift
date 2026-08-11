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
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

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

    // The trailing possessive belongs to the show title that followed it, never to the company, so it is
    // removed from what gets stored. Left on, every later search for this organisation would carry a stray
    // apostrophe, which is exactly the over-qualified query that buried ICB Productions under a Norwegian
    // firm and a retail chain.
    static func withoutPossessive(_ s: String) -> String {
        for suffix in ["\u{2019}s", "'s", "\u{2019}", "'"] where s.hasSuffix(suffix) {
            return String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}
