import Testing
import Foundation
import SwiftData

// #4353 (plan v7 Step W), ONE TIME and deleted in the next commit: the old word prefilter, frozen here as a
// private copy of `VenueKeyIndex.candidates(for:)` and of the patch prototypes' hand rolled maps, against
// `ProducerGate.WordPostings`, over the synthetic 60 and 300 row fixtures at every harness state and over a
// clone of the live store and its fourfold copy. The plan asks for this diff once, pasted, before the old
// body goes (#4267, R4); it is not kept, because a frozen second copy of the superset reasoning is exactly
// the drift Step W removes (L370). Counts and timings only.
@MainActor
@Suite("Step W one time parity: old word prefilter against WordPostings (#4353)")
struct WordPostingsParityOnceTests {
    private let sandboxes = TemporarySandboxes()

    // The old body, frozen verbatim from ProducerGate.swift at 5ac02620.
    private static func oldIndex(_ keys: Set<String>) -> [String: Set<String>] {
        var index: [String: Set<String>] = [:]
        for key in keys {
            for word in key.split(separator: " ") { index[String(word), default: []].insert(key) }
        }
        return index
    }

    private static func oldCandidates(_ index: [String: Set<String>], _ key: String) -> Set<String> {
        var found: Set<String> = []
        for word in key.split(separator: " ") {
            if let hits = index[String(word)] { found.formUnion(hits) }
        }
        return found
    }

    /// Every key of either side asked of both sides' postings; returns (questions, disagreements).
    private static func diff(presenters: Set<String>, venues: Set<String>) -> (Int, Int) {
        let oldVenue = oldIndex(venues), oldPresenter = oldIndex(presenters)
        let newVenue = ProducerGate.VenueKeyIndex(venues).postings
        let newPresenter = ProducerGate.WordPostings(presenters)
        var asked = 0, differ = 0
        for k in presenters.union(venues) {
            asked += 2
            if oldCandidates(oldVenue, k) != newVenue.keys(sharingAWordWith: k) { differ += 1 }
            if oldCandidates(oldPresenter, k) != newPresenter.keys(sharingAWordWith: k) { differ += 1 }
        }
        return (asked, differ)
    }

    private static func keys(_ shows: [ProducerGate.Show]) -> (Set<String>, Set<String>) {
        (Set(shows.compactMap { ProducerGate.key($0.presenter) }), ProducerGate.venueKeys(of: shows))
    }

    @Test func syntheticFixturesAtEveryHarnessState() {
        var totalAsked = 0, totalDiffer = 0, states = 0
        for size in [60, 300] {
            let settings = Phase0cProducers.harness(size: size)
            _ = Phase0cProducers.drive(
                seeds: settings.seeds, ops: settings.ops, seedBase: UInt64(4106_300 + size),
                initial: { Phase0cFixtures.t4World(size: size, &$0) },
                cold: { w in
                    let (p, v) = Self.keys(w.list); let (a, d) = Self.diff(presenters: p, venues: v)
                    totalAsked += a; totalDiffer += d; states += 1
                    return []
                },
                step: { Phase0cFixtures.t4Step($0, size: size, &$1) },
                move: { _, new, _ in
                    let (p, v) = Self.keys(new.list); let (a, d) = Self.diff(presenters: p, venues: v)
                    totalAsked += a; totalDiffer += d; states += 1
                    return []
                })
        }
        print("stepw-parity synthetic: \(states) fixture states, \(totalAsked) questions, \(totalDiffer) differ")
        #expect(states > 50)
        #expect(totalDiffer == 0)
    }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func liveCloneAndItsFourfoldCopy() throws {
        let dir = try sandboxes.make(named: "stepw-parity")
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        for (label, url) in [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))] {
            let ctx = ModelContext(try Phase0.openContainer(at: url))
            let shows = try ctx.fetch(FetchDescriptor<Prospect>())
                .map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) }
            let (p, v) = Self.keys(shows)
            let (asked, differ) = Self.diff(presenters: p, venues: v)
            // The build cost, old against new, interleaved so both see the same machine (L224).
            var oldMs: [Double] = [], newMs: [Double] = []
            for _ in 0..<5 {
                oldMs.append(Phase0.time { _ = Self.oldIndex(v) })
                newMs.append(Phase0.time { _ = ProducerGate.VenueKeyIndex(v) })
            }
            print("stepw-parity \(label): \(shows.count) rows, \(p.count) presenter keys, \(v.count) venue keys, "
                  + "\(asked) questions, \(differ) differ; venue index build old "
                  + Phase0b.reading(oldMs).text + ", new " + Phase0b.reading(newMs).text + ", load " + Phase0.load())
            #expect(v.count > 50)
            #expect(differ == 0)
        }
    }
}
