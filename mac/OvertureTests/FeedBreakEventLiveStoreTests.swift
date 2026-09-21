import Testing
import Foundation
import SwiftData

// #4027 / #3383: the rule in `FeedBreakEvent`, asked of Dan's real store through the app's own predicates.
//
// WHY IT REPORTS RATHER THAN REFUSES. A new source breaking is a fact about a venue's website, not about
// anybody's branch, and these suites run inside the mandatory pre-push gate: a test that goes red when a
// theatre changes ticketing provider would block every merge in the repository until the DATA was settled.
// So the invariants are asserted, the events are printed, and the count is deliberately not one of the
// assertions (L68: a guard over live data asserts the SIGNATURE of the failure, never the data's current
// shape).
//
// WHAT IT IS FOR. The events it prints are the false-positive measurement #4027 asks for before anything
// is surfaced, re-takeable on any day instead of quoted from an issue body (L107).
@Suite("What a source-wide feed break looks like on the real store (#4027, #3383)")
struct FeedBreakEventLiveStoreTests {

    private func withLiveShows(_ body: ([Prospect]) throws -> Void) async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("feed-break-\(UUID().uuidString)",
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
            try body(shows)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // SKIPPED, never red, on a machine with no live store. The GitHub-hosted runner is exactly that
    // machine, and without this trait the suite threw there, so `swift-tests` failed on every branch cut
    // after it landed. A red on a machine that cannot be asked is indistinguishable from a red about the
    // code (L411), and blocking every merge is the one outcome this suite's own header says it exists to
    // avoid.
    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func everyEventTheRuleFindsOnTheLiveStoreHoldsItsOwnContract() async throws {
        try await withLiveShows { shows in
            let asOf = EasternDate.today()
            let events = FeedBreakEvent.events(among: shows, asOf: asOf)
            let flagged = shows.filter {
                $0.disappearedFromFeed && max($0.performanceDate ?? "", $0.runEndDate ?? "") >= asOf
            }
            print("Feed break corpus: \(shows.count) row(s), \(flagged.count) flagged and still to come, "
                  + "\(events.count) source-wide event(s) as of \(asOf)")
            for event in events {
                print("  [\(event.memberKeys.count) rows at \(event.missedScoutCount) misses] "
                      + "\(event.venue), \(event.coveredByAnotherCard) already on another card")
                for key in event.memberKeys { print("      \(key)") }
            }

            var seen: Set<String> = []
            for event in events {
                #expect(event.memberKeys.count >= FeedBreakEvent.minimumMembers,
                        "an event below the floor was reported: \(event.venue) with \(event.memberKeys.count)")
                #expect(event.coveredByAnotherCard <= event.memberKeys.count,
                        "\(event.venue) claims more covered rows than it has members")
                #expect(event.missedScoutCount >= FeedReconcile.goneThreshold,
                        "\(event.venue) was reported on a count the app does not even flag")
                for key in event.memberKeys {
                    #expect(seen.insert(key).inserted,
                            "\(key) is in two events at once, so the buckets are not a partition")
                    let row = shows.first { $0.naturalKey == key }
                    #expect(row?.disappearedFromFeed == true, "\(key) is not flagged, so it cannot be a member")
                    #expect(max(row?.performanceDate ?? "", row?.runEndDate ?? "") >= asOf,
                            "\(key) has already played, so naming it costs Dan a look at nothing")
                }
            }
        }
    }
}
