import Testing
import Foundation

// #1778. Every row action in `ProspectMutations` begins by finding the show behind the row Dan
// pressed. Fifty of them did it inline and returned silently when it found nothing:
//
//     guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
//
// So the control is offered, Dan presses it, and nothing happens with nothing said. That is this
// issue's own test ("is there an input for which this control is shown and pressing it changes
// nothing") answered yes, fifty times over, by a route the issue did not name: it expected a DOMAIN
// rule refusing, and this is the lookup itself.
//
// The refusals BESIDE it already say their piece. `recordOutcome` guards the outcome menu and
// acknowledges `ShowOutcome.refusedLine` when the rule declines. Only the lookup was silent, and it is
// the one every action shares, so one helper covers all fifty (L30).
//
// Whether a stale snapshot can really outlive its model is not the point. A silent no-op cannot be
// told from a control that is broken, and if it never fires the message costs nothing (L11, L98).
@MainActor
@Suite("A control that cannot find its show says so (#1778)")
struct AControlThatFindsNothingSaysSoTests {

    // Reads rather than actions: they return data to draw with, not the result of a press, so a nil is
    // an ordinary answer and there is no acknowledgement to make. Named, with the reason, rather than
    // pattern matched, because an unnamed exemption is one nobody reasoned about (L233).
    private static let readsNotActions = ["manualPrepPrefill"]

    // An `if let` is a BRANCH, not a silent return: the code carries on down another path that was
    // chosen on purpose. `dismissForReason` is the one, and its comment says exactly that ("this falls
    // through to exactly today's behaviour in every case that is not a live multi-night run"). Speaking
    // there would announce an ordinary path as a failure, which is the opposite defect (L11).
    private static let branchesRatherThanReturns = ["dismissForReason"]

    @Test func noRowActionLooksUpItsShowWithoutSayingWhenItFindsNothing() throws {
        let source = SourceGuardHelper.source("Overture/UI/ProspectMutations.swift")
        #expect(!source.isEmpty, "Could not read ProspectMutations.swift, so nothing was measured.")

        let lines = source.components(separatedBy: "\n")
        var enclosing = ""
        var bare: [String] = []
        var viaHelper = 0
        for (index, line) in lines.enumerated() {
            if let match = line.range(of: "static func ") {
                enclosing = String(line[match.upperBound...].prefix { $0.isLetter || $0.isNumber })
            }
            guard line.contains("prospects.first(where:") else { continue }
            // The helper itself is the one place allowed to do it.
            if enclosing == "model" { viaHelper += 1; continue }
            if Self.readsNotActions.contains(enclosing) { continue }
            // Only the guard form is the defect. See branchesRatherThanReturns above.
            guard line.contains("guard let model =") else {
                #expect(Self.branchesRatherThanReturns.contains(enclosing), """
                    \(enclosing) looks up its show outside a guard and is not a declared branch. \
                    Say which it is: a branch that carries on, or an action that must speak (#1778).
                    """)
                continue
            }
            bare.append("\(enclosing)  (line \(index + 1))  \(line.trimmingCharacters(in: .whitespaces))")
        }

        // UNMEASURED is its own outcome: a file that could not be scanned and a file with nothing left
        // to find leave the same empty result (L98).
        #expect(viaHelper > 0, """
            No lookup goes through the shared helper, so this guard measured nothing. Either the helper \
            is gone or this scan is reading the wrong file.
            """)

        #expect(bare.isEmpty, """
            A row action finds its show inline and returns silently when it cannot. Dan presses the \
            control and nothing happens, with nothing said, which is indistinguishable from a broken \
            control (#1778, L11). Go through the shared helper, which says so.
            \(bare.joined(separator: "\n"))
            """)
    }
}
