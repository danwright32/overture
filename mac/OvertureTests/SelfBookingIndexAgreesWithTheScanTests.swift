import Testing
import Foundation

// #3438: the indexed answer and the scanning answer are two definitions of one question, and nothing
// made them agree.
//
// `SelfBookingConflict` has two shapes of every lookup: `conflicts(for:among:)` walks the array, and
// `conflicts(for:in:)` reads a `NightIndex` built once per render pass. #3323 introduced the index and
// pointed the whole app at it, correctly: the render pass builds one (`QueueRenderPass.swift:193`) and
// every helper takes it, so the per-row rebuild #3438 was filed about is already gone.
//
// What #3438 asked for and did not exist is THIS. Every test in `SelfBookingConflictTests` drives the
// SCANNING overload, and the app runs the INDEXED one, so the suite could be entirely green while the
// index answered differently from the definition it was built from. That is L263 exactly: two same-named
// functions on either side of a boundary, never compared, each call site reading correct in isolation.
//
// The oracle is the SCAN, as #3438 decided (L70): nothing is deleted, `conflicts(for:among:)` stays the
// definition and the index is a lookup built FROM it, so this compares two live things and neither is
// dead code.
//
// THE CORPUS IS SHAPED, not sized. The self-booking term is quadratic in shows SHARING A DATE, never in
// row count, so what makes this meaningful is the clustering: the live store's largest single-date
// cluster was 19 when #3435 measured it, and a corpus of a thousand rows on a thousand distinct dates
// would exercise nothing at all (L101).
@Suite("The self-booking index answers exactly what the scan answers (#3438)")
struct SelfBookingIndexAgreesWithTheScanTests {

    private func show(_ id: Int, nights: [String], committed: Bool,
                      times: [String: [String]] = [:]) -> SelfBookingConflict.Show {
        SelfBookingConflict.Show(key: "show-\(id)", nights: nights, isCommitment: committed,
                                 engagementKey: "Ensemble \(id)", name: "Ensemble \(id)",
                                 timesByNight: times)
    }

    // Nineteen shows on one night, which is the live store's largest measured cluster, plus runs that
    // straddle several nights, plus uncommitted rows that must be invisible to both readings, plus
    // start times so the workable-versus-clash split is exercised rather than short-circuited.
    private var corpus: [SelfBookingConflict.Show] {
        var shows: [SelfBookingConflict.Show] = []
        let hot = "2026-11-14"
        for n in 0..<19 {
            shows.append(show(n, nights: [hot], committed: n % 4 != 0,
                              times: [hot: [n % 3 == 0 ? "19:30" : "14:00"]]))
        }
        // Runs across several nights, one of which is the crowded one.
        for n in 20..<28 {
            let nights = ["2026-11-1\(n % 3 + 2)", hot, "2026-11-16"]
            shows.append(show(n, nights: nights, committed: n % 3 != 0,
                              times: [hot: ["20:00"]]))
        }
        // Quiet nights, so the index is not uniformly hot.
        for n in 30..<60 {
            shows.append(show(n, nights: ["2026-12-\(String(format: "%02d", 1 + n % 28))"],
                              committed: n % 2 == 0))
        }
        return shows
    }

    @Test func everyRowGetsTheSameConflictsFromTheIndexAsFromTheScan() {
        let all = corpus
        let index = SelfBookingConflict.NightIndex(all)

        // The comparison is meaningless if nothing collides, so the corpus is asserted to hold clashes
        // before the agreement below is read as evidence (L159, L98).
        let clashing = all.filter { !SelfBookingConflict.conflicts(for: $0, among: all).isEmpty }
        #expect(clashing.count >= 5,
                Comment(rawValue: "only \(clashing.count) rows in this corpus clash at all, so the "
                        + "agreement below is mostly two empty lists matching"))

        for target in all {
            let scanned = SelfBookingConflict.conflicts(for: target, among: all)
            let indexed = SelfBookingConflict.conflicts(for: target, in: index)
            #expect(scanned.map(\.other.key) == indexed.map(\.other.key),
                    Comment(rawValue: "the index and the scan disagree about \(target.key)'s conflicts: "
                            + "scan says \(scanned.map(\.other.key)), index says "
                            + "\(indexed.map(\.other.key)). The scan is the definition; the index is a "
                            + "lookup built from it, and the app reads only the index."))
            #expect(scanned.map(\.night) == indexed.map(\.night),
                    Comment(rawValue: "the index and the scan disagree about WHICH NIGHTS \(target.key) "
                            + "clashes on, which is what the row marker and the send warning name."))
        }
    }

    // The other half of the same split. A show the clock proves is workable alongside another is NOT a
    // clash, and the two readings must agree about that too, or a reassuring line and an actionable one
    // swap places.
    @Test func everyRowGetsTheSameWorkableNightsFromBoth() {
        let all = corpus
        let index = SelfBookingConflict.NightIndex(all)

        let workableSomewhere = all.filter { !SelfBookingConflict.workable(for: $0, among: all).isEmpty }
        #expect(workableSomewhere.count >= 3,
                Comment(rawValue: "only \(workableSomewhere.count) rows have a workable neighbour, so "
                        + "this comparison is mostly empty lists matching"))

        for target in all {
            let scanned = SelfBookingConflict.workable(for: target, among: all)
            let indexed = SelfBookingConflict.workable(for: target, in: index)
            #expect(scanned.map(\.other.key) == indexed.map(\.other.key),
                    Comment(rawValue: "the index and the scan disagree about which shows are WORKABLE "
                            + "alongside \(target.key)."))
        }
    }

    // An uncommitted show is invisible to both readings. Asserted because it is the one input where the
    // index's build loop and the scan's filter apply the same rule in different places, so a change to
    // one could silently keep the other.
    @Test func neitherReadingSeesAnUncommittedShow() {
        let hot = "2026-11-14"
        let target = show(1, nights: [hot], committed: true, times: [hot: ["19:30"]])
        let ghost = show(2, nights: [hot], committed: false, times: [hot: ["19:30"]])
        let all = [target, ghost]

        #expect(SelfBookingConflict.conflicts(for: target, among: all).isEmpty)
        #expect(SelfBookingConflict.conflicts(for: target,
                                              in: SelfBookingConflict.NightIndex(all)).isEmpty)
    }
}
