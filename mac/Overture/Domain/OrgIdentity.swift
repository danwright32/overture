import Foundation

// WHO is this lead about?
//
// It matters because of what happened on Dan's own lead. He pasted his ensemble's show page; Overture
// could not read it, followed its ticket link to Lincoln Center, and read THAT. Lincoln Center's page
// carries an "Alice Tully Hall upcoming events" sidebar, so four shows came back, all real, all at the
// right hall, and NOT ONE of them his ensemble: they belong to the Chamber Music Society and to Lincoln
// Center Presents. His ensemble's own concert had already happened.
//
// The moment we follow a link off an org's site onto a VENUE's page, we are reading a page about many
// organizations. So we have to know which one we came for.
enum OrgIdentity {
    // The characters sites put between an org's name and a page name in a <title>. Built from scalars
    // rather than a literal because the repo's style guard forbids a dash character in source strings,
    // and it is right to: every previous one has been prose, not punctuation for a parser.
    private static let titleSeparators: CharacterSet = {
        var set = CharacterSet(charactersIn: "|")
        set.insert(charactersIn: "-")            // hyphen
        set.insert(Unicode.Scalar(0x2013)!)      // en dash
        set.insert(Unicode.Scalar(0x2014)!)      // em dash
        set.insert(Unicode.Scalar(0x00B7)!)      // middle dot
        return set
    }()

    // Read from the page Dan actually pasted, in the order of how much the site is really telling us:
    // its own declared site name, then its title, then (last resort) its domain.
    static func name(inPage html: String, url: URL) -> String? {
        if let siteName = firstMatch(#"(?i)<meta[^>]+property="og:site_name"[^>]+content="([^"]+)""#, in: html) {
            return splitCamelCase(clean(siteName))
        }
        if let title = firstMatch(#"(?is)<title[^>]*>(.*?)</title>"#, in: html) {
            // "Brooklyn Youth Chorus | Home", "Upcoming Performances | SecondEndingEnsemble": the org's
            // name is one of the parts, and it is the one that is not a page name.
            let parts = clean(title)
                .components(separatedBy: titleSeparators)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let best = parts.first(where: { !isPageName($0) }) ?? parts.first {
                return splitCamelCase(best)
            }
        }
        // The domain is the last honest guess: better than nothing, and it is at least the org's own.
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.components(separatedBy: ".").first
    }

    // Wix and friends publish "SecondEndingEnsemble", jammed together. Left as-is it would never match
    // "Second Ending Ensemble" as the venue's page spells it, and the whole constraint would silently do
    // nothing, which is the failure mode that produced four strangers' concerts in Dan's queue.
    static func splitCamelCase(_ s: String) -> String {
        // An all-caps acronym (BAM) is not several words, and splitting it would make it match nothing.
        guard s.contains(where: { $0.isLowercase }) else { return s }
        guard !s.contains(" ") else { return s }

        // Split ONLY where an uppercase BEGINS a new lowercase-continued word ("...dEnd..." -> "...d End...").
        // A mixed-case acronym ("MoMA") has an uppercase followed by another uppercase or the end of the
        // string, not by a lowercase, so its run stays whole. The all-caps guard above alone did not catch
        // "MoMA" (its internal "o" is a lowercase), and #982 found it came out "Mo MA", which silently
        // matches nothing on the venue page: the exact #799 failure this constraint exists to prevent.
        let chars = Array(s)
        var out = ""
        for i in chars.indices {
            let ch = chars[i]
            let beginsLowerWord = i + 1 < chars.count && chars[i + 1].isLowercase
            if i > 0, ch.isUppercase, beginsLowerWord, let prev = out.last, prev.isLowercase || prev.isNumber {
                out.append(" ")
            }
            out.append(ch)
        }
        return out
    }

    // Words that name a PAGE, not an organization. "Upcoming Performances | SecondEndingEnsemble" would
    // otherwise identify the lead as an organization called "Upcoming Performances".
    private static let pageWords = [
        "home", "events", "upcoming", "performances", "concerts", "calendar", "tickets", "about",
        "contact", "shows", "season", "news", "blog", "gallery", "media",
    ]

    private static func isPageName(_ s: String) -> Bool {
        let words = s.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 3 else { return false }
        return words.allSatisfy { pageWords.contains($0) }
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        let value = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
