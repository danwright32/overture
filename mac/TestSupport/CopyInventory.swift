import Foundation

// #915: every sentence Overture can say to Dan, in one list.
//
// The list is the point. #843 (copy that says the same thing twice) and #844 (read every new sentence
// cold before it ships) are both unworkable without one, for the same reason: you cannot compare
// wordings you cannot see side by side. The first duplicate was already known before this existed, the
// Queue and the Archive both saying "Nothing scouted yet", and it took a person happening to notice.
//
// Swift cannot reflect over a string literal sitting inside a function, so this reads the source. Which
// means it needs a rule for what counts as a sentence, and the rule has one bias, stated here because it
// decides every borderline case: WHEN IN DOUBT, INCLUDE IT. A string wrongly included is one line of
// noise in a list. A string wrongly excluded is invisible, and invisible is the exact failure #844 is
// about.
enum CopyInventory {

    // MARK: - What counts as a sentence

    static func isCopy(_ literal: SwiftSource.Literal) -> Bool {
        // A raw string in this codebase is a regex, every time: DraftCheck's lint patterns,
        // EventClassifier's discipline matchers, GroupNameMatch's normalizers. Dropping them on what the
        // string IS beats sniffing for backslashes and pipes and hoping.
        guard !literal.isRaw else { return false }

        // #2124: interpolations are stood in for, not deleted. A value the sentence LEADS with is still
        // one of its words, and dropping it puts "\(address), replied" at one word, under the floor
        // below. That silently excluded a whole category (anything phrased as "<value>, something"),
        // which screen reader labels skew heavily towards because they name the value first.
        let bare = withInterpolationsAsWords(literal.text)
        guard bare.contains(" ") else { return false }

        // Two real words. This is the whole filter, and it earns its keep: a symbol name
        // ("checkmark.seal.fill"), a defaults key, an enum rawValue and an identifier are all ONE token,
        // and a sentence almost never is.
        //
        // The cost, stated out loud rather than discovered later: a one-word label, Text("Sources"), is
        // out too. At this altitude a single word cannot be told apart from an identifier, and letting
        // those in would bury the sentences under thousands of tokens nobody would read.
        let words = bare.split { !$0.isLetter }.filter { $0.count >= 2 }
        guard words.count >= 2 else { return false }

        guard !isMarkup(bare), !isAddress(bare), !isAlternation(bare) else { return false }
        return true
    }

