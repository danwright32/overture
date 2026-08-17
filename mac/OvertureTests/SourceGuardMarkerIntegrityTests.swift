import Testing
import Foundation

// #2192. Roughly 111 test files reference `SourceGuardHelper`, `SwiftSource` or `CopyInventory`, carrying
// about a fifth of the suite. They assert a rule is still WRITTEN in the source rather than exercising
// behaviour, so a rename, a moved file or a refactor can leave them passing while they check nothing, and
// a hollow guard is indistinguishable from a real one until the defect it was written to catch ships.
//
// #629's meta-guard already covers two ways they go stale: a source PATH that no longer exists, and a
// `named:` function that no longer exists. This covers the two that were still open, and both of them
// were walked into for real while working this milestone on 2026-08-06:
//
//   1. A `propertyBody` marker that does not end at its own opening brace. `propertyBody` counts braces
//      FROM the marker, so a marker stopping at "(" starts the scan inside the signature and only
//      balances at the end of the whole type. The "body" then contains every call site in the file and
//      agrees with itself whatever they say (L70). A guard written that way passed while the code it
//      claimed to pin was doing the opposite.
//
//   2. A marker that no longer matches the file it is asked of. `propertyBody` and `between` both return
//      nil, callers spell that `?? ""` or an optional chain, and every `contains` against an empty string
//      is false: a `#expect(!body.contains(...))` then passes for the wrong reason forever.
//
// Deliberately DERIVED from the suite rather than a list somebody maintains beside it (L41), so a guard
// added tomorrow is covered without anybody remembering to add it here.
//
// What this does NOT do, stated plainly: it does not break each of the ~994 guarded rules and confirm the
// guard goes red. That remains the rest of #2192's ask. What it does is make the two SILENT ways a guard
// hollows itself out impossible to introduce without this failing.
@Suite("Source guards cannot silently stop matching (#2192)")
struct SourceGuardMarkerIntegrityTests {
    private static var macRoot: URL {
        RepoRoot.mac
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    }

