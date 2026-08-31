import Testing
import Foundation

// #3269 / #3270: a suite that TOUCHES one of the process-global stubs actually carries that stub's lock.
//
// WHY THIS EXISTS BESIDE the shell check. `scripts/check-test-shared-state.sh` finds the shared state
// itself and asks whether anybody has accounted for it, and its baseline records the answer in PROSE:
// "held by .sharesTheCarnegieStub". Nothing verified that sentence was still true. A suite that loses
// its trait in a refactor goes back to failing once in four parallel runs, silently, while the baseline
// goes on reading as an answered question, which is the shape of a guard defending nothing (L46, L96).
//
// WHY IT IS DERIVED rather than a list. The subjects are every file that MENTIONS the stub type, so a
// new suite reaching for `PageStubURLProtocol` next year is covered by a guard it never heard of. A
// hand-written list only ever checks what somebody remembered, and the one it forgets is the new one,
// which is exactly the case #3269 was: `StubURLProtocol` in CarnegieExtractorTests had the identical
// shape as `PageStubURLProtocol` and was missed because #3234 enumerated the failures it had SEEN.
//
// WHY `.serialized` IS NOT ACCEPTED as the answer. It orders a suite's own tests against each other,
// and the interference comes from OTHER suites: `SourceFetcherTests` carried `.serialized` and still
// failed in the first parallel run. This guard therefore ignores it entirely.
@Suite("Every suite touching process-global test state carries that state's lock (#3269)")
struct SharedStateWiringTests {

    // The families, each as the stub's own type name and the trait that locks it. The stub NAMES are
    // the derivation's input, and the trait names are what the assertion looks for; both are checked
    // against SharedStateTestLock.swift below, so a family renamed in one place and not the other is a
    // failure rather than a guard that quietly stops matching anything.
    private static let families: [(stub: String, trait: String)] = [
        ("PageStubURLProtocol", "sharesTheNetworkStub"),
        ("StubURLProtocol", "sharesTheCarnegieStub"),
        ("QueueRenderCounter", "sharesTheRenderCounter"),
        // #3272: matched as `ResponseDecodeFailures.shared` rather than as the type, because the type is
        // also used to build a PRIVATE register (`ResponseDecodeFailures()`), which is the correct thing
        // to do and needs no lock. Only the singleton is process-wide.
        ("ResponseDecodeFailures.shared", "sharesTheDecodeFailureRegister"),
    ]

    // Prose is not a use. `SourceFetcherTests.swift` says in a COMMENT that its stub is "distinct from
    // CarnegieExtractorTests' StubURLProtocol", and a reader that counted that demanded the file carry a
    // trait it must not have: the guard's first run failed on exactly that sentence. Stripped from the
    // first `//` that is not part of a `://`, so a URL in a comment does not swallow the rest of a line.
    static func code(in text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let characters = Array(line)
            var index = 0
            while index + 1 < characters.count {
                if characters[index] == "/" && characters[index + 1] == "/" {
                    if index > 0 && characters[index - 1] == ":" { index += 1; continue }
                    return String(characters[0..<index])
                }
                index += 1
            }
            return String(line)
        }.joined(separator: "\n")
    }

    private static var testFiles: [AppSourceWalk.File] {
        AppSourceWalk.files(under: RepoRoot.mac.appendingPathComponent("OvertureTests"), floor: 200)
    }

    // The stub type is matched as a WHOLE WORD, because `StubURLProtocol` is a suffix of
    // `PageStubURLProtocol`: without this every file using the network stub would read as a user of the
    // Carnegie one too, and the guard would demand a trait those files must not have.
    private static func mentions(_ symbol: String, in text: String) -> Bool {
        text.ranges(of: symbol).contains { range in
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            let isWordCharacter: (Character?) -> Bool = { c in
                guard let c else { return false }
                return c.isLetter || c.isNumber || c == "_"
            }
            return !isWordCharacter(before) && !isWordCharacter(after)
        }
    }

    @Test func everyTraitTheGuardLooksForIsOneThatExists() throws {
        let lock = SourceGuardHelper.source("OvertureTests/SharedStateTestLock.swift")
        #expect(lock.count > 500, "SharedStateTestLock.swift did not read, so nothing below is measuring anything")
        for family in Self.families {
            #expect(lock.contains("static var \(family.trait):"),
                    "\(family.trait) is not declared in SharedStateTestLock.swift, so no suite can carry it and this guard would pass by never matching")
        }
    }

    @Test func everySuiteTouchingAStubCarriesItsLock() throws {
        let files = Self.testFiles
        #expect(files.count > 200, "walked \(files.count) files, which is a broken path rather than a small test target")

        var subjectsExamined = 0
        var missing: [String] = []

        for family in Self.families {
            for file in files {
                // The lock's own file names every stub in its documentation, and is not a suite.
                if file.name == "SharedStateTestLock.swift" || file.name == "SharedStateWiringTests.swift" { continue }
                guard Self.mentions(family.stub, in: Self.code(in: file.text)) else { continue }
                guard file.text.contains("@Suite") else { continue }
                subjectsExamined += 1
                // #3272: the TRAIT is looked for in the code too, not in the raw text. A comment naming
                // the trait satisfied this, which is the same "prose is not a use" rule the line above
                // already applies to the stub, applied to only one of the two halves. Found by mutation:
                // removing the trait from a suite declaration whose own comment explains the trait was
                // reported SURVIVED (L135).
                if !Self.code(in: file.text).contains(".\(family.trait)") {
                    missing.append("\(file.name) touches \(family.stub) and does not carry .\(family.trait)")
                }
            }
        }

        // Zero subjects is UNMEASURED, not clean: a renamed stub would empty the corpus and this guard
        // would report a perfectly wired tree while checking nothing (L98).
        #expect(subjectsExamined >= 5,
                "examined \(subjectsExamined) suite files, which is too few to be measuring the families this guard names: a stub was probably renamed")
        #expect(missing.isEmpty, "\(missing.joined(separator: "; "))")
    }
}
