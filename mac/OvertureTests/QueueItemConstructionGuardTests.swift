import Testing
import Foundation

// #1700: the card's construction stays checkable.
//
// `QueueItem(_:sendGroups:)` is one memberwise call with about sixty arguments. Adding a single field to
// it in #1680 failed with "the compiler is unable to type-check this expression in reasonable time",
// which names no field and suggests no cause, so it reads as a broken toolchain rather than as one
// oversized expression. The workaround was to assign that field AFTER the init, and #2395 did the same,
// which left the file with two conventions for one job.
//
// Sixteen computed arguments are hoisted into locals above the call now, each its own small expression.
// MEASURED 2026-08-21: with them out, a new argument added to the call compiles; with them inline it did
// not. What that does NOT buy is room for three at once, so the two conventions are still there, and the
// comment at the call says so with the measurement rather than a guess.
//
// This guards the part that was bought. A closure put back inline would spend the headroom silently, and
// the next person would meet the same nameless error.
@Suite("The card's construction stays checkable (#1700)")
struct QueueItemConstructionGuardTests {
    private var source: String { SourceGuardHelper.source("Overture/UI/QueueView+Model.swift") }

    // The memberwise call itself: from `self.init(` inside the two-argument initializer to its closing
    // line. Read by markers rather than line numbers, which move.
    private func memberwiseCall(in text: String) -> String? {
        guard let start = text.range(of: "init(_ p: Prospect, sendGroups: SendGroup.CardGroups) {") else {
            return nil
        }
        let rest = text[start.upperBound...]
        guard let callStart = rest.range(of: "self.init(") else { return nil }
        guard let callEnd = rest[callStart.upperBound...].range(of: "\n        )") else { return nil }
        return String(rest[callStart.upperBound..<callEnd.lowerBound])
    }

    @Test func theGuardCanFindTheCallItJudges() {
        let text = source
        #expect(!text.isEmpty, "the guard read no source, so everything below passes on nothing")
        let call = memberwiseCall(in: text)
        #expect(call != nil, "the construction moved, so this guard is reading nothing")
        // Non-vacuous: the call really is the big one, not some small initializer that happens to match.
        #expect((call ?? "").components(separatedBy: "\n").count > 40)
    }

    // THE property. A closure inside the call is what the hoisting removed, and putting one back spends
    // the headroom without anything saying so until somebody adds a field and meets the nameless error.
    @Test func noClosureIsInlineInTheMemberwiseCall() throws {
        let call = try #require(memberwiseCall(in: source))

        for marker in ["{ $0", "{ p.", "contains {", "filter {", "first {", "flatMap {", "map {"] {
            #expect(!call.contains(marker),
                    Comment(rawValue: "a closure is back inline in the card's construction (\(marker)). "
                            + "Hoist it into a local above the call, as the sixteen others are: that is "
                            + "what keeps a new field from meeting a compiler error naming nothing."))
        }
    }

    // And the hoisted locals really are there, so the guard above cannot pass by the call having been
    // deleted or emptied rather than by the rule holding.
    @Test func thehoistedLocalsAreWhereTheyBelong() {
        let text = source
        for name in ["let offersSendModeChoice =", "let draftLintBlockers =", "let draftGreetedName =",
                     "let hasAnyEmailContact =", "let formPitch ="] {
            #expect(text.contains(name),
                    Comment(rawValue: "\(name) is gone, so its expression is back inside the call or the "
                            + "field is gone entirely"))
        }
    }
}