    // #2578: a pipe-separated list of short phrases is a search pattern, never a sentence Overture says.
    // `DraftGreeting`'s "hi|hello|hey|dear|good morning|..." is the measured instance: it was listed as
    // copy, and silenced with a marker, which is the wrong direction of defence because a marker is
    // opt-in and the next one nobody remembers stays in.
    //
    // Narrow deliberately, and the narrowness is measured rather than hoped for: 0 of the 1358 entries in
    // the checked-in inventory contain a pipe at all (2026-08-15), so this can cost no sentence that
    // exists, and `CopyInventoryAlternationTests` re-measures that over the whole list every run rather
    // than trusting the number here to stay true (L104: test the filter against what it must PRESERVE).
    //
    // Three parts, not two, because "Sent | not sent" style copy is imaginable and two halves are not yet
    // a pattern. Each part short and free of sentence punctuation, so a real sentence that happens to
    // contain a pipe is not swept up with it.
    private static func isAlternation(_ text: String) -> Bool {
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.split(separator: " ").count <= 3 else { return false }
            return !trimmed.contains(".") && !trimmed.contains(",") && !trimmed.contains("!")
                && !trimmed.contains("?") && !trimmed.contains(":")
        }
    }

    private static func isMarkup(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("<") || trimmed.contains("</")
    }

    // A URL, a file path, or the scraper's User-Agent. All prose-shaped, none of them a sentence: what
    // gives them away is a slash inside a word, which ordinary copy does not have.
    private static func isAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("http") || trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return true }
        guard let first = trimmed.split(separator: " ").first else { return false }
        return first.contains("/") && !first.hasSuffix("/")   // "Mozilla/5.0 (Macintosh; ...)"
    }

    // Strips `\(...)` with balanced parens, so what's left is the WORDS the sentence contributes of its
    // own. Balanced, not a lazy regex: an interpolation can hold a call with its own parens
    // ("\(DueWork.counts(prospects: p).total)"), and stopping at the first `)` leaves ".total)" behind,
    // which looks exactly like words and would be indistinguishable from a real finding.
    static func withoutInterpolations(_ literal: String) -> String {
        strippingInterpolations(literal, replacement: "")
    }

    // The same strip, but each `\(...)` becomes a single placeholder word rather than nothing (#2124).
    // Used for the "two real words" test only: the inventory still LISTS the literal as written, so
    // `\(address), replied` appears in docs/copy-inventory.md with its interpolation intact, the way
    // every other interpolated sentence already does.
    //
    // The placeholder is a bare run of letters on purpose, so it counts as exactly one word and nothing
    // downstream mistakes it for punctuation or an address.
    static func withInterpolationsAsWords(_ literal: String) -> String {
        strippingInterpolations(literal, replacement: "value")
    }

    private static func strippingInterpolations(_ literal: String, replacement: String) -> String {
        var out = ""
        var depth = 0
        var index = literal.startIndex
        while index < literal.endIndex {
            if depth == 0, literal[index] == "\\",
               literal.index(after: index) < literal.endIndex,
               literal[literal.index(after: index)] == "(" {
                depth = 1
                out += replacement
                index = literal.index(index, offsetBy: 2)
                continue
            }
            if depth > 0 {
                if literal[index] == "(" { depth += 1 }
                if literal[index] == ")" { depth -= 1 }
                index = literal.index(after: index)
                continue
            }
            out.append(literal[index])
            index = literal.index(after: index)
        }
        // The escapes a sentence carries are punctuation, not words: \n is a paragraph break, \" a quote.
        return out
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    // MARK: - The inventory

    struct Exclusion: Equatable { var file: String; var reason: String }
    struct Duplicate: Equatable { var sentence: String; var files: [String] }

    struct Inventory {
        var occurrences: [String: [String]] = [:]   // sentence -> the file(s) it is written in, with repeats
        var exclusions: [Exclusion] = []
        var filesScanned = 0

        var sentences: [String] { occurrences.keys.sorted() }

        func sources(of sentence: String) -> [String] {
            Array(Set(occurrences[sentence] ?? [])).sorted()
        }

        // #3155: the entries that are still only PART of what Dan reads, because a value is interpolated
        // into them and no static reading can supply it. Named rather than left in the list looking whole:
        // the cold read is asked whether a sentence tells Dan anything the line beside it did not, and
        // that question cannot be answered about a line with a hole in it. `+` concatenation is joined
        // before this (see `composed`), so what remains here is only the genuinely unresolvable half.
        var carryingAValue: [String] {
            occurrences.keys.filter { $0.contains("\\(") }.sorted()
        }

        // The same sentence written in more than one place. #843's raw material, and the reason the list
        // leads with this rather than burying it: a duplicate is the one thing here that is always worth
        // a second look, because the two copies WILL drift.
        var duplicates: [Duplicate] {
            occurrences
                .filter { $0.value.count > 1 }
                .map { Duplicate(sentence: $0.key, files: $0.value.sorted()) }
                .sorted { $0.sentence < $1.sentence }
        }
    }

    // `floor` is what the walk refuses below (#2311). It defaults to the real app's floor and is
    // lowered only by the fixture tests, which deliberately build a two-file tree: refusing there
    // would be refusing the test's own setup rather than catching a broken path.
    // #3235: the DEFAULT build is paid for once per process. It was being made twelve times a run at
    // about 5.9s each, roughly 70s of a 507s suite, and every one of those twelve produced the same
    // document from the same unchanged tree.
    //
    // Only the default root and floor are kept. A caller that INJECTS a root is the test OF this
    // builder, and handing it a remembered answer about a different tree would make those tests assert
    // nothing. And a scan that read NO files is never kept: an empty inventory reads downstream as "the
    // app says nothing", which is exactly what a broken path produces, so keeping it would let one bad
    // path pass every copy guard in the suite at once (L286, L98). `theScanIsStillProvenToHaveRun` and
    // the `filesScanned` floors are what would catch that, and they still run against this.
    private static let defaultMemo = BuildMemo<Inventory>()

    static var buildsPerformed: Int { defaultMemo.buildsPerformed }

    static func build(root: URL = appRoot, floor: Int = 50) throws -> Inventory {
        guard root == appRoot, floor == 50 else { return try buildUncached(root: root, floor: floor) }
        return try defaultMemo.value(keepIf: { $0.filesScanned > 0 }) {
            try buildUncached(root: appRoot, floor: 50)
        }
    }

    private static func buildUncached(root: URL, floor: Int) throws -> Inventory {
        var inventory = Inventory()
        let files = try swiftFiles(under: root, floor: floor)
        inventory.filesScanned = files.count

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let name = relativePath(of: file, under: root)

            // #2671 first, because nesting leaves the counts BALANCED: the unclosed check below cannot
            // see it, and reporting it as "unclosed" would send the reader looking for a missing marker
            // that is not missing (L11).
            if let line = SwiftSource.nestedIgnoreRegion(in: source) {
                throw Failure.nestedIgnoreRegion(name, line)
            }
            if SwiftSource.unclosedIgnoreRegion(in: source) {
                throw Failure.unclosedIgnoreRegion(name)
            }
            for reason in SwiftSource.ignoredReasons(in: source) {
                inventory.exclusions.append(Exclusion(file: name, reason: reason))
            }
            for literal in composed(SwiftSource.literals(in: source)) where isCopy(literal) {
                inventory.occurrences[literal.text, default: []].append(name)
            }
        }
        return inventory
    }

    // #3155: a sentence written as `"first half " + "second half"` is ONE sentence in the running app,
    // and until this it reached the inventory as two.
    //
    // That matters because the cold read is the only thing catching the #840/#843 class, and it cannot
    // catch what it cannot see. Hit twice in one session, 2026-08-23: `GmailReconnectCopy` (#2967)
    // composed both reconnect sentences from a shared fragment and `AppNotices.responsesNotUnderstood`
    // (#2888) did the same, and both landed here as pieces while the sentence Dan reads appeared nowhere.
    //
    // Joined BEFORE `isCopy` is asked, deliberately and not as an ordering accident. `isCopy` refuses a
    // one-word literal, because at this altitude one word cannot be told from an SF Symbol or a defaults
    // key; two one-word halves of a real sentence are exactly that shape, so asking first would drop the
    // sentence and then have nothing left to join.
    //
    // What it still cannot do is resolve a value: `"\(cause), so nothing was sent"` has no second
    // literal to join, and no static reading can supply the words. Those are NAMED instead, in the
    // rendered document's own section, rather than sitting in the list looking like whole sentences.
    static func composed(_ literals: [SwiftSource.Literal]) -> [SwiftSource.Literal] {
        var out: [SwiftSource.Literal] = []
        for literal in literals {
            if literal.joinedToPrevious, var previous = out.last {
                previous.text += literal.text
                // Raw is carried by the GROUP: a raw literal anywhere in it means the whole thing is a
                // regex rather than a sentence, and `isCopy` refuses it for that reason.
                previous.isRaw = previous.isRaw || literal.isRaw
                out[out.count - 1] = previous
            } else {
                out.append(literal)
            }
        }
        return out
    }

    enum Failure: Error, CustomStringConvertible {
        case unclosedIgnoreRegion(String)
        case nestedIgnoreRegion(String, Int)
        var description: String {
            switch self {
            case .unclosedIgnoreRegion(let file):
                return "\(file) opens a \(SwiftSource.ignoreStart) it never closes, which would hide "
                     + "every sentence after it from the inventory."
            case .nestedIgnoreRegion(let file, let line):
                return "\(file) line \(line) opens a \(SwiftSource.ignoreStart) inside a region that is "
                     + "already open. The inner region's \(SwiftSource.ignoreEnd) closes the outer one "
                     + "too, so every sentence between there and the outer end leaks into the inventory. "
                     + "Widen the outer region, or close it before opening the inner one."
            }
        }
    }

    // #2311: through the shared walk, which refuses out loud when it comes back short. An inventory
    // built from no files is an empty list of everything the app says, which is what #1967 shipped.
    private static func swiftFiles(under root: URL, floor: Int) throws -> [URL] {
        AppSourceWalk.urls(under: root, floor: floor)
    }

    // Internal (not private) so the #1491 regression test can pin it directly. Both paths are
    // canonicalized first: resolvingSymlinksInPath collapses /var vs /private/var, and a symlinked root
    // vs a real file path, into one form, so the strip is an ANCHORED prefix removal rather than the old
    // unanchored replacingOccurrences that fused a leading /private onto the first component.
    static func relativePath(of file: URL, under root: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let filePath = file.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(prefix) else { return filePath }
        return String(filePath.dropFirst(prefix.count))
    }

    // MARK: - The checked-in file, and who is allowed to rewrite it (#1994)

    // What a run should do about the file on disk. Pure, so the decision can be exercised without a
    // real stale inventory and, more to the point, without writing anything anywhere.
    enum CheckedInOutcome: Equatable {
        case upToDate
        case regenerated(contents: String, message: String)
        case stale(message: String)
    }

    static let regenerationVariable = "REGENERATE_COPY_INVENTORY"

    // xcodebuild does NOT hand its own environment to the test process. It forwards only variables
    // prefixed `TEST_RUNNER_`, with the prefix stripped. Measured 2026-08-08 against a real run: the
    // bare name reached nothing and the file was left stale with the request silently ignored, while
    // the prefixed name arrived and regenerated it. Both spellings are accepted so the opt-in works
    // whether the suite is driven through xcodebuild or a test binary is run directly, and the
    // message below quotes the one that actually works from a terminal.
    static let forwardedRegenerationVariable = "TEST_RUNNER_REGENERATE_COPY_INVENTORY"

    // The command that reaches the test process, quoted in the failure message so nobody has to
    // rediscover the prefix.
    static let regenerationCommand =
        "TEST_RUNNER_REGENERATE_COPY_INVENTORY=1 mac/scripts/run-tests-locked.sh"

    // Whether this run was ASKED to rewrite the file. Only an affirmative value counts: an unset or
    // empty variable must never read as yes, because that is exactly the state every ordinary run is
    // in and the whole point is that an ordinary run changes nothing.
    static func regenerationRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        for name in [forwardedRegenerationVariable, regenerationVariable] {
            switch environment[name]?.lowercased() {
            case "1", "true", "yes": return true
            default: continue
            }
        }
        return false
    }

    // The rule, and the reason it is a rule.
    //
    // Regenerating in place is useful when the difference IS a real copy change. The hazard is a run
    // that was never meant to edit the repo. It happened twice on 2026-08-02 while working #1967: the
    // app was deliberately broken with a `fatalError("...")` to prove the unhosted suite survives a
    // launch fault, that string counted as app copy, and the file was rewritten to include it. It then
    // sat modified in the working tree looking exactly like an ordinary edit, and a `git add -A` would
    // have shipped a claim about what the app says to Dan that no human wrote and no reviewer would
    // question. It was caught only because somebody happened to be watching for it.
    //
    // The write also used to happen on a run that FAILED, so an aborted or experimental run left the
    // repo dirty with no obvious cause.
    //
    // So a stale file is REPORTED by default and rewritten only on request. Reporting still names what
    // moved, because "the inventory is stale" alone leaves the reader unable to tell their own copy
    // change from an accident of the run, which is the distinction that matters here.
    // #2650: `documentPath` names the file in every sentence below, defaulted so no existing caller
    // changes. There are two generated copy documents now, the app's own voice and what it sends out,
    // and a message naming the wrong one sends the reader to `git diff` a file that did not move.
    static func checkCheckedIn(existing: String, generated: String,
                               regenerate: Bool,
                               documentPath: String = "docs/copy-inventory.md") -> CheckedInOutcome {
        guard existing != generated else { return .upToDate }

        if regenerate {
            return .regenerated(contents: generated, message: """
                \(documentPath) was out of date and has been regenerated, because this run \
                asked for it.

                Read the diff (`git diff \(documentPath)`): it is every sentence this branch \
                adds, removes or rewords, in the words a person will actually read. If it says what you \
                meant it to say, commit it.
                """)
        }

        return .stale(message: """
            \(documentPath) is out of date. NOTHING has been written: a run that was not asked \
            to change the repo does not change it.

            \(differenceReport(existing: existing, generated: generated))

            If that is a copy change you meant to make, regenerate the file and commit it:

                \(regenerationCommand)

            If it is not, something this run did produced it, and the file on disk is the correct one.
            """)
    }

    // The lines that moved, both directions, bounded. Bounded is not tidiness: the inventory runs to
    // over a thousand lines and a single rename near the top shifts every line after it, so an
    // untruncated dump would bury the one line somebody needs to see.
    static func differenceReport(existing: String, generated: String, limit: Int = 12) -> String {
        let before = Set(existing.components(separatedBy: "\n"))
        let after = Set(generated.components(separatedBy: "\n"))

        let added = after.subtracting(before).sorted()
        let removed = before.subtracting(after).sorted()

        var out: [String] = []
        out.append(contentsOf: section("Added", added, limit: limit))
        out.append(contentsOf: section("Removed", removed, limit: limit))
        return out.isEmpty ? "The two differ only in whitespace or line order." : out.joined(separator: "\n")
    }

    private static func section(_ title: String, _ lines: [String], limit: Int) -> [String] {
        let meaningful = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !meaningful.isEmpty else { return [] }
        var out = ["\(title) (\(meaningful.count)):"]
        out.append(contentsOf: meaningful.prefix(limit).map { "  \($0)" })
        if meaningful.count > limit {
            out.append("  ... and \(meaningful.count - limit) more")
        }
        return out
    }

    // MARK: - Where things live

    static var appRoot: URL {
        repoRoot.appendingPathComponent("mac/Overture")
    }

    static var inventoryURL: URL {
        repoRoot.appendingPathComponent("docs/copy-inventory.md")
    }

    // #1993: through the shared RepoRoot search. This is where the search was FIRST written, after
    // #1967 moved this file one directory shallower and its four-level climb silently landed outside
    // the repo, so eleven tests reported the app had no copy in it rather than saying the path was
    // wrong. It now lives in one place that every test uses, instead of one place that only this file
    // did, which is what #1993 is about.
    private static var repoRoot: URL { RepoRoot.url }
}

