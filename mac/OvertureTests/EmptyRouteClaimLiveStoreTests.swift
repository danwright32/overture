import Testing
import Foundation
import SwiftData

// #3345. The card can tell Dan a show has no way in. This asks the app's own code whether that is true of
// the shows it currently says it about.
//
// The issue was filed on a count taken in SQL over `reachabilityEmptyReasonRaw`: 37 shows carrying
// `named_but_no_route`, 31 of them holding a route. That number is still exactly what the column says
// (re-measured 2026-09-06, 37 and 31, unchanged), and it is NOT what the card says, because the sentence
// is drawn only under `ProspectRowView`'s `.noEmailFound` arm and that verdict recomputes from the row's
// own contacts through `reachabilityResultAsHeld`. A stored reason on a row whose verdict has since moved
// is read by nothing.
//
// So the column was the wrong subject. The right one is the CLAIM, and this suite is that question asked
// of the predicate the screen actually uses rather than of a reproduction of it beside the code (L107).
// Reproducing `hasUnguardedAddress` in SQL is how the original count was taken, and a second definition of
// a rule drifts silently and in the direction that flatters whoever wrote it.
//
// Reads a COPY through `LiveStoreClone`, never the live file, and writes nothing anywhere (L2). Skips
// visibly on a machine with no store rather than passing silently.
@Suite("A show told it has no route really has none (#3345)")
struct EmptyRouteClaimLiveStoreTests {
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    private func withLiveShows(_ body: ([Prospect]) throws -> Void) async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("empty-route-claim-\(UUID().uuidString)",
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
            // A store that reads as empty is a failed open, not a clean bill of health (L98).
            #expect(!shows.isEmpty, "the copied store holds no shows, so nothing below measured anything")
            #expect(shows.contains { !$0.recipients.isEmpty },
                    "the copied store holds no contacts, so the derivations below ran over nothing")
            try body(shows)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // Every show whose card draws the empty-answer sentence, which is `ProspectRowView`'s `.noEmailFound`
    // arm and nothing else. Asked through `reachabilityResultAsHeld` because that is what the row switches
    // on: it recomputes from the contacts for a show still in play, and falls back to the STORED verdict
    // once the show has been sent to or booked, which is the branch where a stale answer can survive.
    private func showsClaimingNoRoute(in shows: [Prospect]) -> [Prospect] {
        shows.filter { $0.reachabilityResultAsHeld == .noEmailFound }
    }

    // LIVE-STORE-CLAIM verified=2026-09-06 measure="shows whose card draws the empty-answer sentence, and whether any of them holds an unguarded address or a usable contact form. Measured 2026-09-06: 4 shows draw it, all 4 hold zero recipients of any kind, so none of them holds a route"
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func noShowIsToldItHasNoRouteWhileHoldingOne() async throws {
        try await withLiveShows { shows in
            var contradicted: [String] = []
            for show in showsClaimingNoRoute(in: shows) {
                // The two routes the card itself would offer. `hasUnguardedAddress` is the address arm of
                // `reachabilityResultFromRecipients`; `usableContactFormURLs` is the form arm, already
                // stripped of venue, press and social URLs by the prospect itself.
                let address = show.recipients.first(where: \.hasUnguardedAddress)
                let form = show.usableContactFormURLs.first
                if address != nil || form != nil {
                    let held = address != nil ? "an address no guard is holding" : "a usable contact form"
                    contradicted.append("\(show.groupName): says no way in, holds \(held)")
                }
            }
            #expect(contradicted.isEmpty,
                    Comment(rawValue: contradicted.prefix(5).joined(separator: "\n")))
        }
    }

    // The corpus, printed every run, because green above means "no live row violates this" and never
    // "this rule was exercised" (L182, L98). The population that draws the sentence shrinks whenever a
    // check finds a route, so it can reach zero on a perfectly healthy store, and only a printed number
    // can tell that apart from a rule that has quietly stopped having anything to say.
    //
    // The second number is the one #3345 was really about. A stored `namedButNoRoute` on a show whose
    // verdict has since moved to a route is DEAD DATA: written by a run before #3387 and #3358, rendered
    // by nothing today. It is reported rather than asserted, deliberately, because a red over data no
    // surface reads is a standing red, and a standing red makes every other failure unreadable (L538).
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theSuiteReportsHowManyShowsItCouldMeasure() async throws {
        try await withLiveShows { shows in
            let claiming = showsClaimingNoRoute(in: shows)
            let storedNamedButNoRoute = shows.filter { $0.reachabilityEmptyReason == .namedButNoRoute }
            let deadReasons = storedNamedButNoRoute.filter {
                $0.reachabilityResultFromRecipients != .noEmailFound
            }
            print("empty-route corpus: \(claiming.count) of \(shows.count) shows draw the "
                  + "no-route sentence, \(storedNamedButNoRoute.count) carry a stored namedButNoRoute "
                  + "reason, \(deadReasons.count) of those are contradicted by their own contacts and "
                  + "so are read by nothing")
            // Not an assertion about the numbers, which move every night. An assertion that the selection
            // was actually computed: `filter` over an unopened store returns empty exactly as a clean
            // store does, and the two must not print the same line (L98).
            #expect(shows.count > 0, "the corpus line above was computed over no shows at all")
        }
    }
}
