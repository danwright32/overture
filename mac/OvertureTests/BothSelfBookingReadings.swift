import Testing
import Foundation

// #3514: `SelfBookingConflict` carries two shapes of every lookup, and only one of them ships.
//
// In `OvertureTests` rather than `mac/TestSupport/`, which is where a shared test helper normally lives:
// TestSupport is compiled into the app-hosted target as well, and that one LINKS the app rather than
// compiling it, so a helper there cannot name an app domain type at all.
//
// `conflicts(for:among:)` and `workable(for:among:)` walk the array. `conflicts(for:in:)` and
// `workable(for:in:)` read a `NightIndex`. THE APP READS ONLY THE INDEX: `QueueRenderPass` builds one per
// render pass and every helper takes it. Every behaviour case in `SelfBookingConflictTests`,
// `SelfBookingWorkableNightTests` and `SelfBookingRunNightsTests` drove only the SCAN, so the two
// readings applied the commitment rule, the different-show rule and the workable-gap rule in different
// places with nothing comparing them on the inputs where they are most likely to differ.
//
// #3438 added `SelfBookingIndexAgreesWithTheScanTests`, which proves agreement over one deliberately
// shaped corpus. What that cannot cover is the EDGE CASES, which live in the three suites above: two
// shows at the same curtain time, a run whose sibling shares every night with itself, a show exempt
// through its engagement key, a night where the clock proves two shows are workable.
//
// So the cases are not duplicated. They are asked of BOTH readings through here, which keeps ONE set of
// cases and ONE set of expectations, so nobody can update one and leave the other behind (L263, L26).
//
// WHAT AN AGREEMENT HERE IS WORTH, stated so the suites are not read as proving more than they do. A
// two-row corpus exercises the index's build loop trivially: one bucket, one entry. What these cases DO
// discriminate is the RULES, which is where the two readings genuinely differ, because the scan applies
// `isCommitment` inside its filter and the index applies it while bucketing. A case whose corpus cannot
// tell the two apart still costs nothing and still goes red if one rule moves.
enum BothSelfBookingReadings {

    // The one place the two readings are compared. Both are taken, they must agree exactly (same
    // overlaps, same order), and the answer handed back is the INDEXED one, because that is what ships:
    // a helper returning the scan's answer would let every expectation in every suite be satisfied by a
    // reading the app never takes.
    private static func agreeing(_ scanned: [SelfBookingConflict.Overlap],
                                 _ indexed: [SelfBookingConflict.Overlap],
                                 _ what: String,
                                 sourceLocation: SourceLocation) -> [SelfBookingConflict.Overlap] {
        let describe = { (o: [SelfBookingConflict.Overlap]) in
            o.map { "\($0.night)/\($0.other.key)" }.joined(separator: ", ")
        }
        #expect(scanned.map(\.night) == indexed.map(\.night)
                && scanned.map(\.other.key) == indexed.map(\.other.key),
                Comment(rawValue: "the two readings of \(what) disagree on this case. Scanning the array "
                        + "gives [\(describe(scanned))]; reading the night index gives "
                        + "[\(describe(indexed))]. The app reads only the index, so the scan's answer is "
                        + "the one nobody sees (#3514, #3438)."),
                sourceLocation: sourceLocation)
        return indexed
    }

    static func conflicts(for target: SelfBookingConflict.Show, among all: [SelfBookingConflict.Show],
                          sourceLocation: SourceLocation = #_sourceLocation) -> [SelfBookingConflict.Overlap] {
        agreeing(SelfBookingConflict.conflicts(for: target, among: all),
                 SelfBookingConflict.conflicts(for: target, in: SelfBookingConflict.NightIndex(all)),
                 "conflicts", sourceLocation: sourceLocation)
    }

    static func workable(for target: SelfBookingConflict.Show, among all: [SelfBookingConflict.Show],
                         sourceLocation: SourceLocation = #_sourceLocation) -> [SelfBookingConflict.Overlap] {
        agreeing(SelfBookingConflict.workable(for: target, among: all),
                 SelfBookingConflict.workable(for: target, in: SelfBookingConflict.NightIndex(all)),
                 "workable", sourceLocation: sourceLocation)
    }
}
