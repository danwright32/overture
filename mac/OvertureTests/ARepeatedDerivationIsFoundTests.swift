import Testing
import Foundation

// #3852: a computed property whose body reaches the filesystem or sweeps the store reads as a free field
// access at the call site, so one question costs one derivation PER REFERENCE.
//
// THE RECORD SO FAR, all of it found by somebody happening to read the file rather than by any check:
//
//   #3646  QueueView.checkRunning      read once per card and once per date heading
//   #3837  RootView.prepToolbarLabel   three marker reads where one reading answers all of it
//   #3837  RootView.prepRefusal        read FOUR times in one toolbar menu, one marker read each
//   #3814  OrganisationsView.nearMisses  read three times, each two whole-store walks plus an O(n squared) scan
//   #3814  OutcomePatternsView.rows      read twice, each a whole-store tally
//   #3814  StruckAddressesView.entries   read twice, each a whole-store map
//
// `prepRefusal` is the clearest: its own docstring said "this reads it twice" while the code read it four
// times, so even the comment beside it had fallen behind. This is the scan that finds the seventh.
//
// WHY IT MATTERS BEYOND THE MILLISECONDS. This is the shape that hid a 69 ms call on the Sources sheet
// for days (#3829, #3645): something that looks like a field access at the call site and is a derivation
// underneath (L383).
//
// ## The two things #3852 said to settle in the same change rather than after it
//
// **1. Is the rule "read once" or "read once per BODY EVALUATION".** It is the second, and it has to be:
// a property read once in `body` and once inside a `.sheet` content closure is two DRAWS, not two reads,
// and a rule that counted it as two would demand a change that saves nothing. This scan reads text and
// cannot tell those apart, so where it cannot, the case is EXEMPTED WITH ITS REASON rather than the walk
// being narrowed: a walk taught to skip closures would also skip the derivations that legitimately live
// in one (L362, and #3829 settled the same question the same way). `RootView.allRows` below is exactly
// that case and says so.
//
// **2. What the fix is meant to be**, because #3646 and #3837 did two different things and a message that
// named the wrong one would send the repair to the wrong layer. The rule, and the failure message states
// it: if the file HAS a render pass, the value belongs in the pass, where a test can count what it costs
// (what #3646 did). If it does not, bind it once at the call site (what #3837 did). Pushing a value into
// a pass that does not exist is a bigger change than the finding warrants, and binding locally inside a
// view that already has a pass puts a derivation somewhere the pass's own cost test cannot see it.
//
// ## What this scan CANNOT see, carried forward from #3829
//
// It reads text. It cannot see a cost inside a type it only names, it cannot count how many times SwiftUI
// evaluates a body, and a reference it finds in a closure may or may not run this draw. It answers one
// question: does one name that costs something appear more than once where a draw can reach it.
//
// The RUNTIME half is stronger where it applies and already exists: the counter #3646 put inside
// `DetachedRunner.heartbeat` counts every marker read in the app, and
// `MarkerReadsDoNotScaleWithTheQueueTests` drives a real draw and counts reads per pass. That covers the
// marker half on the surfaces it drives. This covers every view file, including the ones no hosted test
// brings up, which is where the next one will be.
@Suite("Nothing reads a costly derivation twice in one draw (#3852)")
struct ARepeatedDerivationIsFoundTests {

    // Reaching one of these is a FILESYSTEM read. Every one of them is a real reader in this app, named
    // from the three instances above rather than invented: the marker URLs are computed properties on
    // purpose (#1613, so Foundation's resource cache can never answer a stale "the marker is still
    // there"), which means every one of these really does reach the disk.
    static let filesystemReaders = ["PrepQueueService", "DetachedRunner", "ScoutExtractService",
                                    "ReplyClassifyService", "ScoutReadInFlight", "DownbeatBridge",
                                    "GmailConnection", "FileManager", "Data(contentsOf:"]

