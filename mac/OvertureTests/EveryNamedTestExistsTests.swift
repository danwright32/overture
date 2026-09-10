import Testing
import Foundation

// A comment that names a test must name one that exists.
//
// WHAT THIS IS ABOUT. A comment saying "`XTests` holds this" is read by everyone afterwards as a
// constraint somebody enforced. Where `XTests` does not exist, the comment is enforced by nothing while
// reading as binding, which is the worst of both: the next person believes the coverage is there and
// does not write it (L407, L32).
//
// FOUND BY SWEEPING, 2026-09-10, and it was not one instance. Five names in `mac/Overture` named no test
// type anywhere:
//
//   `ConflictPillColourTests`      said it "measures both, so this cannot silently regress"
//   `FormOutreachFinalityTests`    said it "holds that decision now, in behaviour rather than in this
//                                  comment", while the decision was held in that comment
//   `SystemSleepMeasurementTests`  a pointer that went nowhere
//   `VenueBrandsFromACorpusTests`  the check exists under another name
//   `ScopeCallsTheLedgerOnceTests` the check did not exist at all, and the comment used it to justify
//                                  widening a function's access
//
// Every one is now repointed at the real test, whose coverage was read before repointing, because
// repointing at a test that does not cover the claim is the same defect with a different name.
//
// A FILE NAME IS ACCEPTED as well as a type name. `QueueGeoFilterTests` is a file holding
// `QueueGeoFilterCountTests`, `QueueGeoFilterHideTests` and `QueueGeoFilterKeepTests`, and a comment
// pointing at the file is a true and useful pointer. Refusing it would make the guard fire on a correct
// comment, which is how a guard gets switched off (L93).
@Suite("A comment that names a test names one that exists")
struct EveryNamedTestExistsTests {

    // Test TYPES, from both targets and the shared support, derived from the tree rather than listed
    // (L96). A list would only ever check what somebody remembered.
    // #3113's floor, applied ONCE to the total rather than per root.
    //
    // The three roots are wildly different sizes (about 950 files, about 60, and 19), so a per-root floor
    // has to be pushed down to the smallest to pass at all, and a floor of 1 is low enough to pass on a
    // broken path, which is the protection the floor exists to be. `files(underAll:floor:)` exists for
    // exactly this and the guard-on-the-guard names it: it took two attempts here, and the first was
    // refused with that sentence.
    private static let testFileFloor = 500

    private func testSources() -> [AppSourceWalk.File] {
        AppSourceWalk.files(
            underAll: ["OvertureTests", "OvertureHostedTests", "TestSupport"]
                .map { RepoRoot.mac.appendingPathComponent($0) },
            floor: Self.testFileFloor)
    }

    private func declaredTestTypes() -> Set<String> {
        var out: Set<String> = []
        do {
            for source in testSources() {
                for line in source.text.components(separatedBy: "\n") {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    for keyword in ["struct ", "final class ", "class ", "enum "] {
                        guard code.hasPrefix(keyword) else { continue }
                        let name = code.dropFirst(keyword.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                        if name.hasSuffix("Tests") { out.insert(String(name)) }
                    }
                }
            }
        }
        return out
    }

    // And the file names, for the pointer-at-a-file case above.
    private func testFileNames() -> Set<String> {
        Set(testSources()
            .map { $0.name.replacingOccurrences(of: ".swift", with: "") }
            .filter { $0.hasSuffix("Tests") })
    }

    /// Every identifier in the app's own sources that LOOKS like a test type: initial capital, ending in
    /// `Tests`. The capital is what keeps `isRunningUnderTests` and `underTests`, which are ordinary
    /// variables, out of the sweep; without it the guard reports its own false positives and gets
    /// switched off (L93).
    private func namesClaimedInAppSources() -> [(name: String, at: String)] {
        var out: [(String, String)] = []
        for source in AppSourceWalk.appFiles() {
            for (index, line) in source.text.components(separatedBy: "\n").enumerated() {
                var current = ""
                for character in line + " " {
                    if character.isLetter || character.isNumber || character == "_" {
                        current.append(character)
                    } else {
                        // LONGER than the bare word, which is the second false positive this sweep
                        // produced: `Tests` on its own appears in ordinary prose in the app's comments
                        // and names no type. A guard that reports its own noise is one that gets
                        // switched off (L93).
                        if current.hasSuffix("Tests"), current.count > "Tests".count,
                           current.first?.isUppercase == true {
                            out.append((current, "\(source.name):\(index + 1)"))
                        }
                        current = ""
                    }
                }
            }
        }
        return out
    }

    @Test("every test named in the app's own sources exists")
    func everyNamedTestExists() {
        let types = declaredTestTypes()
        let files = testFileNames()
        let claimed = namesClaimedInAppSources()

        // Floors first, because an empty reading of either side passes trivially and the emptiest
        // possible failure must not read as the cleanest possible pass (L98).
        #expect(types.count >= 900,
                Comment(rawValue: "read only \(types.count) test types, so this checked almost nothing"))
        #expect(claimed.count >= 20,
                Comment(rawValue: "found only \(claimed.count) test names in the app's sources, which is "
                        + "too few to have swept them"))

        let missing = claimed.filter { !types.contains($0.name) && !files.contains($0.name) }
        let described = missing.map { "\($0.name) at \($0.at)" }.sorted().joined(separator: "; ")
        #expect(missing.isEmpty,
                Comment(rawValue: "these comments name a test that does not exist: \(described). A comment "
                        + "saying a check holds something is read as a constraint somebody enforced; where "
                        + "the check is not there it is enforced by nothing while reading as binding "
                        + "(L407). Point it at the real test, having first read that the real test covers "
                        + "the claim."))
    }

    // The sweep must actually be finding the ordinary case, or it could be matching nothing and passing.
    // Named references are common in this codebase and a handful of known-good ones are asserted present.
    @Test("the sweep finds the references that are correct")
    func theSweepIsNotVacuous() {
        let names = Set(namesClaimedInAppSources().map(\.name))
        // Two long standing references the app's own sources really do make. The first attempt named
        // `CopyInventoryTests`, which the app does NOT name, so the control failed and said so: that is
        // the check working, and it is why a non-vacuity control is asserted rather than assumed.
        for known in ["QueueInvalidationGuardTests", "QueueRenderPassCostTests"] {
            #expect(names.contains(known),
                    Comment(rawValue: "the sweep did not find \(known), which the app's sources do name, "
                            + "so it is not reading what it thinks it is"))
        }
    }
}
