import Testing
import Foundation
import SwiftData

// #3691 found this, and #3654's CORRECTION A1 is what it is for.
//
// A1 is the decision that sets Phase 4's target. It rules that card keys are the RENDERED rows plus a
// lookahead rather than the focused STAGE, and the whole ruling rests on one arithmetic: Scout holds
// about 611 shows, 478 of them inside the window, and at 0.368 ms per card that leaves Scout at roughly
// 264 ms, so the 100 ms bar is missed on the only stage Dan works in and the tenfold headline is really
// 2.4x there.
//
// EVERY ONE OF THOSE NUMBERS WAS MEASURED BY HAND ON 2026-09-07 AND NOTHING RE-MEASURES THEM. No
// `LIVE-SHAPE` tag covers the Scout stage or its in-window subset, so `check-fixture-corpus-drift.sh`
// cannot see either, and a figure with a date beside it reads as more trustworthy the older it gets
// (L316, L354, L32). The store grows every night the scout runs and drains every time Dan triages, so
// this is a number that MOVES, quoted as though it were a property of the code.
//
// WHY THIS IS A SWIFT TEST AND NOT A `LIVE-SHAPE` TAG, which was the obvious first answer. The tags are
// answered by one SQL statement each in `scripts/check-fixture-corpus-drift.sh`, and `.scout` cannot be
// written as one honestly. `StageNavigation.matches` asks four things: the status is `.new`, the show
// has not opened, it is within lead time (90 days OR a past client's year, #2365), and the geography
// gate does not hide it. Reimplementing that in SQL is a second definition of the rule, written beside
// the code rather than by it, and it would drift in whichever direction flatters whoever wrote it
// (L107). Worse, the omissions do not point the same way: dropping the client arm makes the count too
// LOW while dropping `hasOpened` and the geo gate make it too HIGH, so the result would not even be a
// bound. So this asks the app's own predicate, once, exactly as the queue asks it.
//
// WHAT IT DOES NOT DO. It does not gate on the count moving, because the store moves nightly in both
// directions and a guard that fires on ordinary movement has its threshold raised until it catches
// nothing (L36, L93). It fails in ONE direction only, the direction that hides the problem: the recorded
// figure sitting materially BELOW the live one, which is exactly when A1's arithmetic understates what
// Scout would cost and the phase's target has been set too low. Same rule and same tolerance as
// `check-fixture-corpus-drift.sh`, for the same reason.
//
// Reads a WAL-inclusive read-only clone and writes nothing anywhere.
@Suite("What the focused-stage rule would cost on Scout, re-derived (#3654 CORRECTION A1)")
final class ScoutStageCardLoadLiveStoreTests {
    private let sandboxes = TemporarySandboxes()

    // LIVE-STORE-CLAIM verified=2026-09-08 measure="shows in the Scout stage, by StageNavigation's own predicate, on the live store"
    // CORRECTION A1's second figure, which is the one its arithmetic multiplies. The first (about 611)
    // is the pre-window population and is already approximated by the `untriaged` LIVE-SHAPE dimension.
    //
    // THE FIRST RE-DERIVATION, 2026-09-08, one day after A1 was written: **426**, with the roster reading
    // `ok` and 18 client sources, against A1's 478. So the record is not understated today and this
    // passes. Two things about that reading are worth having in writing rather than rediscovering.
    //
    // IT MOVES, and by more than anybody assumed. 478 to 426 is 11% in ONE DAY, because Scout grows every
    // night the scout runs and drains every time Dan triages. A figure that swings that far is not a
    // property of the code and must not be quoted as one, which is the whole reason this test exists.
    //
    // AND A1'S OWN ARITHMETIC DOES NOT RECONCILE. It states 478 rows at 0.368 ms per card and concludes
    // "about 264 ms". 478 x 0.368 is 176 ms; 611 x 0.368 is 225 ms; 264 ms needs about 717 rows, which is
    // neither of its figures. Recomputed against today's 426 the same way, Scout is about 157 ms. A1's
    // RULING still stands on that number, because 157 ms misses the 100 ms bar just as 264 ms did, so
    // card keys being the rendered rows rather than the focused stage is unaffected. What does not stand
    // is the size of the margin and the "really 2.4x there" headline beside it. Recorded here rather than
    // corrected in the issue, because the arithmetic is Dan's plan council's and the discrepancy is a
    // finding to put to it (L249: a decision attributed inside an artifact is the one claim nobody
    // re-checks).
    private static let recordedScoutStageRows = 478

    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    // How far below the live figure the record may sit before it is refused. Deliberately the same 10%
    // as `OVERTURE_CORPUS_DRIFT_TOLERANCE`, because it is the same question about the same store.
    private static let tolerancePercent = 10

