import Testing
import Foundation

// #3813: a stall while only RootView rebuilds no longer reads as a surface that stood still.
//
// Two views draw under `.queue`: `RootView` and the `QueueView` inside it. Only the second bumps
// `passes`, because SwiftUI re-evaluates `QueueView` only when a value `RootView` hands it changes. So a
// `RootView` evaluation that changes none of them rebuilds the window and bumps nothing, and a stall
// spanning only those reads `passes: 0`, which under that field's documented meaning says the surface did
// not rebuild. That is the reading that refutes the burst explanation and sends the next diagnosis
// elsewhere (L11).
//
// WHAT THIS DOES NOT CLAIM. How often `RootView` evaluates without `QueueView` following is still
// unmeasured; #3813 asked for that population first, and it cannot be had without a counter that survives
// into a real session. This is that counter, recorded BESIDE `passes` and never into it, so the 1,041
// records already written stay comparable with every one written after (L683).
@Suite("RootView counts its own draws, beside the surface's passes (#3813)")
struct RootViewCountsItsOwnDrawsTests {

    // THREE VALUES, the same vocabulary `passes` uses: absent is unmeasured, 0 is none counted, N is the
    // count. A zero standing for both would make "the window did not rebuild" and "nobody counted"
    // one answer, which is the whole defect one field along (L98, L11).
    @Test func aRecordWrittenNowCarriesACountAndAnOlderOneCarriesNothing() throws {
        let counted = StallRecord(session: "s", sequence: 1, at: Date(timeIntervalSince1970: 0),
                                  seconds: 1, surface: .queue, load: .baseline, loadAverage: nil,
                                  passes: 0, rootDraws: 3)
        #expect(counted.rootDraws == 3)
        #expect(counted.passes == 0, "the two are recorded side by side, not added together")

        let json = """
            {"session":"s","sequence":9,"at":"2026-09-01T00:00:00Z","seconds":4.5,"surface":"queue",\
            "load":"baseline","passes":0}
            """
        let older = try FreezeLog.decoder().decode(StallRecord.self, from: Data(json.utf8))
        #expect(older.rootDraws == nil, "a record from before #3813 says nothing, which is not zero")
        #expect(older.passes == 0)
    }

    // The span rule is the one `passes` already uses, and it is REUSED rather than re-spelled: two
    // readings of the same question would eventually disagree about what an absent count means (L263).
    @Test func theSpanIsCountedTheSameWayThePassesAre() {
        #expect(StallLog.passesSpanned(from: 2, to: 5) == 3)
        // Nothing has ever been counted in this process, so the span cannot say.
        #expect(StallLog.passesSpanned(from: nil, to: nil) == nil)
        // The counter started during the stall, so everything it holds happened inside it.
        #expect(StallLog.passesSpanned(from: nil, to: 4) == 4)
        // A count that went BACKWARDS is not a span.
        #expect(StallLog.passesSpanned(from: 9, to: 2) == nil)
    }

    // The wiring, which is the half no runtime test in this target can reach: `RootView.body` is a view
    // body and the watch is a `@State` on it. What is asserted is that the bump is there, that it is the
    // ROOT one rather than a second surface pass, and that it is not hidden behind `#if DEBUG`, where it
    // would never run in the build whose sessions this needs to measure (L535, L3).
    @Test func rootViewBumpsTheRootCounterOutsideAnyDebugBlock() throws {
        let source = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(!source.isEmpty, "RootView.swift could not be read, so this measured nothing")
        // Bound to a Bool first, never comparing the file's TEXT: a failing expectation renders its
        // operands, and RootView.swift between the reader and the sentence explaining the failure is how
        // a red run stops being readable (L445). Seen, on the mutation proving this very assertion.
        let countsItsOwnDraws = source.contains("freezeWatch.recordRootDraw()")
        #expect(countsItsOwnDraws,
                "RootView does not count its own draws, so a stall spanning only them reads as nothing")
        let bumpsTheSurfaceCounter = source.contains("freezeWatch.recordPass()")
        #expect(!bumpsTheSurfaceCounter, Comment(rawValue:
            "RootView bumps the SURFACE pass counter. It is not a surface: it is what is underneath "
            + "every surface, and counting it there redefines a field 1,041 written records already "
            + "carry (#3813, L683)"))

        let body = try #require(SourceGuardHelper.propertyBody("var body: some View {", in: source),
                                "RootView's body could not be found, so this measured nothing")
        guard let bump = body.range(of: "freezeWatch.recordRootDraw()") else {
            Issue.record("the bump is not in RootView's own body, so it does not run per evaluation")
            return
        }
        // COMMENTS STRIPPED FIRST, and that is not a nicety: the bump carries a comment saying it is
        // deliberately NOT inside the `#if DEBUG` below it, and the first version of this check counted
        // that sentence as an open block and went red on its own documentation (L103, L135).
        let code = SwiftSource.scannableLines(in: String(body), skipping: [])
            .map(\.code).joined(separator: "\n")
        guard let codeBump = code.range(of: "freezeWatch.recordRootDraw()") else {
            Issue.record("the bump is only in a comment, so nothing counts a draw")
            return
        }
        let before = code[..<codeBump.lowerBound]
        let debugOpens = before.components(separatedBy: "#if DEBUG").count - 1
        let debugCloses = before.components(separatedBy: "#endif").count - 1
        #expect(debugOpens == debugCloses, Comment(rawValue:
            "the root draw bump sits inside a #if DEBUG block, so it never runs in the Release build "
            + "whose sessions it exists to measure (L535)"))
    }

    // And FreezeWatch keeps them as two writers into two boxes, which is what "beside, never into" means
    // in the code rather than only in a comment (L407).
    @Test func theWatchKeepsTheTwoCountersApart() {
        let watch = SourceGuardHelper.source("Overture/App/FreezeWatch.swift")
        #expect(!watch.isEmpty)
        #expect(SourceGuardHelper.containsCode("func recordRootDraw() { watchdog?.rootDraws.bump() }", in: watch))
        #expect(SourceGuardHelper.containsCode("func recordPass() { watchdog?.passes.bump() }", in: watch))
    }
}
