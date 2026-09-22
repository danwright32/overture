import Foundation

// Name matching for repeat-client detection. Calendar names are messy (presenter + program
// title, often multi-line); these normalize them and decide confident vs merely-possible
// matches. Precision first: only confident matches drive scoring; possibles are flagged for
// review. Used to be kept identical to a TypeScript mirror (groupNameMatch.ts); that mirror was
// retired in #493, so GroupNameDriftTests (fixtures/group-name-match/v1.json) is now this
// logic's only locked spec, not a cross-language drift guard.

enum GroupNameMatch {
    // #3886: every pattern this matcher uses, compiled ONCE and held here.
    //
    // `replacingOccurrences(of:options:.regularExpression)` and `range(of:options:)` take the pattern as a
    // STRING, so each one is parsed and compiled on every single call, and `stripProgramSubtitle` went
    // further and built a fresh `NSRegularExpression` by hand each time. That is invisible at the call
    // site and reads exactly like a constant.
    //
    // It matters here more than almost anywhere else in the app, because normalize() is the innermost
    // thing in the scout's history check: one comparison normalizes both names, and one event is compared
    // against every client and every history record. Measured on the installed Release build on
    // 2026-09-13, all 15 samples inside `HistoryMatch.matchRelationship` ended in `normalize`, 5 of them
    // in `NSRegularExpression` construction; a 1 ms sample of a render pass minutes later put 346 of
    // 19,748 main thread samples in `NSRegularExpression.init`, reached through `ClientHorizon` and
    // `EngagementLink`, both of which come here.
    //
    // ONE DEFINITION PER PATTERN, which is the other half of it: a pattern written at two call sites is
    // two places the same rule can drift apart (L370). Only the patterns unique to name matching live
    // here; the whitespace collapse and the non-alphanumeric strip are shared with every other fold in
    // the app and are defined once, on CompiledPattern.
    private enum Patterns {
        static let presentedByPrefix = CompiledPattern(#"(?i)^\s*presented by\s+"#)
        // The separators are written as ICU escapes rather than as the characters themselves, so this
        // file holds no literal en or em dash for the style gate to catch. `\u2013` and `\u2014` are
        // four-hex-digit ICU escapes, read by the regex engine rather than by Swift: inside a RAW string
        // Swift passes the backslash through untouched, which is what makes this work and what would
        // make the brace form (`\u{2013}`, a Swift escape) arrive at ICU as literal text.
        static let presenterBeforeSubtitle = CompiledPattern(#"^(.*?)(?:\s[-\u2013\u2014]\s|:\s).+$"#)
        static let presentedByLine = CompiledPattern(#"^(?i)presented by\s+"#)
    }
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
        s = Patterns.presentedByPrefix.replacingMatches(in: s, with: "")
        if strippingSubtitle { s = stripProgramSubtitle(s) }
        s = s.lowercased()
        s = CompiledPattern.nonAlphanumericLowercase.replacingMatches(in: s, with: " ")
        s = s.collapsingWhitespaceRuns()
        return s.trimmingCharacters(in: .whitespaces)
    }

    // Drop a trailing program/subtitle after a clear separator (space-dash-space, en/em
    // dash, or colon), keeping the presenter, but only when the presenter is >= 2 words,
    // so a generic one-word prefix (e.g. "Jazz - ...") isn't collapsed. Booking-sheet names
    // are "Presenter - Program"; the venue lists just the presenter, so this lets them match (#105).
    private static func stripProgramSubtitle(_ s: String) -> String {
        guard let captured = Patterns.presenterBeforeSubtitle.firstCaptureGroup(1, in: s) else { return s }
        let presenter = captured.trimmingCharacters(in: .whitespaces)
        return presenter.split(whereSeparator: { $0.isWhitespace }).count >= 2 ? presenter : s
    }

    // Isolate the org/presenter line from a messy, often multi-line history entry. A
    // "Presented by X" line names the org and can sit on any line (program title first or
    // presenter first), so prefer it; otherwise fall back to the first line (#18).
    private static func orgLine(_ name: String) -> String {
        let lines = name.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if let presenter = lines.first(where: { Patterns.presentedByLine.matches($0) }) {
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

    // #3917: one title is the other with a subtitle appended. A SEPARATE predicate, never a loosening
    // of `isConfident`, and it is deliberately not reachable from it.
    //
    // WHY IT CANNOT BE A PARAMETER ON `isConfident`. That function has 25 call sites and the question it
    // answers is "are these the same act" with nothing else established. Its two refusals here are both
    // correct for that question: the `short.count < 2` guard stops a one word title matching anything it
    // is a word of, and the 0.6 containment guard stops a short name matching a larger unrelated one.
    // The loudest caller is repeat client detection, where a wrong match warms a lead off the wrong
    // organisation (#1351). So nothing about `isConfident` moves, and a caller opts in to this instead.
    //
    // WHAT LICENSES IT. Only a caller that has ALREADY established the same folded venue and an
    // overlapping run may ask this, and the reason is measured rather than argued: #3278 found roughly
    // nine pairs at one venue on one night that a title blind rule would have wrongly joined, so the
    // title test is load bearing. With the venue and the run already corroborated, the remaining
    // question is not whether two acts are the same but whether a source has added or dropped a
    // subtitle, which is exactly what `theplayerstheatre-com` did to ten shows in one sweep on
    // 2026-08-09 and what Carnegie's slug rename does one show at a time.
    //
    // A LEADING RUN, never any contiguous one, which is the one place this is STRICTER than
    // `isConfident`. `containsTokenRun` accepts the short name anywhere inside the long one, which is
    // right for a presenter buried in a program line. Here the short side may be a single token, and a
    // title that merely CONTAINS another title is ordinary in a busy room ("Carol" inside "A Christmas
    // Carol the Musical"), so only an appended subtitle counts.
    //
    // Equal titles answer FALSE. They are `isConfident`'s own first branch, and every caller reaches
    // this only after that has said no, so answering true would hide which predicate did the work.
    static func isSubtitleExtension(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a)
        let tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let (short, long) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        guard short.count < long.count else { return false }
        return Array(long[0..<short.count]) == short
    }

    // #4129: the filler conjunctions a billing carries, which say nothing about WHICH act is playing.
    //
    // `&` is not here and needs nothing: `normalize` replaces every non-alphanumeric character with a
    // space, so an ampersand is already gone before any token exists. The HTML entity `&amp;` WOULD
    // arrive as the word "amp", and it is deliberately not listed either: measured on a clone of the
    // live store on 2026-09-22, 86 of 1,333 titles carry `&` and none carries `&amp;`, so listing it
    // would be a rule with no population, and a token nothing writes is indistinguishable from a
    // measurement of zero (L90).
    private static let fillerConjunctions: Set<String> = ["and", "with"]

    private static func droppingFillerConjunctions(_ t: [String]) -> [String] {
        t.filter { !fillerConjunctions.contains($0) }
    }

    // #4129: one title is the other with more names added to its billing, where a conjunction MOVED.
    //
    // THE CASE, measured on the live store 2026-09-21. Carnegie added two guests to one listing and the
    // scout minted a second row beside the one it already held, on the same page, the same night and in
    // the same room:
    //
    //     ... dave eggar AND gregg august
    //     ... dave eggar gregg august makeda hampton AND mak grgic
    //
    // Every arm refused. `isSubtitleExtension` needs the shorter title to be a contiguous LEADING run of
    // the longer one, and the `and` sits inside the stored title where the incoming one carries a name,
    // so the run breaks at the conjunction. Dropping the fillers from BOTH sides first leaves the stored
    // title an exact opening run of the incoming one.
    //
    // A THIRD PREDICATE, not a loosening of `isConfident`, for the reason `isSubtitleExtension` records
    // in full above: that function answers "are these the same act" with nothing else established, it
    // has 25 call sites, and the loudest of them warms a lead off a past client. This is reachable only
    // from `isSameShowTitle`, whose callers each hold a corroborating fact beyond the title (a shared
    // listing or run URL, or that plus the night and the folded room).
    //
    // IT ANSWERS ONLY WHERE A FILLER WAS ACTUALLY DROPPED. Two titles that carry none are
    // `isConfident`'s and `isSubtitleExtension`'s, and both are asked first, so answering them here
    // would hide which predicate did the work, exactly as `isSubtitleExtension` refuses two equal
    // titles for the same reason.
    //
    // AN EQUAL LENGTH RESULT COUNTS, unlike `isSubtitleExtension`, which demands a strictly shorter
    // side. Once the fillers are gone, "Bach and Handel" against "Bach Handel" is the same billing
    // written two ways rather than one plus a subtitle, and refusing it would leave the commonest
    // spelling difference unjoined while accepting the rarer one.
    static func isBillingExtension(_ a: String, _ b: String) -> Bool {
        let rawA = tokens(a)
        let rawB = tokens(b)
        let ta = droppingFillerConjunctions(rawA)
        let tb = droppingFillerConjunctions(rawB)
        // Nothing was dropped, so this pair belongs to the predicates asked before it.
        guard ta != rawA || tb != rawB else { return false }
        // An empty side is a title of nothing but fillers. Every title is trivially a leading run of
        // everything, so it would join whatever shared its listing.
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let (short, long) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        return Array(long[0..<short.count]) == short
    }

    // #3917: the title question asked by a caller that has ALREADY corroborated the pair, and the only
    // way any caller reaches `isSubtitleExtension` or `isBillingExtension` (#4129). One function rather
    // than an `||` repeated at each site, because the four sites have to answer identically and a drift
    // between them would be silent in the direction that withholds a warning or mints a row (L342:
    // shared only where the callers ask the SAME question, and these do).
    //
    // WHO MAY CALL IT. Only a caller holding at least one corroborating fact beyond the title: a shared
    // listing or run URL, a shared production id, or the same folded venue with overlapping nights. That
    // is a rule about call sites and cannot be enforced by a signature, so it is stated here and every
    // site names its own corroboration where it calls.
    //
    // WHO MAY NOT, and this is the part that matters: every caller asking "are these the same act" with
    // nothing else established. Repeat client detection, org do-not-contact, booking match and the rest
    // all keep `isConfident` exactly as it is.
    //
    // THE ORDER IS THE RULE. `isConfident` first, then the subtitle test, then the billing test, and
    // each answers only what the ones before it refused, so a failure names which predicate joined the
    // pair rather than leaving three candidates.
    static func isSameShowTitle(_ a: String, _ b: String) -> Bool {
        isConfident(a, b) || isSubtitleExtension(a, b) || isBillingExtension(a, b)
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

    // #1848: one word differing by ONE SLIP, where a slip includes two adjacent letters SWAPPED. This
    // is the venue lock's predicate and it is deliberately NOT the one above.
    //
    // The live pair is "Jalopy Theatre" against "Jalopy Theater", which is the 'r' and the 'e' the other
    // way round. Plain Levenshtein, which is what `isOneCharacterApart` measures, counts a transposition
    // as TWO edits (delete one letter, insert it back on the other side), so the rule written on it
    // answered no to the only pair the issue was filed about, and the first run of its own fixture is
    // what showed that.
    //
    // WHY THE TITLE RULE IS LEFT ALONE. `isSameNightVariant` was calibrated against the whole live store
    // on 2026-07-30 (the measurement is recorded above it), and widening the distance it allows re-aims
    // that calibration without re-taking it (L220). A room is also a narrower thing than a show title: a
    // season numbers its own concerts one character apart on purpose, and two rooms in one building
    // spelled one TRANSPOSITION apart is not a shape anybody names deliberately. So the tolerance lives
    // here, on the caller that measured the need for it, and `differsByOneTypo` keeps its own distance.
    // `GroupNameMatchTypoBoundaryTests` asserts the two answer differently on exactly that pair.
    //
    // The word-level guards are shared rather than spelled twice: same word count, exactly one word
    // differing, no digits in it, at least four letters (L370).
    static func differsByOneSlipInOneWord(_ a: String, _ b: String) -> Bool {
        exactlyOneWordDiffers(a, b, where: isOneSlipApart)
    }

    private static func differsByOneTypo(_ a: String, _ b: String) -> Bool {
        exactlyOneWordDiffers(a, b, where: isOneCharacterApart)
    }

    // The token half of both rules: same number of words, exactly one of them different. Extracted so
    // the two distances above differ in the DISTANCE and in nothing else.
    private static func exactlyOneWordDiffers(
        _ a: String, _ b: String, where wordsAreCloseEnough: (String, String) -> Bool
    ) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, ta.count == tb.count else { return false }
        let differing = zip(ta, tb).filter { $0 != $1 }
        guard differing.count == 1, let pair = differing.first else { return false }
        return wordsAreCloseEnough(pair.0, pair.1)
    }

    private static func isOneCharacterApart(_ a: String, _ b: String) -> Bool {
        guard wordsAreComparable(a, b) else { return false }
        return editDistance(a, b) <= 1
    }

    // One character apart OR two adjacent characters swapped. See `differsByOneSlipInOneWord` for why
    // only the venue lock asks this.
    private static func isOneSlipApart(_ a: String, _ b: String) -> Bool {
        guard wordsAreComparable(a, b) else { return false }
        return editDistance(a, b) <= 1 || isOneAdjacentSwapApart(a, b)
    }

    // The guards both distances take before they are worth computing: a season's own numbering is one
    // character apart by design, and a four letter floor is what keeps "me" from matching "ye".
    private static func wordsAreComparable(_ a: String, _ b: String) -> Bool {
        guard !a.contains(where: \.isNumber), !b.contains(where: \.isNumber) else { return false }
        return min(a.count, b.count) >= 4 && abs(a.count - b.count) <= 1
    }

    // Two words of the SAME length that differ in exactly two ADJACENT positions holding each other's
    // letters. Written directly rather than as a Damerau variant of `editDistance`, because this is the
    // whole of what it has to answer and the matrix form of it is the part that is easy to get wrong.
    private static func isOneAdjacentSwapApart(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        guard x.count == y.count else { return false }
        let differing = zip(x, y).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        guard differing.count == 2, differing[1] == differing[0] + 1 else { return false }
        let (i, j) = (differing[0], differing[1])
        return x[i] == y[j] && x[j] == y[i]
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
