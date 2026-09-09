import Testing
import Foundation

// #3654 CORRECTION C3: the in-app check ships in RELEASE, and that is proved rather than declared.
//
// The one instrument of this shape already in this file is `QueueRenderCounter`, and it is Debug only.
// Dan runs Release. A check that shipped behind `#if DEBUG` would be code that has never run on the only
// build that matters, and its error paths least of all, because the guard existed precisely to stop it
// executing (L535, L3).
@Suite("The card check is not Debug only (#3654)")
struct CardCheckShipsInReleaseTests {

    private var model: String { SourceGuardHelper.source("Overture/UI/QueueView+Model.swift") }

    /// Is the line naming `needle` inside an open `#if DEBUG`?
    ///
    /// ASKED THROUGH THE SKIP the scanner already has, rather than by counting directives here.
    /// `SwiftSource` blanks `#if DEBUG` regions, so the question is simply whether the line survives that
    /// skip, and there is one definition of what a DEBUG region is instead of two (L107, L263).
    ///
    /// The first version counted `#if DEBUG` and `#endif` in raw text and went red on its own
    /// explanation: the comment above the call site necessarily writes the directive in order to say the
    /// check is NOT behind one, so the assertion was answered by prose ABOUT the thing rather than by the
    /// thing, in the direction that accuses working code (L103, L135).
    ///
    /// Returns nil when the needle is not there at all, which is a different answer from false (L98).
    static func isInsideADebugBlock(_ source: String, needle: String) -> Bool? {
        let asWritten = SwiftSource.scannableLines(in: source, skipping: [])
        guard asWritten.contains(where: { $0.code.contains(needle) }) else { return nil }
        let withoutDebug = SwiftSource.scannableLines(in: source, skipping: .debug)
        return !withoutDebug.contains(where: { $0.code.contains(needle) })
    }

    @Test func theCheckIsNotInsideADebugBlock() {
        #expect(!model.isEmpty, "the source could not be read, so this measured nothing")
        let inside = Self.isInsideADebugBlock(model, needle: "checkOneCardAgainstAFreshBuild(cards: cards")
        #expect(inside != nil,
                "the check is no longer called from the builder, so this guard is about nothing (L98)")
        #expect(inside == false, Comment(rawValue:
            "the card check sits inside a `#if DEBUG` block. Dan runs Release, so it would never have "
            + "run on the only build that matters (#3654 C3, L535)."))
    }

    // The predicate, seen to answer BOTH ways, so a `false` above is a reading rather than a rule that
    // can only ever say one thing (L1, L171). Exercised on text this test writes, because the app has to
    // be free to hold no DEBUG block at all and a positive control depending on one would be asserting
    // about the app instead of about the predicate.
    @Test func thePredicateCanTellTheTwoApart() {
        let outside = ["func f() {", "#if DEBUG", "let a = 1", "#endif", "theNeedle()", "}"]
            .joined(separator: "\n")
        let inside = ["func f() {", "#if DEBUG", "theNeedle()", "#endif", "}"].joined(separator: "\n")
        // The defect this was rewritten to fix: a COMMENT naming the directive must not count as one.
        let commented = ["func f() {", "// never behind a #if DEBUG, because Dan runs Release",
                         "theNeedle()", "}"].joined(separator: "\n")

        #expect(Self.isInsideADebugBlock(outside, needle: "theNeedle()") == false)
        #expect(Self.isInsideADebugBlock(inside, needle: "theNeedle()") == true)
        #expect(Self.isInsideADebugBlock("func f() {}", needle: "theNeedle()") == nil)
        #expect(Self.isInsideADebugBlock(commented, needle: "theNeedle()") == false)
    }

    // The other half, one file over: the pass hands the result out and the VIEW writes it. The pass may
    // not reach the filesystem, which `QueueRenderPassIsPureTests` holds it to, so a check that wrote its
    // own record would break that rule rather than this one.
    @Test func thePassReportsTheCheckAndTheViewWritesIt() {
        let pass = SourceGuardHelper.source("Overture/UI/QueueRenderPass.swift")
        let view = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(pass.contains("cardCheck: scope.cardCheck"),
                "the pass no longer reports what its check found, so nothing can record it")
        #expect(!pass.contains("CardDivergenceLog"), Comment(rawValue:
            "the render pass reaches the divergence log directly. It may not touch the filesystem, which "
            + "is what makes its cost measurable at all (#1913)."))
        #expect(view.contains("CardDivergenceLog.append(record"),
                "nothing writes a divergence, so the file the reader opens can only ever be empty")
    }
}
