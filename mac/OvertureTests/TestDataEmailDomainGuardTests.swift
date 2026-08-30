import Foundation
import Testing

// #2839 / #2833: nothing stops a real person's e-mail address being written into a test.
//
// A reviewer cannot tell an invented contact from a real one by reading a fixture, so the only defence
// was somebody recognising a name, and that failed twice. On 2026-08-16 an agent copied a real
// presenter's address, name and their own words out of an issue body into a test file and opened a PR
// against this PUBLIC repository (#2831). The scrub that followed (#2844) replaced the twelve
// consumer-mail addresses it found. A SECOND class was structurally invisible to it, because the sweep
// matched consumer-mail domains: addresses at real performers' OWN personal-name domains. Nine of those
// were still here on 2026-08-22, and so was the first class's other half, since #2844 replaced only the
// DOMAIN, leaving the person's own name as the local part and as a display name.
//
// #2833 specified this guard and was closed by that scrub. The guard itself was never built, so the
// class read as handled for six days while nothing checked it.
//
// THE RULE IS AN ALLOWLIST, and that is the whole design. A blocklist of consumer-mail domains is what
// had the blind spot: it allows any domain not on its list, so a performer's own personal-name domain
// went through it exactly as if nothing were being checked. An allowlist cannot have that shape of hole
// (L96). This comment deliberately does not quote one of the real addresses to make the point, and that
// is not squeamishness: the first version did, and this guard failed on its own source, which is the
// rule working. A file explaining a forbidden shape must not contain the shape.
//
// WHAT THIS RULE STRUCTURALLY CANNOT SEE, and where that half lives now (#3110). Judging an address by
// its DOMAIN closes the deliverability half and nothing else: a reserved TLD makes an address unusable
// and does nothing at all about a public repository stating that a named musician is a prospect.
// `arealpersonsname.example` passes every line below. So does a real person's name kept as the LOCAL
// PART of the invented address that replaced theirs, which is what #2839's own scrub left behind,
// because it replaced only the domain.
//
// That half is answered by `scripts/check-test-identity-provenance.sh`, and by evidence rather than by
// a pattern: a name whose first appearance in this repository is a privacy SCRUB commit was minted by
// that scrub and is invented, and one whose first appearance is an ordinary feature commit was written
// by somebody with a real page open. It reports rather than refuses, because plenty of
// feature-introduced names are perfectly invented, so it cannot be a gate and is deliberately not one.
// The regression half below stays exactly as it is: it is the record of people already found, and it
// can see a display name and a handle, which no address rule can.
//
// THE ALLOWED SET IS DERIVED, not hand written, in the one place it could otherwise go stale: a domain
// the APP'S OWN source names in a rule is a domain a test of that rule legitimately needs.
// `WatchedSourceBackfill` matches on "carnegiehall.org", so a test of it must say "carnegiehall.org".
// Reading that from the app rather than listing it here means the permission disappears by itself when
// the rule does. COMMENT lines are deliberately excluded from that read: a comment is prose, and prose
// naming a real person is precisely what this exists to remove, so letting a comment grant permission
// would let the exposure authorise itself.
@Suite("Test data addresses only domains that can never belong to anybody (#2839)")
struct TestDataEmailDomainGuardTests {

    // RFC 2606 and RFC 6761 reserve these so they can never be registered by anyone.
    static let reservedTLDs: Set<String> = ["example", "invalid", "test", "localhost", "local"]
    static let reservedDomains: Set<String> = ["example.com", "example.org", "example.net"]
    // Dan's own sending identity, which the suite legitimately uses as the FROM address.
    static let ownDomains: Set<String> = ["danwrightphotography.com"]

    // A computed property, not a stored one: Regex is not Sendable, so a `static let` is refused
    // under Swift 6 strict concurrency. Building one per use costs nothing at this scale.
    static var addressPattern: Regex<(Substring, Substring)> { /[A-Za-z0-9._%+\-]+@([A-Za-z0-9.\-]+\.[A-Za-z]{2,})/ }

    static func isReserved(_ domain: String) -> Bool {
        let d = domain.lowercased()
        if reservedDomains.contains(d) || ownDomains.contains(d) { return true }
        guard let tld = d.split(separator: ".").last else { return false }
        return reservedTLDs.contains(String(tld))
    }

    // Every domain the app's own NON-COMMENT source names. Derived for the reason in the header.
    static func domainsAppSourceNames() -> Set<String> {
        var found: Set<String> = []
        for file in AppSourceWalk.appFiles() {
            for line in file.text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                for m in String(line).matches(of: addressPattern) {
                    found.insert(String(m.1).lowercased())
                }
                // A rule can name a bare host without an address around it, which is how
                // WatchedSourceBackfill and FeedReconcile name theirs.
                for m in String(line).matches(of: /[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+\.[A-Za-z]{2,}/) {
                    found.insert(String(m.0).lowercased())
                }
                for m in String(line).matches(of: /[A-Za-z0-9\-]+\.[A-Za-z]{2,}/) {
                    found.insert(String(m.0).lowercased())
                }
            }
        }
        return found
    }

