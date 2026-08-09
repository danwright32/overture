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
    private static let betweenMarkers = regex(#"between\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*and:\s*"((?:[^"\\]|\\.)*)""#)

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
        let text: String
        let haystack: String     // every source file this test reads, joined
    }

    private static let guardFiles: [GuardFile] = {
        var out: [GuardFile] = []
        for dir in ["OvertureTests", "OvertureHostedTests"] {
            // #2311: through the shared walk, which refuses out loud rather than handing back an
            // empty list a guard would read as a clean result.
            for file in AppSourceWalk.files(under: macRoot.appendingPathComponent(dir), floor: 20) {
                guard !buildsItsOwnText.contains(file.name) else { continue }
                guard file.text.contains("propertyBody(") || file.text.contains("between(") else { continue }
                let bodies = Set(captures(pathLiteral, in: file.text, groups: [1])).compactMap {
                    try? String(contentsOf: macRoot.appendingPathComponent($0), encoding: .utf8)
                }
                out.append(GuardFile(name: file.name, text: file.text,
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
        #expect(markers.count >= 40, "found only \(markers.count) propertyBody markers")
    }

    // 1. Every `propertyBody` marker ends at its own opening brace.
    //
    // `propertyBody` scans braces from the marker with depth already at 1, so a marker stopping short of
    // the brace begins inside the signature and does not balance until the end of the enclosing type. The
    // returned "body" is then most of the file, and a guard asking whether it CONTAINS something is
    // answered by any occurrence anywhere, while one asking whether it does NOT is answered by the whole
    // file. Either way it agrees with itself and stops depending on the code it names.
    @Test func everyPropertyBodyMarkerEndsAtItsOwnBrace() {
        for file in Self.guardFiles {
            for marker in Self.captures(Self.propertyBodyMarker, in: file.text, groups: [1]) {
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

    // 2. Every marker still matches something in the source its own test file reads.
    //
    // A marker that stops matching returns nil, spelled at the call site as `?? ""` or an optional chain,
    // and every `contains` against an empty string is false. The guard goes on passing and has stopped
    // asking anything at all.
    @Test func everyMarkerStillMatchesTheSourceItIsAskedOf() {
        for file in Self.guardFiles where !file.haystack.isEmpty {
            let markers = Self.captures(Self.propertyBodyMarker, in: file.text, groups: [1])
                + Self.captures(Self.betweenMarkers, in: file.text, groups: [1, 2])
            for marker in markers where !marker.isEmpty {
                #expect(file.haystack.contains(Self.unescape(marker)),
                        """
                        \(file.name): the marker \(marker.debugDescription) matches nothing in the source \
                        this test reads, so the guard using it is asking nothing at all. Point it at the \
                        code's current wording, or delete the guard (#2192, L1).
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
