import Testing
import Foundation

// #4197: a view that draws the action banner must not READ the banner's state on its render path.
//
// WHAT WAS MEASURED, which is why this is the guard rather than a memo on every sheet. #4197 set out to
// memoise four sheets (Follow-ups, Days off, Skipped towns, Struck addresses) on the premise that raising
// a banner re-derived each of them. `ABannerDerivesNothingOnAnySheetTests` took the reading first, hosting
// the real types, and a banner cost every one of them ZERO derivations. The
// banner is drawn by a `ViewModifier` that reads `ActionFeedback` in its OWN body, so a message
// invalidates the modifier and never the sheet beneath it.
//
// The one thing that breaks that isolation is the sheet itself reading the feedback object's observed
// state while its body is evaluated: SwiftUI's observation then subscribes the WHOLE body, derivation and
// all, to every message. Seen: adding `let _ = feedback.revision` to the Follow-ups body turned that
// suite's zero into one derivation per banner. So the defect class is a read, and a read is something a
// scan can find, where a memo on each surface would be machinery protecting against nothing (the issue's
// own warning).
//
// ENUMERATED FROM THE CODE: every file applying `.actionFeedbackBanner(` is a subject, so a banner added
// to a new surface next month is checked on the run after it is written (L96).
//
// WHAT THIS CANNOT SEE, stated so a green run is not read as more than it is (L400). It matches the
// observed properties by the name `feedback.`, which is what every banner surface calls its
// `ActionFeedback` today; one held under another name would be invisible. And it cannot tell a read in
// the body from a read inside a button's action closure, which runs at click time and subscribes nothing.
// None exists today, so it flags both, and a closure read that trips it is a false positive to move into
// a helper function rather than a reason to widen the rule.
@Suite("A banner surface never reads its banner's state on its render path (#4197)")
struct ABannerSurfaceNeverReadsItsBannerGuardTests {

    private static let appRoot = RepoRoot.mac.appendingPathComponent("Overture")
    // The file DECLARING the banner, which is the one place that is supposed to read it.
    private static let bannerDeclaration = "ActionFeedbackBanner.swift"

    // Every property of `ActionFeedback` the banner's own body observes. A read of any of them inside a
    // sheet's body subscribes that body to the banner.
    static let observed = ["revision", "message", "tone", "action", "topBanner"]

    // Written as the reason plus its issue, never a bare name (L233, L65). Delete the entry when the issue
    // closes; `exemptionsStillHaveSomethingToExempt` fails the day it stops being needed.
    // Empty since #4247 removed the one read it held (SourcesView's Debug trace). Kept as the place a
    // future exemption would go, with its reason, rather than deleted along with its last entry.
    static let exempt: [String: String] = [:]

    /// The finding, as a pure function over (file name, source), so it can be PRODUCED by a test rather
    /// than only watched not to happen (L151).
    static func offenders(in files: [(name: String, text: String)]) -> [String] {
        let pattern = #"\bfeedback\.("# + observed.joined(separator: "|") + #")\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ["the pattern did not compile"] }
        var found: [String] = []
        for file in files where file.name != bannerDeclaration {
            // Debug regions are NOT skipped: the test suite runs the Debug build, and a Debug-only read
            // subscribes the body there exactly as a shipped one would.
            let lines = SwiftSource.scannableLines(in: file.text, skipping: [.previews])
            guard lines.contains(where: { $0.code.contains(".actionFeedbackBanner(") }) else { continue }
            for (line, code) in lines {
                let range = NSRange(code.startIndex..., in: code)
                if regex.firstMatch(in: code, range: range) != nil {
                    found.append("\(file.name):\(line)")
                }
            }
        }
        return found
    }

    private static func appFiles() -> [(name: String, text: String)] {
        AppSourceWalk.files(under: appRoot).map { ($0.name, $0.text) }
    }

    @Test func theRuleFindsAReadInABannerSurface() {
        let surface = """
            struct S: View {
                var body: some View {
                    let _ = feedback.revision
                    Text("x").actionFeedbackBanner()
                }
            }
            """
        let noBanner = """
            struct T: View {
                var body: some View { Text("\\(feedback.message ?? "")") }
            }
            """
        let commented = """
            struct U: View {
                // feedback.revision is read by the banner, not here
                var body: some View { Text("x").actionFeedbackBanner() }
            }
            """
        let found = Self.offenders(in: [("S.swift", surface), ("T.swift", noBanner), ("U.swift", commented)])
        #expect(found == ["S.swift:3"], Comment(rawValue:
            "the rule reported \(found): it must name the read in the banner surface and nothing in a "
            + "file with no banner or in a comment (#4197, L1)"))
    }

    @Test func noBannerSurfaceReadsItsBannerOnItsRenderPath() {
        let files = Self.appFiles()
        let surfaces = files.filter { $0.text.contains(".actionFeedbackBanner(") && $0.name != Self.bannerDeclaration }
        // Cannot pass vacuously: a walk that found no banner surface measured nothing (L98).
        #expect(surfaces.count >= 5, Comment(rawValue:
            "only \(surfaces.count) file(s) apply .actionFeedbackBanner(, fewer than the app has, so "
            + "nothing below was measured (L98)"))

        let offenders = Self.offenders(in: files)
            .filter { Self.exempt[String($0.prefix { $0 != ":" })] == nil }
        #expect(offenders.isEmpty, Comment(rawValue:
            "\(offenders.joined(separator: ", ")) read ActionFeedback's observed state in a view that "
            + "draws the banner. That subscribes the whole body, and whatever it derives, to every "
            + "message shown over it: measured on Follow-ups as one derivation per banner (#4197). Read "
            + "it inside an action instead, or let the banner modifier be the only reader."))
    }

    @Test func exemptionsStillHaveSomethingToExempt() {
        let flagged = Set(Self.offenders(in: Self.appFiles()).map { String($0.prefix { $0 != ":" }) })
        for (file, reason) in Self.exempt {
            #expect(flagged.contains(file), Comment(rawValue:
                "\(file) is exempted because \(reason), and it no longer reads the banner's state, so "
                + "the exemption covers nothing: delete it (L233)"))
        }
    }
}