    static func backlog() throws -> Set<String> {
        let url = RepoRoot.url.appendingPathComponent("fixtures/test-data-email-domains.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        return Set(text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.lowercased() })
    }

    struct Finding: Hashable { let domain: String; let file: String }

    // #3235: three of this suite's four tests ask for the same findings over the same unchanged tree,
    // and each was paying about 11.6s for it. Built once per process, on the same terms as the copy
    // documents: a run that scanned NO files is never kept, because an empty finding list is exactly
    // what a broken path produces and is indistinguishable downstream from a clean tree (L286, L98).
    // `theWalkReachesTheTestSources` is the test that would catch a kept empty scan, and it still runs
    // against this.
    private static let findingsMemo = BuildMemo<(all: [Finding], filesScanned: Int)>()

    static func findings() throws -> (all: [Finding], filesScanned: Int) {
        try findingsMemo.value(keepIf: { $0.filesScanned > 0 }) { try scanForFindings() }
    }

    private static func scanForFindings() throws -> (all: [Finding], filesScanned: Int) {
        let allowedByApp = domainsAppSourceNames()
        var out: [Finding] = []
        var scanned = 0
        // Through AppSourceWalk, never a private enumerator: a guard that walks a directory itself does
        // not inherit the refusal on an empty walk, and passes silently when the path resolves to
        // nothing (#2311). The extensions argument exists for this caller.
        for root in ["mac/OvertureTests", "mac/OvertureHostedTests", "mac/TestSupport", "fixtures"] {
            let dir = RepoRoot.url.appendingPathComponent(root)
            for file in AppSourceWalk.files(under: dir, floor: 1,
                                            extensions: ["swift", "json", "txt", "md", "html"]) {
                guard file.name != "test-data-email-domains.txt" else { continue }
                scanned += 1
                for m in file.text.matches(of: addressPattern) {
                    let d = String(m.1).lowercased()
                    if isReserved(d) || allowedByApp.contains(d) { continue }
                    out.append(Finding(domain: d, file: file.name))
                }
            }
        }
        return (out, scanned)
    }

    // The walk refuses out loud on an empty result rather than reporting a clean tree, for the reason
    // AppSourceWalk exists: a guard that checked nothing and a guard that found nothing are the two most
    // different outcomes there are, and they look identical (L98, #2311).
    @Test func theWalkReachesTheTestSources() throws {
        let (_, scanned) = try Self.findings()
        #expect(scanned > 500, """
            This guard scanned \(scanned) test files, far fewer than this repo has. That is a broken \
            path, not clean test data: with nothing to walk every assertion below passes over \
            everything it exists to check.
            """)
    }

    @Test func noTestDataAddressesADomainSomebodyCouldOwn() throws {
        let known = try Self.backlog()
        let (all, _) = try Self.findings()
        let fresh = all.filter { !known.contains($0.domain) }
        let byDomain = Dictionary(grouping: fresh, by: \.domain)
        #expect(byDomain.isEmpty, """
            Test data addresses \(byDomain.count) domain(s) that are not reserved, not Dan's own, not \
            named by the app's own rules, and not in the recorded backlog:

            \(byDomain.keys.sorted().map { d in "  \(d)  in \(Set(byDomain[d]!.map(\.file)).sorted().joined(separator: ", "))" }.joined(separator: "\n"))

            A domain that can be registered can belong to a real person, and this repository is PUBLIC. \
            Use an .example domain instead: an invented personal-name one where the test is ABOUT a \
            personal-name domain (ReplyCandidateMatch treats that shape as a signal), so the test keeps \
            proving what it was written for. Never add it to fixtures/test-data-email-domains.txt: that \
            file only ever shrinks.
            """)
    }

    // The backlog may only shrink. An entry for a domain no longer present is a line to delete, and
    // leaving it means the file stops describing the tree and starts hiding a re-introduction.
    @Test func theRecordedBacklogHasNoEntriesThatAreAlreadyGone() throws {
        let known = try Self.backlog()
        let (all, _) = try Self.findings()
        let present = Set(all.map(\.domain))
        let gone = known.subtracting(present).sorted()
        #expect(gone.isEmpty, """
            fixtures/test-data-email-domains.txt still lists \(gone.count) domain(s) that no longer \
            appear in any test data: \(gone.joined(separator: ", ")).

            Delete those lines. The file is a ratchet, and one that never tightens is not one.
            """)
    }

    // Every real person scrubbed out of this PUBLIC repository must not come back, by name OR by handle
    // OR by domain. This is the narrow regression half, deliberately kept beside the general rule rather
    // than instead of it: the rule above judges an ADDRESS by its domain and can see neither a display
    // name nor an Instagram handle.
    //
    // Two batches now. #2839 scrubbed twelve people found by grepping for e-mail addresses, which is the
    // shape somebody happened to look for. #2834 swept the shapes that sweep could not see and found
    // twenty-one more: eight named people paired with real Instagram handles, and thirteen producers and
    // music directors credited on real shows, which arrive the same way an address does, because a test
    // written from a real listing keeps the real credits.
    //
    // What is deliberately NOT here: venues and organisations. A room's published phone number, address
    // or account is public information about a public entity, so `jalopytheatre` and a box office number
    // stay. The target is a private individual (#2834 says so, and a rule that fired on every venue would
    // fire on the common case and be switched off, L93).
    @Test func noScrubbedRealPersonReturnsByNameOrHandle() throws {
        let scrubbed = [
                        // #2834, the handles
                        "cydneyemcg", "maggieestephens", "sarah.bernadette", "migueamell", "markklett",
                        "sunny.sheu", "kenjin39", "heybailay", "celloverton", "alexkim",
                        // #2834, the names
                        "cydney mcquillan-grace", "cydney mcquillan", "maggie stephens",
                        "maggie wisniewski", "sarah bernadette", "miguel amell", "mark klett",
                        "sunny sheu", "kento hong", "sarah overton", "alex kim",
                        // #2834, three more found by extracting every `name:` literal in test data and
                        // provenance-testing each: a name introduced by a SCRUB commit is invented and
                        // stays, one introduced by a feature commit was written from real data. That test
                        // is what kept "Corin Hale" and "Nora Calder" (both minted by #2839 and #2844) and
                        // what condemned these.
                        "tatianna cordoba", "sam ock", "zachary mcintyre", "zachmcint",
                        // #2834, the producer and music director credits
                        "ben cameron", "bela reynoso", "daniel rubinson", "bryce valle",
                        "ellen grace diehl", "jenna matula", "kelsey seaman", "rachel sandler",
                        "mackenzie bruen",
                        // Written twice, because the accented character reaches this comparison as itself
                        // in a JSON fixture and as the six characters of a unicode escape in Swift source.
                        "desir\u{00E9}e dabney", "desir\\u{00e9}e dabney",
                        // #2839
"ryanjamesmonroe", "reevecarney", "jerrickcavagnaro", "alexsyiek", "vegaviolin",
                        "annapierre", "samweaver", "iyerviolin", "marcduval", "jakebergmagic",
                        "oliviaterpin", "caseengaines", "caseen.gaines", "ryansbrother",
                        "ryan james monroe", "reeve carney", "jerrick cavagnaro", "alex syiek",
                        "marisol vega", "anna pierre", "sam weaver", "tomas iyer", "marc duval",
                        "jake berg", "olivia terpin", "caseen gaines"]
        // Every one of those names ALSO forbidden in each of the separators a machine puts between its
        // parts, DERIVED rather than listed again (#3110). A person comes back as a domain label, a
        // handle, an e-mail local part or a URL slug far more often than as prose, because that is the
        // form a website and a social account put them in, and the spaced spelling matches none of them.
        // That was not hypothetical: `tatianna cordoba` and `maggie stephens` were scrubbed by #2834,
        // were on this list the whole time, and were both still in the tree as personal-name hosts,
        // which this check read as clean.
        //
        // Deriving it, rather than writing the variants beside the names, is the point: adding a name
        // covers every form at once, so the halves cannot drift the way the hand-written pairs for
        // #2839's people could. The empty separator is first because it is the one that was missing.
        let forbidden = scrubbed + ["", ".", "-", "_"].flatMap { separator in
            scrubbed
                .filter { $0.contains(" ") }
                .map { $0.replacingOccurrences(of: " ", with: separator) }
        }
        // #3235: ONE pass per file for the whole list, instead of one Unicode-aware string search per
        // name per file. This test alone measured 216 seconds of a 705 second suite on 2026-08-29,
        // about 150 names across about 1,000 files. The scanner is judged against the search it
        // replaces by a differential test rather than by a list of cases (ForbiddenTextScannerTests),
        // and it keeps the slow path for the accented names, where a byte comparison would let a real
        // person through.
        let scanner = ForbiddenTextScanner(needles: forbidden)
        var hits: [String] = []
        for root in ["mac", "fixtures", "src", "docs"] {
            let dir = RepoRoot.url.appendingPathComponent(root)
            for file in AppSourceWalk.files(under: dir, floor: 1,
                                            extensions: ["swift", "json", "txt", "md", "html", "sh", "ts"]) {
                guard !file.url.path.contains("Overture.xcodeproj") else { continue }
                // Its own source has to NAME what it forbids, so it is the one file it cannot police.
                guard file.name != "TestDataEmailDomainGuardTests.swift" else { continue }
                for name in scanner.matches(in: file.text) {
                    hits.append("\(name) in \(file.name)")
                }
            }
        }
        #expect(hits.isEmpty, """
            A real person scrubbed in #2839 has come back into this PUBLIC repository:
            \(hits.sorted().joined(separator: "\n"))
            """)
    }
}
