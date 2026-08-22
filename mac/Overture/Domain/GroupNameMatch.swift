import Foundation

// Name matching for repeat-client detection. Calendar names are messy (presenter + program
// title, often multi-line); these normalize them and decide confident vs merely-possible
// matches. Precision first: only confident matches drive scoring; possibles are flagged for
// review. Used to be kept identical to a TypeScript mirror (groupNameMatch.ts); that mirror was
// retired in #493, so GroupNameDriftTests (fixtures/group-name-match/v1.json) is now this
// logic's only locked spec, not a cross-language drift guard.

enum GroupNameMatch {
    // Accents fold to their plain letters before anything else (#774). The strip below removes
    // everything outside a-z, so without this "Sinfónica" shreds into the junk tokens "sinf" and
    // "nica" and can never match itself, and an org with an accent in its name silently reads as a
    // cold lead. #755 fixed this for people only; orgs had the same bug.
    //
    // Folding touches combining marks, not punctuation, so the em/en dash separators stripProgramSubtitle
    // relies on survive it untouched (the locked fixture proves this: its one non-ASCII case is an em dash).
    //
    // A fixed locale, not .current, so the result never depends on Dan's system settings.
    private static func foldAccents(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func normalize(_ name: String) -> String {
        normalize(name, strippingSubtitle: true)
    }

    // #1693: the same normalization with the subtitle strip made optional, so the fuzzy gate can read a
    // name WHOLE. Everything else (the org line, "presented by", accents, punctuation, whitespace) is
    // shared, because those are all canonicalization and none of them can lose an identity.
    private static func normalize(_ name: String, strippingSubtitle: Bool) -> String {
        var s = orgLine(foldAccents(name))
        s = s.replacingOccurrences(of: #"(?i)^\s*presented by\s+"#, with: "", options: .regularExpression)
        if strippingSubtitle { s = stripProgramSubtitle(s) }
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

    // #1693: every token in the name, including any the subtitle strip would drop. Used by the fuzzy
    // gate alone; see isPossible for why.
    private static func wholeNameTokens(_ name: String) -> [String] {
        normalize(name, strippingSubtitle: false)
            .split(separator: " ").map(String.init).filter { !$0.isEmpty }
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
    static let minContainmentFraction = 0.6

    // #1590 follow-up: the value the SAME-NIGHT dedupe uses instead, and nothing else. Being the same
    // night at the same venue is already strong evidence that a bare title comparison does not have, so
    // the title test there can afford to be looser than the one deciding whether a show belongs to a
    // past client, where a loose match warms a lead off the wrong organisation.
    //
    // LIVE-STORE-CLAIM verified=2026-07-28 measure="extra same-night groups merged at each containment threshold, over untriaged dated shows"
    // 0.40 is measured, not picked: over all 558 untriaged dated shows on 2026-07-28 it merges exactly
    // two more groups than 0.60, and NOTHING is gained below it (0.34, 0.30 and 0.25 all find the same
    // two), so this is where the curve goes flat. Both are real, and one is Dan's own headline example
    // from #1590: the third Jalopy open mic card, which survived the first run because its seven word
    // parenthetical aside left only five shared words out of twelve.
    static let sameNightContainmentFraction = 0.40

    // A single-token acronym is a confident match for a multi-token name when its letters ARE that
    // name's word-initials, one letter per word, in order (#1351). "nyys" <-> New York Youth Symphony.
    // Kept deliberately tight so it can never loosen the >= 2 token guard below into a false client
    // match, the risk #1351 flagged:
    //   - the acronym's length must EQUAL the word count, so a stray short token can't match a longer
    //     name on a prefix of its initials ("nyc" is not "New York City Ballet"), and
    //   - it must be >= 2 letters, since a single letter would collide with almost anything.
    // A leading-word abbreviation (TENET for "TENET Vocal Artists") is NOT an acronym of the name and
    // is intentionally excluded: its length (5) never equals the word count (3).
    private static func isAcronymMatch(_ a: [String], _ b: [String]) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard short.count == 1, long.count >= 2 else { return false }
        let acronym = short[0]
        guard acronym.count >= 2, acronym.count == long.count else { return false }
        let initials = String(long.compactMap { $0.first })
        return acronym == initials
    }

    // #1590 follow-up: `minimumContainment` defaults to the strict shared value, so every existing call
    // site (repeat-client detection above all) is untouched. Only the same-night dedupe passes a looser
    // one, and it passes it explicitly so the loosening is visible at the call site rather than hidden
    // in a default that quietly governs client matching too.
    static func isConfident(_ a: String, _ b: String,
                            minimumContainment: Double = minContainmentFraction) -> Bool {
        let ta = tokens(a)
        let tb = tokens(b)
        if ta.isEmpty || tb.isEmpty { return false }
        if ta.joined(separator: " ") == tb.joined(separator: " ") { return true }
        if isAcronymMatch(ta, tb) { return true }

        let (short, long) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        if short.count < 2 { return false }
        if Double(short.count) / Double(long.count) < minimumContainment { return false }
        return containsTokenRun(long, short)
    }

    // #1764: the same-night dedupe's own entry point, and the ONLY caller allowed to tolerate a
    // misspelling. Since #1761 dropped the room from the merge, the title is the sole guard against a
    // wrong merge, so this is written to be as narrow as the live evidence demands and no wider.
    //
    // The live case: one source spells its own show "The Golden Hour Series at Greely Square: Vaden
    // Landers" on two days and "Greeley Square" on a third. One letter, inside the title, so the
    // containment rule refuses them and the night reads as two cards.
    //
    // LIVE-STORE-CLAIM verified=2026-07-30 measure="same-night groups and duplicate rows before and after allowing a one-character typo in a single word of the title"
    // Measured over all 742 dated rows before it was written: the group count does not move (26), rows
    // removed goes from 32 to 34, and exactly two groups change, both Golden Hour nights absorbing the
    // copy that spells Greeley correctly. NO new group appears anywhere in the store.
    //
    // Every condition below is load-bearing, because a season's own numbering is one character apart by
    // design ("Symphony No 5" against "No 6", "Part I" against "Part II") and those are different
    // concerts:
    //   - the two titles must hold the SAME NUMBER of words, so nothing is gained or lost,
    //   - exactly ONE word may differ, since a typo is one slip and not two,
    //   - that word may not be a number,
    //   - it must be at least four letters, which is what keeps "me" from matching "ye",
    //   - and it must be one character from its twin.
    static func isSameNightVariant(_ a: String, _ b: String) -> Bool {
        if isConfident(a, b, minimumContainment: sameNightContainmentFraction) { return true }
        return differsByOneTypo(a, b)
    }

    private static func differsByOneTypo(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, ta.count == tb.count else { return false }
        let differing = zip(ta, tb).filter { $0 != $1 }
        guard differing.count == 1, let pair = differing.first else { return false }
        return isOneCharacterApart(pair.0, pair.1)
    }

    private static func isOneCharacterApart(_ a: String, _ b: String) -> Bool {
        guard !a.contains(where: \.isNumber), !b.contains(where: \.isNumber) else { return false }
        guard min(a.count, b.count) >= 4, abs(a.count - b.count) <= 1 else { return false }
        return editDistance(a, b) <= 1
    }

    // Levenshtein, two rows at a time. Only ever called on two short words that already passed the
    // length and digit guards above.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i]
            for j in 1...y.count {
                cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)))
            }
            prev = cur
        }
        return prev[y.count]
    }

    // #1693: the fuzzy gate scores the WHOLE name, unlike isConfident above, which keeps the subtitle
    // strip. The two want opposite things from that strip and it took 18 wrong flags to see it.
    //
    // isConfident needs it: a booking-sheet name is "Presenter - Program", the venue lists just the
    // presenter, and dropping the program is what lets them match (#105). Nothing is lost, because the
    // presenter that survives IS the identity being matched.
    //
    // Here it is the opposite. A scraped listing is often shaped "Series: Act", where the suffix is
    // the specific half, so stripping deletes the only part that says who is playing and leaves a
    // series or venue brand to score on. That brand is shared by every show in the building, so ONE
    // record reaches every card: "Carnegie Hall Citywide: Ivalas Quartet" stripped to "carnegie hall
    // citywide" is 2 shared tokens of 4 against the presenter "Carnegie Hall Presents", landing exactly
    // on the gate below, and it flagged all 18 Carnegie Hall shows in the live store against an act Dan
    // has never worked with. Whole, it is 2 of 6 and does not fire.
    //
    // The strip cannot tell those two shapes apart (it is one regex over free text, and both are
    // "words, separator, words"), so the fix is not a smarter strip: it is that a gate this loose must
    // never score a name with a piece missing. Reading whole is also strictly the more conservative
    // direction here, since the extra tokens can only grow the union.
    static func isPossible(_ a: String, _ b: String) -> Bool {
        if isConfident(a, b) { return false }
        let ta = Set(wholeNameTokens(a))
        let tb = Set(wholeNameTokens(b))
        if ta.isEmpty || tb.isEmpty { return false }
        let shared = ta.intersection(tb).count
        let union = ta.union(tb).count
        return Double(shared) / Double(union) >= 0.5
    }

    // A trailing word that names a ROLE, not a person (#755). Dan's booking history stores a soloist
    // as "Toma Reyes, violin", so without this the strict rule below can never match the person
    // "Toma Reyes" to the record that IS him. Found by running the matcher against his real history
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

    // A person's name with any trailing role words removed. Never strips below two tokens, so a name
    // can't be eroded into a single word that would then collide with half the world. Accent folding
    // is normalize()'s job now (#774): it used to be duplicated here, back when only the person path
    // needed it.
    static func personNameTokens(_ name: String) -> [String] {
        var t = tokens(name)
        while t.count > 2, let last = t.last, roleWords.contains(last) { t.removeLast() }
        return t
    }

    // Person names, matched STRICTLY (#749). isConfident above accepts token containment, which is
    // right for orgs ("New York Ballet" really is "New York Theatre Ballet") and wrong for people:
    // it would match the person "Jane Doe" to the org "Jane Doe Ensemble", and warm a lead off a
    // group that merely bears her name. Full token-set equality instead, so every token on both
    // sides has to be accounted for. Order still doesn't matter, so a surname-first program listing
    // ("Sable, Larkin") matches. Deliberately a SEPARATE entry point: the org call sites keep the
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
