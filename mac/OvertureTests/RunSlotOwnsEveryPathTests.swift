import Testing
import Foundation

// #2763 (phase 1 of #2620): `RunSlot` is only worth having if it is the ONLY place that knows these
// names. A second literal somewhere is a file the check will still share with the prep run after the two
// are meant to be separable, and it will look exactly like working code.
//
// Derived from the source rather than from a list of the places somebody remembered to change, because a
// hand-written registry only ever checks the entries that are already safe (L96). The first draft of this
// plan carried such a list and it had already missed the two FIFOs, the chunk logs and the run log.
@Suite("Only RunSlot names a run's files (#2763)")
struct RunSlotOwnsEveryPathTests {

    // The fragments that name a run file. Anchored to `appendingPathComponent(` so this cannot fire on a
    // comment or a doc string that merely mentions one (L103).
    static let forbidden = [
        #"appendingPathComponent("prep"#,
        #"appendingPathComponent("check"#,
        #"appendingPathComponent("overture-prep"#,
        #"appendingPathComponent("overture-check"#,
    ]

    // RunSlot builds these names by interpolating its own raw value, so it holds no literal to match and
    // needs no exemption. Kept as a named constant anyway: the day somebody writes one out longhand in
    // there, this is the line to reach for rather than an allowlist somewhere else.
    static let owner = "RunSlot.swift"

    // The scan, as a function, so the guard below and the control beneath it are the SAME code. A control
    // that exercised a second copy of the matcher would only prove the copies agree (L70).
    static func offenders(in source: String, named name: String) -> [String] {
        var found: [String] = []
        for (i, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let code = String(line)
            guard !code.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            for fragment in forbidden where code.contains(fragment) {
                found.append("\(name):\(i + 1)  \(code.trimmingCharacters(in: .whitespaces))")
            }
        }
        return found
    }

    @Test("no file but RunSlot builds a run file's path")
    func onlyRunSlotNamesThem() throws {
        let files = AppSourceWalk.urls(under: RepoRoot.app)
        #expect(!files.isEmpty, "a wrong path here would walk nothing and pass over everything")

        var offenders: [String] = []
        for file in files where file.lastPathComponent != Self.owner {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            offenders += Self.offenders(in: text, named: file.lastPathComponent)
        }
        #expect(offenders.isEmpty, """
            A run file's name is built outside RunSlot. Route it through the slot instead, or the check \
            and the prep run keep sharing it:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // The control. A guard that reports "no offenders" is indistinguishable from one whose fragments
    // match nothing at all, and the second is what a rename produces. So the matcher is shown catching
    // the real shape and leaving prose alone, every run.
    //
    // Written after the first version of this control failed honestly: it asserted the fragments appear
    // in RunSlot.swift, which they never will, because RunSlot interpolates its raw value rather than
    // spelling the names out.
    @Test("the scan catches the real shape and leaves prose alone")
    func theScanStillWorks() {
        let live = """
            enum Somewhere {
                static var url: URL { dir.appendingPathComponent("prep-running") }
                static var two: URL { dir.appendingPathComponent("overture-check-results.json") }
            }
            """
        #expect(Self.offenders(in: live, named: "Fake.swift").count == 2)

        let prose = """
            // The marker used to be dir.appendingPathComponent("prep-running") before #2763 moved it.
            enum Somewhere {}
            """
        #expect(Self.offenders(in: prose, named: "Fake.swift").isEmpty,
                "a comment about the old code is not the old code")
    }
}
