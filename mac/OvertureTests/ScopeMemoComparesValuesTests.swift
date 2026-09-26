import Testing
import Foundation
import SwiftData

// #4252: a memo serves SwiftData's refetch after a save, which re-announces every field of every row with
// nothing changed, instead of deriving the whole store a second time for one saved change.
//
// Every case that MUST rebuild sits beside the case that must not, because a memo that always serves its
// answer passes every "it built nothing" assertion perfectly and shows stale rows (L159, L40). The rows
// live in the container's MAIN context, because that is the context the app's views read and the one the
// memo asks whether anything is unsaved.
@MainActor
@Suite("A memo serves a refetch that changed nothing, and nothing else (#4252)")
struct ScopeMemoComparesValuesTests {

    private func seed(_ ctx: ModelContext, rows: Int) -> [Prospect] {
        var made: [Prospect] = []
        for n in 0..<rows {
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n)", discipline: "music",
                             venue: "Weill Recital Hall", performanceDate: "2027-05-0\(1 + (n % 9))",
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .new)
            ctx.insert(p)
            made.append(p)
        }
        try? ctx.save()
        return made
    }

    /// A fixed instant, so nothing here is measuring the clock (L130, L290).
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor private final class Harness {
        let container: ModelContainer
        let rows: [Prospect]
        let memo: ScopeMemo<String>
        let policy: ScopeMemo<String>.Refetch
        private var tick = 0.0
        private let t0: Date

        init(rows count: Int, policy: ScopeMemo<String>.Refetch, t0: Date,
             seed: (ModelContext, Int) -> [Prospect]) throws {
            container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
            rows = seed(container.mainContext, count)
            // A counter of this harness's own: keyed per container, so another suite's saves cannot move it.
            memo = ScopeMemo<String>(saves: StoreSaveCount(center: .default))
            self.policy = policy
            self.t0 = t0
        }

        // The derivation reads ONE field, `groupName`, and never `discipline`.
        @discardableResult
        func evaluate() -> String {
            tick += 0.1
            var key = ScopeFingerprint()
            key.add(rows)
            return memo.value(fingerprint: key, cardKeys: [], now: t0.addingTimeInterval(tick),
                              staleAfter: .never, savesIn: container, onRefetch: policy) {
                rows.map(\.groupName).joined(separator: "|")
            }
        }

        // What SwiftData's `@Query` refetch does after a save, as measured under #4253: `willSet` on every
        // field of every row, with nothing changed and nothing left unsaved. Played through each row's own
        // `withMutation`, the path the refetch's notification takes, because a plain `fetch` in a unit test
        // re-announces nothing (measured: it left the memo unmarked).
        func reannounce() {
            for row in rows {
                row.withMutation(keyPath: \.groupName) {}
                row.withMutation(keyPath: \.discipline) {}
            }
        }

        // A real fetch in the main context, which is what merges another context's saved write here.
        func refetch() throws {
            _ = try container.mainContext.fetch(FetchDescriptor<Prospect>())
        }
    }

    private func harness(_ policy: ScopeMemo<String>.Refetch = .serveWhenNothingChanged) throws -> Harness {
        try Harness(rows: 12, policy: policy, t0: t0, seed: seed)
    }

    // One saved change, as a mutation makes it: an edit and a save, then the refetch.
    private func savedChange(_ h: Harness) throws {
        h.rows[3].groupName = "Renamed Ensemble"
        try h.container.mainContext.save()
        h.evaluate()
        h.reannounce()
    }

    @Test func theRefetchAfterASavedChangeIsServed() throws {
        let h = try harness()
        h.evaluate()
        try savedChange(h)
        #expect(h.memo.builds == 2, "the saved change itself did not rebuild, so nothing below means anything")

        let answer = h.evaluate()
        #expect(h.memo.servedUnchanged == 1, Comment(rawValue:
            "the refetch was served \(h.memo.servedUnchanged) times, so it never marked the memo stale and "
            + "the build count below would hold for the wrong reason"))
        #expect(h.memo.builds == 2, Comment(rawValue:
            "the refetch after one saved change derived again (\(h.memo.builds) builds), which is the "
            + "second derivation per saved change #4106 measured"))
        #expect(answer.contains("Renamed Ensemble"))
    }

    @Test func aMemoThatChoseToRebuildRebuildsOnTheRefetch() throws {
        let h = try harness(.rebuild)
        h.evaluate()
        try savedChange(h)
        h.evaluate()
        #expect(h.memo.servedUnchanged == 0)
        #expect(h.memo.builds == 3, "a memo told to rebuild on a refetch served it instead")
    }

    // A SERVED answer must still hear the next edit. The build's own tracking was spent by the refetch, so
    // this only holds if serving re-armed it.
    @Test func anUnsavedEditAfterAServedRefetchRebuilds() throws {
        let h = try harness()
        h.evaluate()
        try savedChange(h)
        h.evaluate()
        #expect(h.memo.servedUnchanged == 1, "the refetch was not served, so the edit below follows a build")

        h.rows[8].groupName = "Edited After The Refetch"
        let answer = h.evaluate()
        #expect(h.memo.builds == 3, Comment(rawValue:
            "an edit in place after a served refetch left the memo at \(h.memo.builds) builds, so serving "
            + "did not re-arm observation and the screen would keep the old answer"))
        #expect(answer.contains("Edited After The Refetch"))
    }

    // An observed change with something unsaved behind it is an edit, not a refetch.
    @Test func anUnsavedEditIsNeverServed() throws {
        let h = try harness()
        h.evaluate()
        h.rows[5].groupName = "Unsaved"
        let answer = h.evaluate()
        #expect(h.memo.servedUnchanged == 0)
        #expect(h.memo.builds == 2, "an unsaved edit was served as a refetch")
        #expect(answer.contains("Unsaved"))
    }

    // A save since the build is a change, whatever observation says.
    @Test func aSaveSinceTheBuildRebuilds() throws {
        let h = try harness()
        h.evaluate()
        h.rows[5].discipline = "theater"
        try h.container.mainContext.save()
        h.evaluate()
        #expect(h.memo.builds == 2, "a save since the build was served")
    }

    // Serving re-arms EVERY property; the build that follows arms only what the derivation reads. The
    // serving's tracking cannot be cancelled, so it must not mark the next answer stale. The rebuild here
    // is provoked by a save that touches none of the rows, so the serving's registrations are still armed
    // when the build replaces them (a field edit would have spent them).
    @Test func aBuildAfterAServedRefetchWatchesOnlyWhatItRead() throws {
        let h = try harness()
        h.evaluate()
        try savedChange(h)
        h.evaluate()
        #expect(h.memo.servedUnchanged == 1, "the refetch was not served, so the case below never arises")

        let elsewhere = Prospect(naturalKey: "not-an-input", groupName: "Elsewhere", discipline: "music",
                                 venue: "Merkin Hall", performanceDate: "2027-06-01", sourceListingURL: nil,
                                 priorRelationship: "none", production: "self", profile: "strong",
                                 coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                                 status: .new)
        h.container.mainContext.insert(elsewhere)
        try h.container.mainContext.save()
        h.evaluate()
        #expect(h.memo.builds == 3, "the save did not rebuild, so the serving's tracking was never replaced")

        // To a property the derivation never reads: nothing the answer depends on moved. It is left
        // UNSAVED, so if the serving's tracking still marks the answer stale, the unsaved change behind it
        // makes the memo rebuild, which is what this refuses.
        h.rows[4].discipline = "dance"
        h.evaluate()
        #expect(h.memo.builds == 3, Comment(rawValue:
            "an edit to a property the derivation never reads rebuilt it: the served refetch's tracking "
            + "outlived the build that replaced it"))
    }

    // THE ONE CASE VALUES DECIDE. A write saved through another context BEFORE the build, merged into the
    // main context after it: no save since the build, nothing unsaved, and a row that changed.
    @Test func aWriteFromAnotherContextMergedAfterTheBuildRebuilds() throws {
        let h = try harness()
        let other = ModelContext(h.container)
        let theirs = try #require(try other.fetch(FetchDescriptor<Prospect>()).first { $0.naturalKey == "row-6" })
        theirs.groupName = "Written Elsewhere"
        try other.save()

        let before = h.evaluate()
        try #require(!before.contains("Written Elsewhere"), Comment(rawValue:
            "the main context had already merged the other context's write when the memo built, so this "
            + "fixture cannot produce the merge-after-build case it exists for"))

        try h.refetch()
        let after = h.evaluate()
        #expect(after.contains("Written Elsewhere"), Comment(rawValue:
            "a write merged in from another context after the build was served as a refetch "
            + "(builds \(h.memo.builds), served \(h.memo.servedUnchanged)): the screen disagrees with the store"))
    }
}