    // A declaration this scan has judged and let stand, each with the reason it is allowed. An entry with
    // no written reason is evidence nobody reasoned about it (L233), so the shape of this table forces
    // one. Keyed `File.declaration`.
    static let allowed: [String: String] = [
        "RootView.allRows": """
        read twice, but the second is inside `archiveItems: { allRows }`, a closure Archive evaluates when \
        it opens rather than a value this draw computes. One draw reads it once. This is the exemption the \
        header calls case 1, and it is the reason the rule is per body evaluation rather than per \
        reference.
        """,
        "QueueView.items": """
        read five times, and every one of the five is an ACTION path this text scan cannot tell from draw \
        code: two scroll-jump handlers, a send that snapshots one card, and the finish-missed-shows \
        control. Checked one at a time on 2026-09-12, not assumed. The body itself never reads it: \
        `data.items` is what every draw uses, and #1771 and #1772 are the two issues that made it so, \
        each naming the word difference. The remaining reads reach the region only because the body names \
        the functions those actions live in, which is the same limit #3829 recorded for `WatchlistEditing` \
        and settled the same way (L362).
        """,
    ]

    private static func appViewFiles() -> [(name: String, text: String)] {
        AppSourceWalk.urls(under: RepoRoot.mac.appendingPathComponent("Overture"))
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(": View") else {
                    return nil
                }
                return (url.deletingPathExtension().lastPathComponent, text)
            }
    }

    /// One declaration that costs something and is referenced more than once where a draw can reach it.
    struct Finding: CustomStringConvertible {
        let file: String
        let declaration: String
        let reads: Int
        let reaches: String
        var key: String { "\(file).\(declaration)" }
        var description: String { "\(key) read \(reads)x (\(reaches))" }
    }

    /// The scan, over one file. Exposed so `theScanCanSeeARepeatedDerivation` can drive it against a
    /// source that definitely has one: a scan whose only evidence is that it found nothing is
    /// indistinguishable from a scan that examined nothing (L90, L98).
    static func findings(inFileNamed name: String, text: String) -> [Finding] {
        let stripped = RedrawRegion.code(text)
        // The WHOLE-STORE CORPUS this file holds, however it came by it. A declaration naming one of
        // these sweeps the store.
        //
        // #3846 RE-AIMED THIS, and it is worth reading before narrowing it back. Until then a corpus was
        // recognised only as `@Query ... [Prospect]`, which was every way a view could have one. That
        // issue took the queue's and the Archive's own queries away, because RootView already held an
        // identical bare one and two of them share nothing (158.8 ms measured over 1,238 rows), and the
        // rows are handed down as a plain stored property instead. Recognising only the query shape would
        // have left this scan unable to see a corpus in the two views it was written against, and its
        // findings there would have gone to zero while reading as a clean result (L220, L98). The stale
        // exemption for `QueueView.items` was what said so.
        let storeQueries = stripped.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("@Query"), trimmed.contains("[Prospect]"),
               let varRange = trimmed.range(of: "var ") {
                let rest = trimmed[varRange.upperBound...]
                let named = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                return named.isEmpty ? nil : named
            }
            // A corpus HANDED IN: `let allProspects: [Prospect]`, a stored property with no initializer.
            // The trailing-value case (`let x: [Prospect] = ...`) is deliberately not matched, because a
            // local inside a function is not a corpus this view holds for the life of a draw.
            guard trimmed.hasSuffix(": [Prospect]"),
                  trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ") else { return nil }
            let rest = trimmed.dropFirst(4)
            let named = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            return named.isEmpty ? nil : named
        }

        let lines = stripped.components(separatedBy: "\n")
        let allDeclarations = RedrawRegion.declarations(in: stripped)
        // THE REGION ONE DRAW EVALUATES, and counting inside it rather than across the whole file is what
        // makes this "per draw" rather than "per mention". `QueueView.items` counted eleven after every
        // other exclusion, and all eleven were reads from ACTION paths: a send confirm, a jump, a probe
        // sweep. The body itself deliberately reads `data.items` and never the property (#1771, #1772), so
        // the file's own fix was being reported as the defect it fixed.
        let region = RedrawRegion.of(text)
        var found: [Finding] = []
        for (_, declaration) in allDeclarations {
            guard !declaration.body.isEmpty, declaration.name != "body" else { continue }
            // A VALUE somebody reads, never an ACTION somebody presses, and this is the distinction the
            // first real run of this scan got wrong. It reported `RootView.runScout` as "read 6x" because
            // six buttons name it, which is six controls rather than six derivations: an action runs when
            // Dan presses it and a computed property runs every time its name is evaluated. Ten of the
            // fifteen it first reported were actions (L147: measure how often a guard fires on the REAL
            // values before believing it).
            guard isAValueRatherThanAnAction(declaration.name, in: lines, at: declaration.line) else {
                continue
            }

            let reachedReaders = Self.filesystemReaders.filter { declaration.body.contains($0) }
            let sweptQueries = storeQueries.filter { references(to: $0, in: declaration.body) > 0 }
            guard !reachedReaders.isEmpty || !sweptQueries.isEmpty else { continue }

            // Counted OUTSIDE the declaration's own body, so a recursive mention or a name used in its
            // own return type is never counted as a call site.
            //
            // A SECOND DECLARATION OF THE SAME NAME IS NOT A CALL SITE EITHER, and that one is measured
            // rather than imagined: `QueueView.renderTrace` is declared twice, once under `#if DEBUG`
            // with a body and once returning `[:]` for Release. Counting the release declaration as a
            // read reported a DEBUG-only diagnostic as a repeated derivation, which is the noise that
            // makes a finding unreadable (L412).
            // Counted in the region, then the declaration's OWN body taken back off, because the region
            // contains that body whenever a draw reaches it and a recursive mention is not a call site.
            var reads = references(to: declaration.name, in: region)
            if region.contains(declaration.body) {
                reads -= references(to: declaration.name, in: declaration.body)
            }
            // And any body where the name is a PARAMETER rather than this property. `missedByACheckKeys(in
            // items:)` is the measured case (L412).
            for other in allDeclarations.values where other.name != declaration.name {
                guard other.line < lines.count, !other.body.isEmpty else { continue }
                let header = lines[other.line]
                guard header.contains("\(declaration.name):") else { continue }
                guard region.contains(other.body) else { continue }
                reads -= references(to: declaration.name, in: other.body)
            }
            guard reads > 1 else { continue }

            let reaches = reachedReaders.isEmpty
                ? "sweeps \(sweptQueries.joined(separator: ", "))"
                : "reads \(reachedReaders.joined(separator: ", "))"
            found.append(Finding(file: name, declaration: declaration.name, reads: reads, reaches: reaches))
        }
        return found.sorted { $0.reads > $1.reads }
    }

    /// Whole-word references to `name` in one piece of source, so `rows` never matches `allRows` and
    /// `items` never matches `archiveItems`. The first crude version of this scan counted substrings and
    /// reported `QueueView.items` twenty-five times, which is the noise that makes a finding unreadable
    /// (L412).
    private static func references(to name: String, in source: String) -> Int {
        // STRING LITERALS ARE NOT CODE, through the repo's own scanner rather than a second stripper of
        // my own (L41). `DaysOffView` draws `sectionHeading("Days you blocked", systemImage: "calendar")`,
        // and the word inside that literal was being counted as a read of its `calendar` property.
        //
        // `codeLines` and NOT `scannableLines`, and the difference is the whole point rather than a
        // detail: `scannableLines` leaves literals INTACT on purpose, because the copy guards it was
        // written for have to read the words inside a `Text(`. `codeLines` is the same scan with the
        // string contents removed, which its own comment says is "what you want when counting braces".
        // Reaching for the better known of the two is what left this counting a word inside a label.
        //
        // AND THE INTERPOLATIONS PUT BACK, because neither of the repo's two views is the one counting
        // reads needs. `Text("\(listed.count) waiting")` IS a read of `listed`, and `codeLines` removes
        // it along with the words around it. Taking only `codeLines` made this scan report an empty app
        // AND fail its own positive control in the same run, which is the control doing exactly its job:
        // a scan that can no longer find a planted repeat says nothing by finding none in the app (L90,
        // L171). The interpolated spans come off `scan.literals`, whose text keeps them intact by
        // contract, so this is still one scan of the source rather than a second stripper.
        let scan = SwiftSource.tokenize(source)
        var text = scan.codeLines.keys.sorted().compactMap { scan.codeLines[$0] }.joined(separator: "\n")
        for literal in scan.literals {
            for span in interpolatedSpans(in: literal.text) { text += "\n" + span }
        }
        var count = 0
        var searchFrom = text.startIndex
        while let range = text.range(of: name, range: searchFrom..<text.endIndex) {
            let beforeOK = range.lowerBound == text.startIndex
                || !isNameCharacter(text[text.index(before: range.lowerBound)])
            let afterOK = range.upperBound == text.endIndex
                || !isNameCharacter(text[range.upperBound])
            // A MEMBER OF SOMETHING ELSE is not this property. `group.items` and `data.items` are the
            // whole reason `QueueView.items` first counted twenty-five: the body deliberately reads
            // `data.items` (#1771, #1772) precisely so it does NOT read the property, and the scan was
            // counting each of those as a read of the thing they exist to avoid. `self.items` is kept,
            // because that IS a read of the property.
            let precededByDot = range.lowerBound > text.startIndex
                && text[text.index(before: range.lowerBound)] == "."
            let throughSelf = precededByDot && text[..<range.lowerBound].hasSuffix("self.")
            // AN ARGUMENT LABEL is not a read either: `items: group.items` names a parameter.
            let isALabel = range.upperBound < text.endIndex && text[range.upperBound] == ":"
            if beforeOK && afterOK && !isALabel && (!precededByDot || throughSelf) { count += 1 }
            searchFrom = range.upperBound
        }
        return count
    }

    /// The `\(...)` spans inside one string literal's text, which are code and not words.
    ///
    /// Nesting is counted rather than stopping at the first `)`, because `\(a.map { f($0) })` is one span
    /// and stopping early would cut a read in half.
    private static func interpolatedSpans(in literal: String) -> [String] {
        var spans: [String] = []
        let characters = Array(literal)
        var index = 0
        while index < characters.count - 1 {
            guard characters[index] == "\\", characters[index + 1] == "(" else {
                index += 1
                continue
            }
            var depth = 0
            var cursor = index + 1
            var span = ""
            while cursor < characters.count {
                let c = characters[cursor]
                if c == "(" { depth += 1 } else if c == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                if depth > 0, cursor > index + 1 { span.append(c) }
                cursor += 1
            }
            spans.append(span)
            index = cursor + 1
        }
        return spans
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// Whether the declaration on `line` produces a VALUE a draw can read, rather than performing an
    /// action a control invokes.
    ///
    /// COMPUTED PROPERTIES ONLY, and that is a MEASURED narrowing rather than a convenient one. #3852's
    /// own text says "a computed property or zero-argument function", so both were tried. Every
    /// zero-argument function the scan then flagged was reached only from actions, checked one at a time
    /// rather than assumed: `ArchiveView.actionRows` (a reveal and a send, and its own comment says "a
    /// reveal is an action outside any render pass"), `RootView.ingestScoutExtract` and
    /// `watchScoutExtractRun` (both from run-handling paths) and `RootView.readDownbeatHealth` (a control
    /// press and a launch `.task`). Every one of the six instances on record is a computed property.
    ///
    /// So a function arm would contribute nothing but exemptions, and a finding list that is mostly
    /// exemptions is one nobody reads (L172). WHAT THAT GIVES UP, stated rather than left implicit: a
    /// zero-argument function genuinely evaluated twice per draw is invisible here. Nothing in this app
    /// is one today, and this comment is what a future reader needs to know before trusting an empty list.
    private static func isAValueRatherThanAnAction(_ name: String, in lines: [String], at index: Int) -> Bool {
        guard index < lines.count else { return false }
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("var ") || trimmed.hasPrefix("private var ")
    }

    // UNMEASURED is its own outcome, and here it is the likeliest failure by far: a walk that read no
    // files, or a costly-reader list that matches nothing, produces an empty finding list that reads
    // exactly like an app with no repeated derivations in it (L98, L90).
    @Test func theScanReallyReadsTheAppAndFindsCostlyDeclarations() {
        let files = appViewFilesForTest()
        #expect(files.count > 30, "the walk read \(files.count) view files, so nothing below was measured")

        // At least one file really does hold a declaration this scan CLASSIFIES as costly. Without this,
        // a typo in `filesystemReaders` or a change to how `@Query` is spelled would make every file
        // uninteresting and the guard would pass by seeing nothing at all.
        var costly = 0
        for file in files {
            let stripped = RedrawRegion.code(file.text)
            for (_, d) in RedrawRegion.declarations(in: stripped) where !d.body.isEmpty {
                if Self.filesystemReaders.contains(where: { d.body.contains($0) }) { costly += 1 }
            }
        }
        #expect(costly > 5, """
        only \(costly) declarations in the whole app reach a filesystem reader, which cannot be right: \
        the classifier is not matching and every finding below would be a false absence
        """)
    }

    // THE POSITIVE CONTROL. The scan finds a repeated derivation when one is put in front of it.
    //
    // This is the half that makes an empty result below mean something. It is driven against a source
    // written here rather than against a real file, so it keeps working on the day the last real instance
    // is fixed, which is the day this suite would otherwise stop being able to fail (L1, L171).
    @Test func theScanCanSeeARepeatedDerivation() {
        let source = """
        struct ThingView: View {
            @Query private var prospects: [Prospect]
            private var tally: Int {
                prospects.filter { $0.status == .new }.count
            }
            private var marker: Bool {
                PrepQueueService.runInFlight(now: Date())
            }
            var body: some View {
                VStack {
                    if tally == 0 { Text("none") }
                    Text("\\(tally) waiting")
                    if marker { Text("running") }
                }
            }
        }
        """
        let found = Self.findings(inFileNamed: "ThingView", text: source)

        let tally = found.first { $0.declaration == "tally" }
        #expect(tally?.reads == 2, "a property read twice in one body was not found")
        #expect(tally?.reaches == "sweeps prospects", "the store sweep was not what it was flagged for")
        // And the one read ONCE is not reported, or every costly declaration in the app would be a
        // finding and the list would be unreadable.
        #expect(!found.contains { $0.declaration == "marker" },
                "a declaration read once was reported, so this scan flags cost rather than repetition")
    }

    // THE FINDING. Nothing in the app reads a costly derivation more than once per draw.
    @Test func noViewReadsACostlyDerivationMoreThanOncePerDraw() {
        var findings: [Finding] = []
        for file in appViewFilesForTest() {
            findings += Self.findings(inFileNamed: file.name, text: file.text)
                .filter { Self.allowed[$0.key] == nil }
        }

        #expect(findings.isEmpty, """
        \(findings.map(\.description).joined(separator: "; ")).

        Each of these is one question costing one derivation per reference, and at the call site it \
        reads as a free field access (L383). THE FIX DEPENDS ON THE FILE. If it declares a render pass, \
        the value belongs in the pass, where a cost test can count it (what #3646 did for \
        QueueView.checkRunning). If it does not, bind it once at the top of the body and hand it down \
        (what #3837 did for RootView.prepRefusal). If it is genuinely read once per DRAW and this scan \
        cannot tell, add it to `allowed` with the reason, which is what that table is for.
        """)
    }

    // Every exemption carries a reason somebody wrote, and it is checked rather than assumed: an entry
    // with an empty or placeholder reason is one nobody reasoned about, and it sits in the table looking
    // exactly like one somebody did (L233).
    @Test func everyExemptionCarriesAWrittenReason() {
        for (key, reason) in Self.allowed {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmed.count > 40, "\(key) is exempted with no real reason: \"\(trimmed)\"")
        }
    }

    // An exemption for a declaration that no longer exists, or that no longer reads more than once, is a
    // stale entry quietly widening what this guard permits. It is reported rather than left, on the same
    // rule a suppression set by hand has to carry an expiry and be listed somewhere visible (L523).
    @Test func noExemptionCoversSomethingThatIsNoLongerAFinding() {
        var live: Set<String> = []
        for file in appViewFilesForTest() {
            for finding in Self.findings(inFileNamed: file.name, text: file.text) { live.insert(finding.key) }
        }
        let stale = Self.allowed.keys.filter { !live.contains($0) }.sorted()
        #expect(stale.isEmpty, """
        \(stale.joined(separator: ", ")) is exempted here and is no longer a finding, so the exemption \
        is widening what this guard permits with nothing behind it. Delete the entry.
        """)
    }

    private func appViewFilesForTest() -> [(name: String, text: String)] { Self.appViewFiles() }
}