    // Any quoted repo-relative path a guard reads. Filenames here really do carry `+` (QueueView+Model)
    // and the runner guards read `.sh`, so both are in the character class on purpose: a narrower one
    // silently finds no haystack and every marker in that file reads as unmatched.
    private static let pathLiteral = regex(#""([A-Za-z0-9_/+.-]+\.(?:swift|sh))""#)
    private static let propertyBodyMarker = regex(#"propertyBody\(\s*"((?:[^"\\]|\\.)*)""#)

    // #2841: the same call with its marker arriving through a NAME rather than as a literal.
    //
    // The regex above only ever saw a literal, and that is not a hypothetical hole: it is exactly how the
    // defect the guard was written for stayed hidden. The `focusOnLeads` vacuity in
    // `QueueInvalidationGuardTests` survived #2784 because its markers sat in an array rather than as
    // literal arguments, so nothing matched the call at all and the scan reported cleanly on a guard whose
    // searched region was every line of QueueView below a function.
    //
    // A bare identifier only. `surface.marker` and other member accesses are deliberately NOT matched:
    // those come from a registry (`QueueShowableSurfacesAreOnePredicateTests`) that drives its own missing
    // and ambiguous findings, so it is reviewed, just not by this guard, and there is no single literal to
    // resolve them to anyway.
    private static let propertyBodyVariableMarker = regex(#"propertyBody\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,"#)

    // `let name = "literal"`, or `let name: String = "literal"`, in the same file. One level, no
    // arithmetic, no concatenation: a name defined once and used once is the shape this is for, and
    // anything cleverer would be a source-text interpreter guessing at values (L103's direction).
    private static func literalBinding(named name: String, in source: String) -> String? {
        let pattern = regex(#"\blet\s+"# + NSRegularExpression.escapedPattern(for: name)
                            + #"\s*(?::\s*String\s*)?=\s*"((?:[^"\\]|\\.)*)""#)
        return captures(pattern, in: source, groups: [1]).first
    }

    // Every marker a file hands to `propertyBody`, whether written at the call or resolved through a
    // local binding. One list, so the checks below cannot cover one shape and miss the other.
    private static func propertyBodyMarkers(in source: String) -> [String] {
        var out = captures(propertyBodyMarker, in: source, groups: [1])
        for name in captures(propertyBodyVariableMarker, in: source, groups: [1]) {
            if let literal = literalBinding(named: name, in: source) { out.append(literal) }
        }
        return out
    }
    private static let betweenMarkers = regex(#"between\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*and:\s*"((?:[^"\\]|\\.)*)""#)
    // #2417: the third way a guard names the code it reads. `bodyOfFunction` takes a NAME rather than a
    // signature, which is what makes it survive a parameter change, but the name can go stale in exactly
    // the same silent way: it returns nil, the caller spells that `?? ""`, and every `contains` against
    // an empty string is false. Added here in the same change that added the helper, because a scan that
    // only checks the idioms somebody remembered is a scan that is blind to the newest one (L96).
    private static let functionNameMarker = regex(#"bodyOfFunction\(\s*named:\s*"([A-Za-z0-9_]+)""#)

    private static func captures(_ re: NSRegularExpression, in text: String, groups: [Int]) -> [String] {
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).flatMap { match in
            groups.compactMap { g -> String? in
                let r = match.range(at: g)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }

    // Swift source is written with escapes ("\\(" for a literal backslash-paren, "\"" for a quote), and a
    // marker is compared against real file text, so the escapes have to come off first or every marker
    // containing one reads as unmatched.
    private static func unescape(_ literal: String) -> String {
        literal
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    // The two files that legitimately pass propertyBody/between text they BUILT rather than text read
    // from a source file: the helper's own unit tests, and this scan, whose source contains the very
    // literals it searches for. Named rather than inferred, and pinned by `theExclusionsAreExactlyThose`
    // below, so the list cannot quietly grow to cover a guard that has genuinely gone blind.
    private static let buildsItsOwnText: Set<String> = [
        "SourceGuardHelperTests.swift",
        "SourceGuardMarkerIntegrityTests.swift",
    ]

    private struct GuardFile {
        let name: String
        let text: String         // the guard file's CODE, comments stripped (see below)
        let haystack: String     // every source file this test reads, joined
    }

    // Every marker below is read out of the guard file's CODE, never its raw text. A guard test's
    // comments quote the very shapes these patterns look for (this file's own do), and a commented-out
    // or merely DESCRIBED call would then be scanned as a live one: reported as stale when it matches
    // nothing, or as a mid-signature pin when it was only ever an example in prose. A pattern that reads
    // comments is a pattern that fires on its own documentation (L103), which is one of the three ways
    // the guards this suite audits have already passed on broken code (#2726).
    //
    // `skipping: []` on purpose: a DEBUG branch or a marked region in a test file still holds real
    // guards, and this is asking about the guards, not about what the app says.
    private static func code(of text: String) -> String {
        SwiftSource.scannableLines(in: text, skipping: []).map(\.code).joined(separator: "\n")
    }

    private static let guardFiles: [GuardFile] = {
        var out: [GuardFile] = []
        for dir in ["OvertureTests", "OvertureHostedTests"] {
            // #2311: through the shared walk, which refuses out loud rather than handing back an
            // empty list a guard would read as a clean result.
            for file in AppSourceWalk.files(under: macRoot.appendingPathComponent(dir), floor: 20) {
                guard !buildsItsOwnText.contains(file.name) else { continue }
                let source = code(of: file.text)
                guard source.contains("propertyBody(") || source.contains("between(")
                        || source.contains("bodyOfFunction(") else { continue }
                let bodies = Set(captures(pathLiteral, in: source, groups: [1])).compactMap {
                    try? String(contentsOf: macRoot.appendingPathComponent($0), encoding: .utf8)
                }
                out.append(GuardFile(name: file.name, text: source,
                                     haystack: bodies.joined(separator: "\n")))
            }
        }
        return out
    }()

    // The premise, measured rather than assumed: this really is looking at the guards. Without it every
    // assertion below would pass on an empty list, which is the exact failure the suite is being audited
    // for (L1, and the "empty check must fail" rule #1710 states).
    @Test func thereReallyAreGuardsToCheck() {
        #expect(Self.guardFiles.count >= 20,
                "found only \(Self.guardFiles.count) files using propertyBody/between; the scan is broken")
        let markers = Self.guardFiles.flatMap {
            Self.captures(Self.propertyBodyMarker, in: $0.text, groups: [1])
        }
        let names = Self.guardFiles.flatMap {
            Self.captures(Self.functionNameMarker, in: $0.text, groups: [1])
        }
        // A floor PER IDIOM, not one total. #2599 moved 45 markers off `propertyBody` and onto
        // `bodyOfFunction`, so a single total would have stayed comfortably above its floor while one of
        // the two regexes stopped matching anything at all, and an idiom nobody is scanning is exactly
        // the state this suite exists to make impossible (L53, L96). Measured after that sweep,
        // 2026-08-16: 31 and 53. Both floors sit well under those, because a tight number fails on an
        // ordinary deletion and teaches the next person to lower it without reading (L63).
        #expect(markers.count >= 15, "found only \(markers.count) propertyBody markers")
        #expect(names.count >= 25, "found only \(names.count) bodyOfFunction markers")
    }

    // 1. Every `propertyBody` marker ends at its own opening brace.
    //
    // `propertyBody` scans braces from the marker with depth already at 1, so a marker stopping short of
    // the brace begins inside the signature and does not balance until the end of the enclosing type. The
    // returned "body" is then most of the file, and a guard asking whether it CONTAINS something is
    // answered by any occurrence anywhere, while one asking whether it does NOT is answered by the whole
    // file. Either way it agrees with itself and stops depending on the code it names.
    // #2841: through the resolver, so a marker arriving by name is held to this too. All three checks in
    // this file share one list, or one shape would be covered and the other missed, which is the defect
    // being closed here rather than a second version of it.
    @Test func everyPropertyBodyMarkerEndsAtItsOwnBrace() {
        for file in Self.guardFiles {
            for marker in Self.propertyBodyMarkers(in: file.text) {
                #expect(marker.hasSuffix("{"),
                        """
                        \(file.name): the marker \(marker.debugDescription) does not end at "{". \
                        propertyBody counts braces from the marker, so this one scans from inside the \
                        signature and returns the rest of the type instead of the body it names, which \
                        makes every assertion against it self-agreeing (#2192, L70).
                        """)
            }
        }
    }

    // Is this `propertyBody` marker anchored to a FUNCTION rather than to a property, a type or a
    // brace-delimited region? Two shapes, and they are two because the guards were written both ways:
    //
    //   1. The whole signature as written ("private func focusOnStage(_ status: AgentStatus) {").
    //   2. The LAST LINE of a wrapped argument list ("agentInputs: AgentInputs) -> some View {",
    //      "async -> ReconcileSummary {"), which is what a guard reaches for once the signature no
    //      longer fits on one line.
    //
    // The second is told from a legitimate marker by its parens: a mid-signature anchor CLOSES a paren
    // it never opened, or opens with the tail of a signature (`->`, `async`, `throws`). A marker that
    // merely contains a balanced call, `.onChange(of: focus) {`, is left alone, which is why this counts
    // parens rather than looking for one.
    static func functionAnchor(_ marker: String) -> String? {
        if marker.contains("func ") { return "it pins the function's whole signature as written" }
        if marker.filter({ $0 == ")" }).count > marker.filter({ $0 == "(" }).count {
            return "it pins the last line of the function's argument list"
        }
        let head = marker.trimmingCharacters(in: .whitespaces)
        if ["->", "async", "throws", "rethrows"].contains(where: { head.hasPrefix($0) }) {
            return "it pins the tail of the function's signature"
        }
        return nil
    }

    // 3. No `propertyBody` marker is anchored to a function (#2599, #2784).
    //
    // `propertyBody` needs its marker to run all the way to the opening brace, so a guard using it on a
    // function is pinned to that function's signature AS WRITTEN. Adding a parameter, renaming one, or
    // merely re-wrapping the signature across two lines then makes the marker match nothing:
    // `propertyBody` returns nil, and at the call sites that spell that `?? ""` every assertion beneath
    // it is quietly false, while at the ones that `Issue.record` it goes red for a reason unrelated to
    // the rule. #2417 hit it (five guards over two QueueView functions), #2524 hit it again (two more),
    // and each time the fix was the same: `bodyOfFunction(named:in:)`, which finds the declaration by
    // name and walks the parameter list by paren depth.
    //
    // So the class is closed here rather than swept a third time (L30, L96). This runs over every guard
    // file in both targets, derived rather than listed, so a marker written tomorrow is covered.
    // #2841: markers reaching `propertyBody` through a local NAME are judged too, because that is the
    // shape the defect this guard exists for actually wore.
    @Test func noPropertyBodyMarkerIsAnchoredToAFunction() {
        for file in Self.guardFiles {
            for marker in Self.propertyBodyMarkers(in: file.text) {
                let anchor = Self.functionAnchor(marker)
                #expect(anchor == nil,
                        """
                        \(file.name): the marker \(marker.debugDescription) anchors propertyBody to a \
                        function, because \(anchor ?? ""). The next parameter added or signature \
                        re-wrapped makes it match nothing, and a marker that matches nothing returns \
                        nil, which every `contains` beneath it reads as false. Use \
                        SourceGuardHelper.bodyOfFunction(named:in:) instead, which finds the \
                        declaration by name (#2599, #2784, L103).
                        """)
            }
        }
    }

    // The classifier itself, exercised on each shape it claims to know rather than only ever watched not
    // to fire. A documented outcome nobody constructs can be unreachable in the code while the guard
    // looks thoroughly tested (L151), and the mid-signature shapes are exactly the ones a fixture is
    // least likely to reach for.
    @Test func theClassifierKnowsEachShapeItNames() {
        #expect(Self.functionAnchor("private func focusOnStage(_ status: AgentStatus) {") != nil)
        #expect(Self.functionAnchor("@ViewBuilder private func focusedSection(data: RenderData) -> some View {")
                != nil)
        #expect(Self.functionAnchor("agentInputs: AgentInputs) -> some View {") != nil)
        #expect(Self.functionAnchor("only: Set<String>? = nil) {") != nil)
        #expect(Self.functionAnchor("async -> ReconcileSummary {") != nil)

        // And the markers it must leave alone: a stored property, a type, a brace-delimited region, and
        // one carrying a BALANCED call, which is what separates this from "the marker mentions a paren".
        #expect(Self.functionAnchor("private var masthead: some View {") == nil)
        #expect(Self.functionAnchor("struct QueueScrollHolder<Content: View>: View {") == nil)
        #expect(Self.functionAnchor("if let insecure = source.insecureFetchNote {") == nil)
        #expect(Self.functionAnchor(".onChange(of: focusedStage) {") == nil)
    }

    // And the scan reads code, not prose. This file's own comments quote the exact call shapes the
    // patterns above look for, so without the strip a marker that only ever existed as an example, or a
    // call somebody commented out, would be scanned as a live guard: reported stale when it matches
    // nothing, or reported as a mid-signature pin when it is not a pin at all. Exercised on both, rather
    // than trusted, because a strip that stopped working leaves every check passing for the wrong reason.
    @Test func theScanReadsCodeAndNotComments() {
        let file = """
        // An example in prose: SourceGuardHelper.propertyBody("private func gone(x: Int) {", in: src)
        struct Thing {
            let real = SourceGuardHelper.propertyBody("private var masthead: some View {", in: src)
            // let old = SourceGuardHelper.propertyBody("private func alsoGone() {", in: src)
        }
        """
        let markers = Self.captures(Self.propertyBodyMarker, in: Self.code(of: file), groups: [1])
        #expect(markers == ["private var masthead: some View {"])
        // Which is exactly what the raw text would NOT have said, and the difference is the point.
        #expect(Self.captures(Self.propertyBodyMarker, in: file, groups: [1]).count == 3)
    }

    // #2841: a marker reaching propertyBody through a local NAME is resolved and judged.
    //
    // The guard used to see literal arguments only, and that is not a hypothetical hole: it is how the
    // `focusOnLeads` vacuity survived #2784, its markers sitting in an array rather than at the call. So
    // the vacuous marker below is planted in the shape that actually hid one, and every check in this
    // file is asked of it.
    @Test func aMarkerReachedThroughALocalNameIsResolvedAndJudged() {
        let file = """
        struct Guarded {
            func check() {
                let marker = "private func focusOnLeads(_ keys: Set<String>) {"
                let body = SourceGuardHelper.propertyBody(marker, in: src) ?? ""
                #expect(body.contains("something"))
            }
        }
        """
        let resolved = Self.propertyBodyMarkers(in: Self.code(of: file))
        #expect(resolved == ["private func focusOnLeads(_ keys: Set<String>) {"],
                "a marker defined once and used once must be followed to its literal")
        // And once resolved it is CONDEMNED, which is the whole point: this is a function signature, so
        // propertyBody scans from inside the parameter list and hands back most of the type.
        #expect(Self.functionAnchor(resolved[0]) != nil,
                "a resolved marker must be judged by the same rule a literal one is")
    }

    // The other direction, which is what keeps this from becoming a source interpreter: a name it cannot
    // resolve to a single literal in the same file yields NOTHING rather than a guess. The registry in
    // QueueShowableSurfacesAreOnePredicateTests is the live example, and it is reviewed by its own missing
    // and ambiguous findings rather than by this.
    @Test func anUnresolvableNameIsNotGuessedAt() {
        let registry = """
        struct Guarded {
            func check() {
                for surface in Self.surfaces {
                    let body = SourceGuardHelper.propertyBody(surface.marker, in: text)
                }
            }
        }
        """
        #expect(Self.propertyBodyMarkers(in: Self.code(of: registry)).isEmpty,
                "a member access has no single literal to resolve to, so it is left to its own review")

        let elsewhere = """
        struct Guarded {
            func check() {
                let body = SourceGuardHelper.propertyBody(markerFromAnotherFile, in: text)
            }
        }
        """
        #expect(Self.propertyBodyMarkers(in: Self.code(of: elsewhere)).isEmpty,
                "a name with no binding in this file is not invented")
    }

