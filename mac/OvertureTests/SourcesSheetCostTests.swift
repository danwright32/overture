import Testing
import Foundation
import SwiftData

// #3656 (milestone #80, Phase 6): an instrument that can actually SEE the Sources sheet, and the reading
// it takes.
//
// CORRECTION C5 is the whole reason this exists. The plan said to measure with the Phase 0 instruments,
// and those are `QueueRenderPass.WorkTally`'s counters, every one of which is bound around building a
// queue CARD. Verified 2026-09-08: `SourcesView` contains ZERO occurrences of `QueueItem` and ZERO of
// `QueueModel.items`. It is a sheet with its own `@Query private var prospects` (`SourcesView.swift:23`)
// in a different view tree, so a reading taken with those counters comes back at zero BY CONSTRUCTION,
// and a zero from an instrument nothing calls is UNMEASURED rather than cheap (L90, L98, L248).
//
// WHAT THIS SURFACE ACTUALLY PAYS, and it is the thing no counter here can express. Three
// `.onChange(of:)` modifiers sit on the sheet (`SourcesView.swift:223`, `:231`, `:239`), and **the value
// they watch is an ARGUMENT, so it is evaluated at the call site on every body evaluation** rather than
// only when something changes. That is #1916's shape and #3647's, one file over. The recompute behind
// each gate is skipped when the signature matches; computing the signature is not.
//
// So the instrument is a stopwatch over the live corpus, timing each signature and each recompute
// separately, because the whole design of this surface rests on the claim that the signature is "cheap to
// evaluate every redraw" while the recompute behind it is not. That claim is what has never been measured.
//
// THE READINGS, 2026-09-08, over 1,226 prospects, 73 sources and 31 clients, means of 10 after a warm
// pass. BEFORE is the sheet as #3656 found it, three hash gates gating two recomputes; AFTER is the same
// sheet with the two whole-store gates removed, which is what shipped:
//
//   BEFORE  per body evaluation   6.88 ms   SourceYield 3.95, UnplacedRooms 2.46, ClientCoverage 0.47
//           behind the gates      SourceYield.tallies 6.21 ms, UnplacedRooms.from 2.64 ms
//   AFTER   per body evaluation   8.98 ms   tallies 6.08, rooms 2.41, ClientCoverage key 0.49
//
// **+2.10 ms per redraw**, and that is the whole price of the change. It is measured in the same change
// that made it rather than estimated beside it (L5), and it came in under the +2.44 ms the decision was
// taken on. What it buys is that no number on this sheet can any longer be one the store disagrees with.
//
// TWO THINGS IN IT ARE WORTH MORE THAN THE TOTAL, and neither is what the phase expected to find.
//
// **The `UnplacedRooms` gate barely pays for itself.** Its change-key costs 2.46 ms and the recompute it
// avoids costs 2.64 ms, so the gate saves about 7%. Both walk the same `waitingShows(prospects:context:)`
// and the key then hashes a venue string while the recompute builds a small map, which is why they cost
// almost the same. `SourceYield`'s gate is better but not by much: 3.95 ms to avoid 6.21 ms, saving 36%.
// A cache is supposed to make the common path cheap, and on the common path (nothing changed) this one
// pays 64% of the price it exists to avoid. `ClientCoverage`'s is the one doing its job: 0.47 ms to
// gate an O(clients x sources) match.
//
// #3645 RE-TOOK THIS READING WITH THE FOURTH THING IN IT, AND IT CHANGES THE ANSWER BELOW.
//
// Every number above times a CHANGE KEY or its recompute. None of them times `SourcesView.roomContext`,
// which was evaluated at the call site on every body pass exactly like the keys were, and which
// constructs a `ClientWindow`. Measured 2026-09-12 on a quiet Mac (load average 2.06 to 3.12 throughout),
// medians of five runs over 1,238 prospects, 73 sources and 31 clients:
//
//   ClientWindow(sources:clients:)   69.01 ms   (68.55 to 69.31 over five runs)
//   everything else per redraw        7.87 ms   (7.67 to 8.42)
//
// So one body evaluation of this sheet cost about **76.9 ms**, not the 8.98 ms recorded above, and the
// fuzzy roster match was NINE TENTHS of it. The reading above is not wrong; it is a reading of the three
// things somebody thought to time, and the expensive one was the one nobody did (L102).
//
// That also revises the conclusion in the paragraph below, which is left standing rather than rewritten
// because it is a dated measurement and the argument it makes from its own numbers is sound. At 76.9 ms a
// redraw, seventeen body evaluations reach 1.3 seconds, so the per-redraw derivation cost CAN account for
// the freezes #3645 recorded, where 9 ms could not. #3645 takes the match off the render path: it is
// decided when its inputs change and handed to `SourcesRenderPass` as a value.
//
// **And this is NOT what freezes the sheet.** #3645 measured 30 real freezes on this surface in one day
// at a median of 1.34 seconds. 6.88 ms per body evaluation cannot produce that on its own, so the change
// keys are not the cause and converting them would not fix it. What turns milliseconds into a freeze is
// HOW MANY body evaluations an interaction drives, which this instrument deliberately cannot see: it
// times one derivation, unhosted. Counting evaluations needs the hosted target, and that is #3645'"'"'s
// question rather than this one'"'"'s (L102: a cost measured with the expensive path switched off reads as
// reassurance for exactly the case nobody tested).
@Suite("What one Sources sheet redraw costs (#3656)")
struct SourcesSheetCostTests {
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }
    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    private struct Live {
        let prospects: [Prospect]
        let sources: [WatchedSource]
        let context: StageContext
        // The OTHER two inputs `ClientCoverage.signature` reads. Carried rather than defaulted to empty:
        // timing that signature with no clients and nothing dismissed measures the sources half alone
        // and reports a lower bound as the sheet's cost, which is a measurement taken with the expensive
        // path switched off (L102).
        let clients: [DownbeatClient]
        let dismissedIds: Set<String>
        let rosterHealth: DownbeatBridge.Health
    }

    private func live(in dir: URL, now: Date) throws -> Live {
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let schema = Schema([Prospect.self, Recipient.self, WatchedSource.self,
                             ExcludedTown.self, AllowedSeedTown.self, DismissedCoverageClient.self])
        let ctx = ModelContext(try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: clone, cloudKitDatabase: .none)]))
        let prospects = try ctx.fetch(FetchDescriptor<Prospect>())
        let sources = try ctx.fetch(FetchDescriptor<WatchedSource>())
        let excluded = try ctx.fetch(FetchDescriptor<ExcludedTown>())
        let allowedSeed = try ctx.fetch(FetchDescriptor<AllowedSeedTown>())
        let dismissed = try ctx.fetch(FetchDescriptor<DismissedCoverageClient>())
        // Built the way `SourcesView.roomContext` builds it (`SourcesView.swift:106`), so the signature
        // this times is the one the sheet really evaluates rather than a cheaper cousin (L107).
        let geo = GeoRefusals(userExcludedTowns: Set(excluded.map(\.town)),
                              allowedSeedTowns: Set(allowedSeed.map(\.town)))
        let roster = DownbeatBridge.loadWithHealth(
            from: StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport,
                                                 isDebugBuild: false)
                .appendingPathComponent("downbeat-export.json"),
            now: now)
        return Live(prospects: prospects, sources: sources,
                    context: StageContext(now: now, geo: geo,
                                          clients: ClientWindow(sources: sources,
                                                                clients: roster.clients)),
                    clients: roster.clients,
                    dismissedIds: Set(dismissed.map(\.clientId)),
                    rosterHealth: roster.health)
    }

    private static func milliseconds(rounds: Int, _ body: () -> Void) -> Double {
        let started = Date()
        for _ in 0..<rounds { body() }
        return Date().timeIntervalSince(started) / Double(rounds) * 1000
    }

    // THE POSITIVE CONTROL, and it runs on every push.
    //
    // A change-key that never moves is a gate that never fires, and its recompute would then be dead
    // while the surface reads as cached and correct. Timing it would measure a number that means
    // nothing. This asserts each signature really does respond to its own input, so the readings below
    // are readings of a live gate (L171, L557: a check that has never once passed is measuring nothing).
    @Test func theWholeStoreDerivationsProduceSomethingToTime() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "k", groupName: "A Show", discipline: "choral", venue: "A Room",
                         performanceDate: "2099-01-01", sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.sourceIds = ["s1"]
        ctx.insert(p)
        try ctx.save()

        #expect(!SourceYield.tallies(in: [p]).isEmpty,
                "SourceYield.tallies produced nothing, so the reading below times an empty loop")

        // The one gate that REMAINS, and it has to still move on its own input or it caches forever.
        let s = WatchedSource(sourceId: "s1", orgName: "An Org", listingsURL: nil, kind: .html)
        let coverBefore = ClientCoverage.signature(sources: [s], clients: [], dismissedIds: [])
        s.orgName = "A Renamed Org"
        #expect(ClientCoverage.signature(sources: [s], clients: [], dismissedIds: []) != coverBefore,
                "ClientCoverage.signature does not move when a source name does, so its gate never fires")
    }

    // THE READING. Opt in, because it clones the live store and runs a stopwatch.
    //
    //   TEST_RUNNER_MEASURE_SOURCES_SHEET=1 mac/scripts/run-tests-locked.sh \
    //     -only-testing:OvertureTests/SourcesSheetCostTests
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func measureOneSourcesSheetRedraw() async throws {
        guard ProcessInfo.processInfo.environment["MEASURE_SOURCES_SHEET"] != nil else {
            print("sources-sheet-cost: not measured. Set TEST_RUNNER_MEASURE_SOURCES_SHEET=1 to run it.")
            return
        }
        await RealStoreTestLock.shared.acquire()   // #2198: released inline on both paths, never a Task
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory
                .appendingPathComponent("sources-sheet-cost-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }

            let now = Date()
            let l = try live(in: dir, now: now)
            let rounds = 10

            // Warmed, so the first pass's SwiftData faulting is not counted as the cost of a redraw.
            _ = SourceYield.tallies(in: l.prospects)
            _ = UnplacedRooms.from(l.prospects, context: l.context)
            _ = ClientCoverage.signature(sources: l.sources, clients: l.clients,
                                         dismissedIds: l.dismissedIds)

            // #3656: what the sheet pays NOW. The two hash gates are gone, so their recomputes ARE the
            // per-redraw cost; ClientCoverage's gate stays and its key is still what a redraw pays.
            let yieldRecompute = Self.milliseconds(rounds: rounds) {
                _ = SourceYield.tallies(in: l.prospects)
            }
            let roomsRecompute = Self.milliseconds(rounds: rounds) {
                _ = UnplacedRooms.from(l.prospects, context: l.context)
            }
            let coverSig = Self.milliseconds(rounds: rounds) {
                _ = ClientCoverage.signature(sources: l.sources, clients: l.clients,
                                             dismissedIds: l.dismissedIds)
            }
            // #3645: the FOURTH thing a redraw used to pay for, and the one that issue is about.
            // `SourcesView.roomContext` built this as an ARGUMENT to the room derivation, so every body
            // evaluation ran it; since #3645 it is decided when its inputs change and handed to
            // `SourcesRenderPass` as a value. Timed here so what the removal SAVED is a measured number
            // rather than an argument, and timed with a warm pass of its own first for the same reason
            // every reading above has one.
            _ = ClientWindow(sources: l.sources, clients: l.clients)
            let clientWindow = Self.milliseconds(rounds: rounds) {
                _ = ClientWindow(sources: l.sources, clients: l.clients)
            }
            let perRedraw = yieldRecompute + roomsRecompute + coverSig
            // The roster is a FILE, so it is the one input that can silently go missing and make the
            // coverage timing a measurement of the sources half alone. Reported with the number rather
            // than beside it, because a count and how it was obtained are one fact (L544).
            let rosterNote = l.rosterHealth == .ok
                ? "\(l.clients.count) clients"
                : "ROSTER \(l.rosterHealth), so the coverage key below is a LOWER BOUND"
            print(String(format: "sources-sheet-cost: over %d prospects, %d sources and %@, one body "
                         + "evaluation costs %.2f ms: SourceYield.tallies %.2f, UnplacedRooms.from %.2f, "
                         + "and the one remaining change-key ClientCoverage.signature %.2f. Since #3656 "
                         + "the first two are paid outright rather than gated on a hash of the store.",
                         l.prospects.count, l.sources.count, rosterNote, perRedraw,
                         yieldRecompute, roomsRecompute, coverSig))
            print(String(format: "sources-sheet-cost: and the fuzzy client match #3645 took OFF the "
                         + "render path, ClientWindow(sources:clients:), costs %.2f ms, which is %.0f%% "
                         + "of the %.2f ms above. It was paid on every body evaluation and is now paid "
                         + "only when a source name, a client tag or the roster changes.",
                         clientWindow, clientWindow / perRedraw * 100, perRedraw))

            #expect(l.prospects.count > 0, "the clone holds no prospects, so nothing here was measured")
            #expect(l.sources.count > 0,
                    Comment(rawValue: "the clone holds no watched sources, so the coverage half "
                            + "measured nothing"))
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
