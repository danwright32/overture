import Testing
import Foundation

// #3743 widened `QueueModel.inheritedAnswers` from `private` to internal so the cost instrument could
// time it. This is what that widening rests on.
//
// WHY IT EXISTS. Making a whole-corpus derivation reachable is a real change even when nothing calls it:
// the next caller can now appear without anything saying so, and it walks the UNFILTERED store (dismissed
// shows included, deliberately, per #1598) and reads the stored ledger. One caller is a pass paying for it
// once; two is a pass paying twice, which is the exact defect #3743 was filed to remove one layer up.
//
// THE COMMENT THAT NAMED THIS SUITE SHIPPED BEFORE THE SUITE DID. `QueueView+Model.swift` said "Nothing
// else calls it, and `ScopeCallsTheLedgerOnceTests` asserts that, so widening the access has not widened
// what can happen", and that was false: the claim was held by the comment alone, which is precisely what
// a comment cannot hold (L407). Found by sweeping every test name the app's sources mention, which turned
// up five such claims and is now `EveryNamedTestExistsTests`.
@Suite("Only the render pass asks the organisation ledger (#3743)")
struct ScopeCallsTheLedgerOnceTests {

    /// Call sites in the app's own sources, which is everything but the declaration itself.
    private func callSites() -> [(file: String, line: Int)] {
        var out: [(String, Int)] = []
        for source in AppSourceWalk.appFiles() {
            for (index, line) in source.text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard code.contains("inheritedAnswers(") else { continue }
                // The declaration is not a call, and neither is a comment ABOUT the call, which is the
                // shape that makes a source guard answer about prose rather than code (L103).
                guard !code.contains("static func inheritedAnswers("), !code.hasPrefix("//") else { continue }
                out.append((source.name, index + 1))
            }
        }
        return out
    }

    @Test("exactly one caller, and it is the render pass's own derivation")
    func onlyScopeCallsIt() {
        let sites = callSites()

        #expect(sites.count == 1,
                Comment(rawValue: "`inheritedAnswers` has \(sites.count) callers: "
                        + "\(sites.map { "\($0.file):\($0.line)" }.joined(separator: ", ")). It walks the "
                        + "unfiltered store and reads the stored ledger, so a second caller is a second "
                        + "whole-corpus derivation per pass. It is internal only so the cost instrument "
                        + "can time it (#3743); if a second caller is wanted, hand it the answer the pass "
                        + "already derived rather than asking again."))

        #expect(sites.first?.file == "QueueView+Model.swift",
                Comment(rawValue: "the one caller is \(sites.first?.file ?? "nowhere"), not "
                        + "`QueueView+Model.swift`. The ledger is derived inside `QueueModel.scope` and "
                        + "handed down; a caller anywhere else is deriving it a second time."))
    }

    // And the declaration is still reachable from a test at all, so the suite above cannot pass because
    // the function was renamed out from under it (L100: an operation that finds its target by matching
    // text reports success when it matches nothing).
    @Test("the function this is about still exists under that name")
    func theFunctionStillExists() {
        let model = SourceGuardHelper.source("Overture/UI/QueueView+Model.swift")
        #expect(model.contains("static func inheritedAnswers("),
                "`inheritedAnswers` is gone or renamed, so the guard above is matching nothing")
    }
}