    struct Measured {
        var prospects: Int
        var scoutStageRows: Int
        var rosterHealth: DownbeatBridge.Health
        var clientSources: Int
        var excludedTowns: Int

        /// Whether `scoutStageRows` is the stage or only a floor under it. The client arm of the
        /// lead-time window (#2365) is the one input that comes from a file rather than the store, so a
        /// roster that did not read leaves every past client's far-out show OUT of this count and the
        /// real stage is larger. Carried WITH the number rather than beside it, because a count and the
        /// story of how it was obtained are one fact and separating them is how a bound comes to be
        /// quoted as a measurement (L544).
        var isALowerBound: Bool { rosterHealth != .ok }
        var reading: String { isALowerBound ? "a LOWER BOUND on the stage" : "the stage" }
    }

    /// Where Dan's real export lives for the RELEASE build, built from the pure helper so no redirect
    /// and no build flag is involved in deciding it.
    private static var releaseRosterURL: URL {
        StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
            .appendingPathComponent("downbeat-export.json")
    }

    /// The roster, read through the app's own reader and READ ONLY. An absent or unreadable export is
    /// not a failure here: it is a machine state this test cannot set (L411), and it is reported as one.
    ///
    /// It was written to take a COPY first, on `LiveStoreClone`'s precedent, and that was wrong twice
    /// over. `LiveStoreCopyGuardTests.nothingButTheHelperCopiesTheLiveStore` refused it, correctly by its
    /// own rule (a file that names the live store path AND copies files is doing by hand what the shared
    /// clone does once), and the honest answer to a guard refusing you is not to spell the same operation
    /// differently. It was also no safer: a copy of a file being rewritten is torn exactly as a read of it
    /// is, and the tear is handled either way, because a half-written export fails to decode and arrives
    /// as `.unreadable`, which this reports rather than believes.
    ///
    /// Nothing here writes. That is what makes reading the real path acceptable where #2097's redirect of
    /// `StoreLocation.handoffDirectory` would otherwise apply: that redirect exists so a test run cannot
    /// WRITE into Dan's handoff directory, and this suite already reads his real store the same way.
    private func roster(now: Date) -> (clients: [DownbeatClient], health: DownbeatBridge.Health) {
        let loaded = DownbeatBridge.loadWithHealth(from: Self.releaseRosterURL, now: now)
        return (loaded.clients, loaded.health)
    }

