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
        // The whole-store queries this file holds. A declaration naming one of these sweeps the store.
        let storeQueries = stripped.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@Query"), trimmed.contains("[Prospect]"),
                  let varRange = trimmed.range(of: "var ") else { return nil }
            let rest = trimmed[varRange.upperBound...]
            let named = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            return named.isEmpty ? nil : named
        }

        let lines = stripped.components(separatedBy: "\n")
        var found: [Finding] = []
        for (_, declaration) in RedrawRegion.declarations(in: stripped) {
            guard !declaration.body.isEmpty, declaration.name != "body" else { continue }

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
            var reads = 0
            for (index, line) in lines.enumerated() {
                guard index < declaration.line || index >= declaration.line + declaration.span else { continue }
                guard !declares(declaration.name, on: line) else { continue }
                reads += references(to: declaration.name, in: line)
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
    private static func references(to name: String, in text: String) -> Int {
        var count = 0
        var searchFrom = text.startIndex
        while let range = text.range(of: name, range: searchFrom..<text.endIndex) {
            let beforeOK = range.lowerBound == text.startIndex
                || !isNameCharacter(text[text.index(before: range.lowerBound)])
            let afterOK = range.upperBound == text.endIndex
                || !isNameCharacter(text[range.upperBound])
            if beforeOK && afterOK { count += 1 }
            searchFrom = range.upperBound
        }
        return count
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// Whether this line DECLARES the named property or function, rather than reading it.
    private static func declares(_ name: String, on line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["private var ", "private func ", "var ", "func "] where trimmed.hasPrefix(prefix) {
            let rest = trimmed.dropFirst(prefix.count)
            return String(rest.prefix { isNameCharacter($0) }) == name
        }
        return false
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
