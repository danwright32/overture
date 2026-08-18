import Testing
import Foundation

// #2978: the check learns its pace from ITS OWN results file.
//
// #2760 split the reachability check onto its own run slot, and `recordCheckPace` kept reading
// `PrepImporter.defaultURL`, which is `resultsURL(for: .prep)`. The settle call on the line above it
// already carries the right answer, so the run's own slot was in scope and simply unused.
//
// Measured on the live store on 2026-08-18 rather than argued: the last two rows of
// `overture-probe-duration-history.json` were `301.47` seconds over 6 streams, twice, and
// `overture-prep-results.json` held exactly `durationMs 301470, streams 6` from 2026-08-16. So one stale
// file's cost was filed as two different checks' pace, while the two checks that really ran that day
// (196512ms over 5 streams, and 432721ms over 8) recorded nothing at all.
//
// It is silent in both directions, which is why it needs a guard rather than attention: a refused sample
// writes nothing and says nothing (L98), and a wrong row is a plausible number indistinguishable from a
// right one (L90). What it feeds is the wait quoted BEFORE Dan spends, which is the one figure that has
// to be honest about work he has not paid for yet.
@Suite("A check learns its pace from its own slot (#2978)")
struct CheckPaceReadsItsOwnSlotTests {

    private static var recordCheckPaceBody: String? {
        SourceGuardHelper.bodyOfFunction(named: "recordCheckPace",
                                         in: SourceGuardHelper.source("Overture/App/RootView.swift"))
    }

    // Scoped to the function's own body, never the whole file (L135). RootView legitimately names the
    // prep results file elsewhere, so a search over the file would be answered by one of those and pass
    // while this line was wrong, which is exactly how the defect survived.
    @Test func theWallClockComesFromTheSettlingSlotsResultsFile() throws {
        let body = try #require(Self.recordCheckPaceBody,
                                "recordCheckPace could not be found, so this guard checked nothing (L98)")
        #expect(SourceGuardHelper.containsCode("PrepImporter.resultsURL(for: slot)", in: body),
                """
                recordCheckPace must read the results file of the slot that just settled. Reading a fixed \
                slot files one run's wall clock as another run's pace, and the estimate it feeds is what \
                Dan is quoted before he spends (#2978).
                """)
    }

    // The other half, and a separate fact: the fixed default is GONE from this body rather than merely
    // joined by the right call. Both present would compile, and whichever was actually passed would
    // decide, with the guard above satisfied either way.
    @Test func theFixedPrepDefaultIsNotUsedHere() throws {
        let body = try #require(Self.recordCheckPaceBody,
                                "recordCheckPace could not be found, so this guard checked nothing (L98)")
        #expect(!SourceGuardHelper.containsCode("PrepImporter.defaultURL", in: body),
                "recordCheckPace still names the prep slot's results file (#2978)")
    }

    // And the slot really does reach it, rather than the body naming a `slot` that is some other value in
    // scope. The caller settles a specific slot and must hand that same one over.
    @Test func theSettlingSlotIsPassedIn() {
        let source = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(SourceGuardHelper.containsCode("recordCheckPace(slot: slot,", in: source),
                "the slot that was settled must be the slot whose pace is recorded")
    }
}
