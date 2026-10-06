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
// #4357 slice I2: and the lookup is no longer by KEY at all. A key-only lookup finds whichever row holds
// the key, which after a merge is a survivor Dan did not press (B3), so every action now resolves the
// card's store identifier through `ShowIdentity`, which says each refusal's own cause. This guard used to
// count `prospects.first(where:` lines; it now refuses any show lookup written in this file at all,
// because the only lookup allowed is the one rule, which lives in `ShowIdentity`.
//
// Whether a stale snapshot can really outlive its model is not the point. A silent no-op cannot be
// told from a control that is broken, and if it never fires the message costs nothing (L11, L98).
@MainActor
@Suite("A control that cannot find its show says so (#1778)")
struct AControlThatFindsNothingSaysSoTests {

    // The spellings of a show lookup written by hand: a predicate on a show's key or identifier, or a
    // walk of the rows for one. A row's own recipients are walked by `recipients.first(where:` and are
    // not shows, so they are deliberately not matched.
    private static func isAShowLookup(_ code: String) -> Bool {
        code.contains("$0.naturalKey") || code.contains("persistentModelID")
            || code.contains("prospects.first") || code.contains("prospects.last")
            || code.range(of: #"naturalKey\s*=="#, options: .regularExpression) != nil
    }

    @Test func noRowActionFindsItsShowExceptThroughTheOneResolver() throws {
        let source = SourceGuardHelper.source("Overture/UI/ProspectMutations.swift")
        #expect(!source.isEmpty, "Could not read ProspectMutations.swift, so nothing was measured.")

        // Comments stripped and nothing skipped: a comment ABOUT the old lookup is how this file records
        // why it went, and must not read as the lookup coming back (L103).
        let code = SwiftSource.scannableLines(in: source, skipping: [])
        let lookups = code.filter { Self.isAShowLookup($0.code) }
            .map { "line \($0.line)  \($0.code.trimmingCharacters(in: .whitespaces))" }

        #expect(lookups.isEmpty, """
            ProspectMutations finds a show by hand. A lookup by key lands on whichever row holds the key, \
            which after a merge is a show Dan did not press (#4357 slice I2, B3), and a lookup that returns \
            silently is #1778. Resolve the card through ShowIdentity, which refuses by name.
            \(lookups.joined(separator: "\n"))
            """)

        // UNMEASURED is its own outcome (L98): a file with nothing left to find and a scan that read the
        // wrong file leave the same empty list, so the actions must be SEEN going through the helper.
        let throughTheHelper = code.filter {
            $0.code.contains("model(for: item, in: prospects, feedback: feedback)")
                || $0.code.contains("model(forKey: naturalKey, org: nil, in: prospects, feedback: feedback)")
        }.count
        #expect(throughTheHelper > 40, """
            Only \(throughTheHelper) actions resolve their show through the shared helper, so this guard \
            is reading something other than the actions it exists for.
            """)
        let helper = try #require(SourceGuardHelper.bodyOfFunction(named: "model", in: source))
        #expect(helper.contains("prospects.show(for: item, feedback: feedback)"),
                "the shared helper no longer resolves through ShowIdentity, so the actions behind it do not")
    }
}
