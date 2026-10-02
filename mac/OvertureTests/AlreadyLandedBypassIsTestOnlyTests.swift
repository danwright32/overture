import Testing
import Foundation

// #4336 (A7): the already-landed check has a seam, and the seam must be reachable from test code only.
//
// A probe that re-lands one frozen results file every round needs past the check, or every round after the
// first measures a refusal (the 2026-09-29 decision on the issue). So the check is a parameter whose
// default is the real lookup, and `AlreadyLandedCheck.bypassedForMeasurement` lets a probe through. Passed
// anywhere in the app, it would let the reattach path land the same results twice, which is the defect A7
// exists to stop, and nothing would say so. Likewise a check BUILT in the app (`AlreadyLandedCheck {`) can
// be a bypass under another name.
//
// The second half: the ingest only knows the results' identity when its caller hands it one, and only
// `ScoutExtractLanding` holds the bytes the identity is the hash of. A call to the ingest anywhere else in
// the app would land a file with no check at all.
@Suite("The already-landed bypass is reachable from tests only (#4336)")
struct AlreadyLandedBypassIsTestOnlyTests {
    static let declaringFile = "ScoutExtractLanding.swift"

    // The calls the app may not make outside the declaring file, by the code they are written as.
    static let forbidden = ["bypassedForMeasurement", "AlreadyLandedCheck {", "AlreadyLandedCheck(",
                            "ScoutExtractIngest.ingest("]

    static func findings(in text: String, file: String) -> [String] {
        guard file != declaringFile else { return [] }
        let code = SwiftSource.tokenize(text).codeLines
        return code.keys.sorted().flatMap { line in
            forbidden.filter { code[line]!.contains($0) }.map { "\(file):\(line) \($0)" }
        }
    }

    @Test func noAppFileOutsideTheLandingNamesTheBypassOrCallsTheIngest() {
        let found = AppSourceWalk.appFiles().flatMap { Self.findings(in: $0.text, file: $0.name) }
        #expect(found.isEmpty, Comment(rawValue: "used outside \(Self.declaringFile): \(found)"))
    }

    // The scan is seen to find each shape it forbids, and to ignore a comment or a string naming it.
    @Test func theScanFindsEachForbiddenShapeAndIgnoresCommentsAndStrings() {
        for shape in Self.forbidden {
            #expect(!Self.findings(in: "let x = \(shape)", file: "RootView.swift").isEmpty,
                    Comment(rawValue: "missed \(shape)"))
            #expect(Self.findings(in: "let x = \(shape)", file: Self.declaringFile).isEmpty)
        }
        #expect(Self.findings(in: "// bypassedForMeasurement\nlet s = \"ScoutExtractIngest.ingest(\"",
                              file: "RootView.swift").isEmpty)
    }
}