    private func measure(now: Date = Date()) throws -> Measured {
        let dir = try sandboxes.make(named: "scout-stage-load")
        // #1672: through the ONE shared clone, never a file-at-a-time copy, or whatever this concludes is
        // a statement about a torn snapshot rather than about Dan's data.
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let schema = Schema([Prospect.self, Recipient.self, WatchedSource.self,
                             ExcludedTown.self, AllowedSeedTown.self])
        let ctx = ModelContext(try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: clone, cloudKitDatabase: .none)]))

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let sources = try ctx.fetch(FetchDescriptor<WatchedSource>())
        let excluded = try ctx.fetch(FetchDescriptor<ExcludedTown>())
        let allowedSeed = try ctx.fetch(FetchDescriptor<AllowedSeedTown>())

        // Built the way `RootView` builds them (`RootView.swift:112` and `:119`), not a second
        // arrangement of the same inputs. The roster is a file rather than a store row, so its HEALTH is
        // carried beside it: an empty roster from a file that could not be read and an empty roster from
        // a file that genuinely holds none are different facts, and only one of them may be believed
        // (L544, and the reason `ClientRoster` keeps `health` at all).
        //
        // It has to name the RELEASE path explicitly, which is the part that bit. The test bundle is a
        // Debug build, so `DownbeatBridge.loadWithHealth()` with no argument resolves this build's own
        // handoff directory, and pairing the Release STORE with the Debug build's ROSTER is two machines'
        // answers to one question. The first version of this test did exactly that and reported the
        // roster as `.missing` on a Mac that has one; the health reading is what caught it, which is the
        // whole reason it is carried rather than assumed.
        let loaded = roster(now: now)
        let geo = GeoRefusals(userExcludedTowns: Set(excluded.map(\.town)),
                              allowedSeedTowns: Set(allowedSeed.map(\.town)))
        let window = ClientWindow(sources: sources, clients: loaded.clients)
        let context = StageContext(now: now, geo: geo, clients: window)

        // THE APP'S OWN PREDICATE. `StageNavigation.counts` is what the stage pills and the focused list
        // both ask, so this is the number the focused-stage card rule would actually have built (L107).
        let counts = StageNavigation.counts(in: all, context: context)

        return Measured(prospects: all.count,
                        scoutStageRows: counts[.scout] ?? 0,
                        rosterHealth: loaded.health,
                        clientSources: window.clientSourceIds.count,
                        excludedTowns: excluded.count)
    }

    /// The L98 half. A store that is present and a predicate that answered zero look exactly like a
    /// measurement nobody took, and the emptiest possible failure must not read as the cleanest possible
    /// answer. This is what makes the drift assertion below a bound on something.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theScoutStageIsMeasuredRatherThanAssumed() async throws {
        await RealStoreTestLock.shared.acquire()   // #2198: released inline on both paths, never from a Task
        do {
            let m = try measure()
            print("scout-stage-load: prospects=\(m.prospects) scoutStageRows=\(m.scoutStageRows) "
                  + "(\(m.reading)) recorded=\(Self.recordedScoutStageRows) "
                  + "roster=\(m.rosterHealth) clientSources=\(m.clientSources) "
                  + "excludedTowns=\(m.excludedTowns)")

            #expect(m.prospects > 0,
                    "the clone holds no prospects at all, so nothing here was measured")
            #expect(m.scoutStageRows > 0,
                    Comment(rawValue: "StageNavigation put NO show in .scout on a store of "
                            + "\(m.prospects) prospects. That is a broken measurement rather than an "
                            + "empty stage: the drift bound below would then pass against nothing."))
            // The roster is REPORTED and never asserted. Whether Dan's Downbeat export is on this
            // machine is a state this test cannot set from inside itself, and a red there would be
            // indistinguishable from a real finding while making every other failure in the list
            // unreadable (L411). What it costs is carried on the number itself, as `isALowerBound`.
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    /// The half that keeps CORRECTION A1 honest. Fails in one direction only.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theRecordedFigureHasNotFallenMateriallyBelowTheLiveOne() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let m = try measure()
            let floor = m.scoutStageRows - (m.scoutStageRows * Self.tolerancePercent / 100)
            #expect(Self.recordedScoutStageRows >= floor,
                    Comment(rawValue: "CORRECTION A1 multiplies \(Self.recordedScoutStageRows) Scout "
                            + "rows; the live store gives \(m.scoutStageRows) today as \(m.reading), "
                            + "which is more than "
                            + "\(Self.tolerancePercent)% above it. A1's estimate of what a focused-stage "
                            + "card rule would cost on Scout is therefore understated, in the direction "
                            + "that makes the bar look reachable. Re-take the reading, update this "
                            + "constant with today's date, and re-check A1's arithmetic before Phase 4 "
                            + "sets its card-key rule."))
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