    // 2. Every marker still matches something in the source its own test file reads.
    //
    // A marker that stops matching returns nil, spelled at the call site as `?? ""` or an optional chain,
    // and every `contains` against an empty string is false. The guard goes on passing and has stopped
    // asking anything at all.
    @Test func everyMarkerStillMatchesTheSourceItIsAskedOf() {
        for file in Self.guardFiles where !file.haystack.isEmpty {
            let markers = Self.propertyBodyMarkers(in: file.text)
                + Self.captures(Self.betweenMarkers, in: file.text, groups: [1, 2])
            for marker in markers where !marker.isEmpty {
                #expect(file.haystack.contains(Self.unescape(marker)),
                        """
                        \(file.name): the marker \(marker.debugDescription) matches nothing in the source \
                        this test reads, so the guard using it is asking nothing at all. Point it at the \
                        code's current wording, or delete the guard (#2192, L1).
                        """)
            }
            // The same question of a `bodyOfFunction` name, asked the way that helper asks it: the
            // DECLARATION, never a call site, so a function deleted while its callers remain still reads
            // as gone.
            for name in Self.captures(Self.functionNameMarker, in: file.text, groups: [1]) {
                #expect(file.haystack.contains("func \(name)("),
                        """
                        \(file.name): no function named \(name) is declared in the source this test \
                        reads, so bodyOfFunction returns nil and every check standing on it is asking \
                        nothing at all. Point it at the function's current name, or delete the guard \
                        (#2192, #2417, L1).
                        """)
            }
        }
    }

    // The exclusions are exactly the two that build their own text, and both still exist. A stale name in
    // that list is an exclusion covering nothing, and a list free to grow is how this audit would hollow
    // ITSELF out.
    @Test func theExclusionsAreExactlyThoseThatBuildTheirOwnText() throws {
        #expect(Self.buildsItsOwnText.count == 2)
        for name in Self.buildsItsOwnText {
            let url = Self.macRoot.appendingPathComponent("OvertureTests").appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path),
                    "\(name) is excluded from this scan and no longer exists")
        }
    }

    // And every guard file names a source to read. One that names none has no haystack, so the check
    // above skips it entirely, and a skip that nobody sees is how this audit would hollow ITSELF out.
    @Test func everyGuardFileNamesSourceItCanActuallyRead() {
        let blind = Self.guardFiles.filter { $0.haystack.isEmpty }.map(\.name).sorted()
        #expect(blind.isEmpty,
                """
                these use propertyBody/between but read no source file this check could resolve, so their \
                markers are unverifiable here: \(blind.joined(separator: ", ")). Either they read a path \
                shape the scan does not recognise (widen it) or they are passing text built in the test, \
                which is fine but should be obvious.
                """)
    }
}