// MARK: - Rendering

extension CopyInventory.Inventory {

    // Sorted by SENTENCE, and deliberately without line numbers.
    //
    // Both choices serve the same end: the diff. A file-ordered list reshuffles every time a line moves,
    // and line numbers churn on edits that change no words at all, so the one thing a reviewer wants to
    // see (which sentences did this PR add, remove or reword) would be buried in noise. Sorted by the
    // words themselves, a new sentence is one added line, and near-identical wordings land next to each
    // other, which is how a duplicate gets noticed.
    // #2349: the header states the SENTENCE count and no longer the file count.
    //
    // A scanned-file count moves whenever any Swift file is added anywhere in the app, including one
    // carrying no copy at all, so two branches open at once each recorded their own and the second went
    // red on main purely because the number had drifted underneath it. Measured three times in one
    // session on 2026-08-10 (402 to 404 to 406 to 407), each costing a full suite rerun, and each red
    // reading as a copy change when no sentence had moved.
    //
    // Dropping it from the FILE loses nothing: `filesScanned` still exists on this value and is still
    // asserted (CopyInventoryTests, ProducerCorrectionControlTests), so the guard against a scan that
    // walked nothing is the test, never the printed number. What remains in the header is the sentence
    // count, which moves exactly when the copy does, so a red here is always a real copy change.
    func render() -> String {
        var out = """
        # Copy inventory

        Every sentence Overture can say to Dan: **\(occurrences.count) sentences**.

        Generated, do not edit by hand. The test suite regenerates it (`mac/scripts/run-tests-locked.sh`)
        and fails if it is stale, so a PR that changes what the app says shows the change here, in the
        words Dan will read rather than as a line of Swift.

        What is in it: a string literal carrying two or more words, from anywhere in `mac/Overture`.
        What is not, and why:

        - **One-word labels** (`Text("Sources")`). At this altitude a single word cannot be told apart
          from an SF Symbol, a defaults key or an identifier, and letting those in would bury the
          sentences under tokens nobody reads.
        - **Nothing, if it is written as two literals joined with `+`.** Those ARE joined here, into the
          one sentence the running app says (#3155). What is still only part of what Dan reads is a
          sentence carrying a VALUE: \(carryingAValue.count) of the \(occurrences.count) below hold a
          `\\(...)` where a number or a name goes, so what is printed is the template. They are counted
          here rather than listed again, because the hole is visible in the line itself; what was missing
          was any statement of how much of this document is templates.
        - **DEBUG-only copy**, which is compiled out of the app Dan runs.
        - **Marked regions**, listed below with the reason, at the source.

        """

        if !exclusions.isEmpty {
            out += "\n## Excluded at the source\n\n"
            for exclusion in exclusions.sorted(by: { $0.file < $1.file }) {
                out += "- `\(exclusion.file)`: \(exclusion.reason)\n"
            }
        }

        let duplicates = self.duplicates
        out += "\n## The same sentence, said in more than one place (\(duplicates.count))\n\n"
        out += duplicates.isEmpty ? "None.\n" : "Two copies of a sentence will drift. #843 owns fixing these.\n\n"
        for duplicate in duplicates {
            out += "- \(quoted(duplicate.sentence))\n"
            for file in duplicate.files { out += "  - `\(file)`\n" }
        }

        out += "\n## Every sentence\n\n"
        for sentence in sentences {
            out += "\(quoted(sentence))\n"
            for file in sources(of: sentence) { out += "    `\(file)`\n" }
        }
        return out
    }

    // A multi-line literal is rendered on one line so the list stays scannable and its diffs stay small.
    private func quoted(_ sentence: String) -> String {
        "\"" + sentence.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
