import Testing
import Foundation
import SwiftData

// #2998: how many of Dan's runs are wholly redundant with separate cards, asked of his real store
// through the same predicate the app would act on.
//
// This is the REPORT half of the adjusted direction (2026-09-20): the card control and the one press
// retire are deliberately held until this number is not zero, because a control built for a state
// nobody is in ships inert (L543). So this suite exists to say, on any day, whether that moment has come,
// instead of the number being quoted from an issue body and trusted (L107).
//
// It REPORTS rather than refuses, for the reason the other live store suites give: the count is a fact
// about Dan's data, and a test that went red when a venue started listing a weekly series both ways
// would block every merge until the data changed (L68). What it asserts is the invariant that has to
// hold whatever the data is: every run gets exactly one answer (L517).
@MainActor
@Suite("How many runs are wholly covered by separate cards, on the real store (#2998)")
struct FullyCoveredRunLiveStoreTests {

    private func withLiveShows(_ body: ([Prospect], ModelContext) throws -> Void) async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("covered-runs-\(UUID().uuidString)",
                                                                   isDirectory: true)
            defer { try? fm.removeItem(at: dir) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let url = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let schema = Schema([Prospect.self, Recipient.self])
            let context = ModelContext(try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]))
            let shows = try context.fetch(FetchDescriptor<Prospect>())
            // An empty read is a failed open, never a clean bill of health (L98).
            #expect(!shows.isEmpty, "the copied store holds no shows, so nothing below measured anything")
            try body(shows, context)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func everyRunGetsExactlyOneCoverageAnswer() async throws {
        try await withLiveShows { shows, context in
            var fully = 0, partial = 0, none = 0, unreadable = 0, notARun = 0
            var fullyCoveredNames: [String] = []
            for p in shows {
                switch p.coverageOfItsOtherNights(lookup: { try Prospect.stored(key: $0, in: context) }) {
                case .fullyCovered:
                    fully += 1
                    fullyCoveredNames.append("\(p.groupName) @ \(p.venue ?? "?") \(p.performanceDate ?? "?")")
                case .partiallyCovered: partial += 1
                case .notCovered: none += 1
                case .cannotCheck: unreadable += 1
                case .notARun: notARun += 1
                }
            }
            let runs = fully + partial + none + unreadable
            print("Covered runs: \(shows.count) row(s), \(runs) multi night run(s): "
                  + "\(fully) fully covered, \(partial) partially, \(none) not covered, "
                  + "\(unreadable) could not be checked")
            for name in fullyCoveredNames.sorted() { print("  fully covered: \(name)") }
            print(fully == 0
                  ? "The card control stays held: no run is wholly redundant today (#2998, L543)."
                  : "The card control's moment has come: \(fully) run(s) are wholly redundant (#2998).")

            // THE INVARIANT, which holds whatever the data is. Every row lands in exactly one bucket,
            // so a new answer added to `RunCoverage` without a bucket here fails rather than vanishing.
            #expect(runs + notARun == shows.count,
                    "a row was counted in no bucket or in two, so the report's totals do not add up")
            // A store the clone could open must be readable for this question too. An unreadable answer
            // over a readable store means the predicate is asking something the store cannot answer.
            #expect(unreadable == 0,
                    Comment(rawValue: "\(unreadable) run(s) could not be checked against a store that "
                            + "opened, so the report is measuring less than it claims"))
        }
    }
}
