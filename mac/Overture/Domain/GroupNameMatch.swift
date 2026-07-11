import Foundation

// Name matching for repeat-client detection. Calendar names are messy (presenter + program
// title, often multi-line); these normalize them and decide confident vs merely-possible
// matches. Precision first: only confident matches drive scoring; possibles are flagged for
// review. Used to be kept identical to a TypeScript mirror (groupNameMatch.ts); that mirror was
// retired in #493, so GroupNameDriftTests (fixtures/group-name-match/v1.json) is now this
// logic's only locked spec, not a cross-language drift guard.

enum GroupNameMatch {
    static func normalize(_ name: String) -> String {
        var s = orgLine(name)
        s = s.replacingOccurrences(of: #"(?i)^\s*presented by\s+"#, with: "", options: .regularExpression)
        s = stripProgramSubtitle(s)
        s = s.lowercased()
        s = s.replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // Drop a trailing program/subtitle after a clear separator (space-dash-space, en/em
    // dash, or colon), keeping the presenter, but only when the presenter is >= 2 words,
    // so a generic one-word prefix (e.g. "Jazz - ...") isn't collapsed. Booking-sheet names
    // are "Presenter - Program"; the venue lists just the presenter, so this lets them match (#105).
    private static func stripProgramSubtitle(_ s: String) -> String {
        let pattern = #"^(.*?)(?:\s[-–—]\s|:\s).+$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges >= 2,
              let g1 = Range(m.range(at: 1), in: s) else { return s }
        let presenter = s[g1].trimmingCharacters(in: .whitespaces)
        return presenter.split(whereSeparator: { $0.isWhitespace }).count >= 2 ? presenter : s
    }

    // Isolate the org/presenter line from a messy, often multi-line history entry. A
    // "Presented by X" line names the org and can sit on any line (program title first or
    // presenter first), so prefer it; otherwise fall back to the first line (#18).
    private static func orgLine(_ name: String) -> String {
        let lines = name.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if let presenter = lines.first(where: {
            $0.range(of: #"^(?i)presented by\s+"#, options: .regularExpression) != nil
        }) {
            return presenter
        }
        return lines.first ?? ""
    }

    static func tokens(_ name: String) -> [String] {
        normalize(name).split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    // True when `short` appears as a contiguous run of whole tokens inside `long`.
    private static func containsTokenRun(_ long: [String], _ short: [String]) -> Bool {
        guard short.count <= long.count else { return false }
        var i = 0
        while i + short.count <= long.count {
            if Array(long[i..<i + short.count]) == short { return true }
            i += 1
        }
        return false
    }

    // The fraction guard stops a short name ("New York") confidently matching an
    // unrelated larger one ("New York Theatre Ballet").
    private static let minContainmentFraction = 0.6

    static func isConfident(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a)
        let tb = tokens(b)
        if ta.isEmpty || tb.isEmpty { return false }
        if ta.joined(separator: " ") == tb.joined(separator: " ") { return true }

        let (short, long) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        if short.count < 2 { return false }
        if Double(short.count) / Double(long.count) < minContainmentFraction { return false }
        return containsTokenRun(long, short)
    }

    static func isPossible(_ a: String, _ b: String) -> Bool {
        if isConfident(a, b) { return false }
        let ta = Set(tokens(a))
        let tb = Set(tokens(b))
        if ta.isEmpty || tb.isEmpty { return false }
        let shared = ta.intersection(tb).count
        let union = ta.union(tb).count
        return Double(shared) / Double(union) >= 0.5
    }

    // A trailing word that names a ROLE, not a person (#755). Dan's booking history stores a soloist
    // as "Kento Hong, violin", so without this the strict rule below can never match the person
    // "Kento Hong" to the record that IS him. Found by running the matcher against his real history
    // (see PerformerMatchPrecisionCheckTests): it matched 2 of 13 real past performers, because
    // almost every soloist is filed with their instrument.
    //
    // Deliberately a closed vocabulary rather than "drop the last token": dropping blindly would turn
    // the org "Jane Doe Ensemble" into the person "Jane Doe", which is exactly the false positive the
    // strict rule exists to prevent.
    private static let roleWords: Set<String> = [
        "violin", "viola", "cello", "violoncello", "bass", "contrabass", "doublebass",
        "piano", "fortepiano", "harpsichord", "organ", "guitar", "lute", "harp", "accordion",
        "flute", "piccolo", "recorder", "oboe", "clarinet", "bassoon", "saxophone",
        "trumpet", "horn", "trombone", "tuba", "percussion", "drums", "marimba", "vibraphone",
        "soprano", "mezzo", "alto", "contralto", "tenor", "baritone", "countertenor",
        "voice", "vocals", "vocalist", "conductor", "composer", "narrator", "director", "soloist",
    ]

    // Accents folded to their plain letters before anything else (#755). normalize() below strips
    // everything outside a-z, so "Asunción" would otherwise shred into the junk tokens "asunci" and
    // "n" and could never match itself. In classical music an accented name is not an edge case, it
    // is most of the roster, and this was caught by the real-data precision check: the second soloist
    // of a real recital ("Victor Santiago Asunción, Piano") was the one name in his own history the
    // matcher could not find.
    //
    // A fixed locale, not .current, so the result never depends on Dan's system settings.
    private static func foldAccents(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    // A person's name with accents folded and any trailing role words removed. Never strips below two
    // tokens, so a name can't be eroded into a single word that would then collide with half the world.
    static func personNameTokens(_ name: String) -> [String] {
        var t = tokens(foldAccents(name))
        while t.count > 2, let last = t.last, roleWords.contains(last) { t.removeLast() }
        return t
    }

    // Person names, matched STRICTLY (#749). isConfident above accepts token containment, which is
    // right for orgs ("New York Ballet" really is "New York Theatre Ballet") and wrong for people:
    // it would match the person "Jane Doe" to the org "Jane Doe Ensemble", and warm a lead off a
    // group that merely bears her name. Full token-set equality instead, so every token on both
    // sides has to be accounted for. Order still doesn't matter, so a surname-first program listing
    // ("Vega, Marisol") matches. Deliberately a SEPARATE entry point: the org call sites keep the
    // looser containment rule, unchanged.
    static func isConfidentPersonName(_ a: String, _ b: String) -> Bool {
        let ta = Set(personNameTokens(a))
        let tb = Set(personNameTokens(b))
        if ta.isEmpty || tb.isEmpty { return false }
        return ta == tb
    }

    // Match a performer against a messy, multi-LINE booking-history entry (#755). normalize() picks a
    // single org line out of such an entry, which is right for org matching and wrong here: Dan files
    // a two-soloist recital as one entry with a performer per line, so the second soloist sits on a
    // line the org path never even looks at. Every line is its own candidate person name.
    //
    // Still full token-set equality per line, which is what keeps the precision: an org merely NAMED
    // AFTER someone ("Abby Whiteside Foundation") has a leftover token and so is not that person.
    static func isConfidentPersonName(_ performer: String, inEntry entry: String) -> Bool {
        let target = Set(personNameTokens(performer))
        guard !target.isEmpty else { return false }
        return entry
            .split(separator: "\n")
            .contains { Set(personNameTokens(String($0))) == target }
    }
}
