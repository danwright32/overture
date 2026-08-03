import Testing
import Foundation
import SwiftData

// #1763: prove against a COPY of Dan's real store that the row never offers a correction the gate would
// ignore. The unit tests next door pin the rule on hand-built rows; this one asks whether it bites on the
// real population, because the whole defect was a claim about scale (15 organisations and 312 rows, 43%
// of the store, every one of them offering a control that did nothing).
//
// Gated on the live store existing, so a machine without one reports a visible SKIP rather than a silent
// pass. Reads a copy and writes nothing anywhere.
@Suite("The correction is offered only where it can bite, live store (#1763)")
struct ProducerCorrectionLiveStoreTests {
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    private func copyLiveStore(to dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("Overture.store")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: Self.liveStoreURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: URL(fileURLWithPath: dest.path + suffix))
        }
        return dest
    }

    private func openContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      url: url, cloudKitDatabase: .none)])
    }

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="presenters judged the building by the equality arm, the rows they cover, and whether promoting each moves the verdict"
    // Measured 2026-07-29 over 724 rows: of the 22 presenters judged the building, 15 are refused by the
    // EQUALITY arm covering 312 rows, and promoting each leaves all 15 refused. The other 7 (39 rows) are
    // caught only by containment, where promotion genuinely works.
    //
    // Asserted as an INVARIANT plus a non-empty population rather than as those counts, because the store
    // grows every night and a pinned number would fail tomorrow for no reason. The population assertion is
    // the half that matters: without it this test would keep passing after the rule stopped applying to
    // anything, which is exactly how a guard goes vacuous long after it was real.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func noRowOffersACorrectionTheGateWouldIgnore() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1763-live-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            let storeCopy = try copyLiveStore(to: scratch)

            let ctx = ModelContext(try openContainer(at: storeCopy))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            #expect(all.count > 100, "the live store still holds a real queue to measure")

            let items = QueueModel.items(from: all)
            let brands = ProducerGate.VenueBrands(
                shows: all.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) })

            // The invariant: no row spelled exactly like its room offers a correction, since promoting it
            // would be stored and then ignored.
            let offeredAnyway = items.filter {
                $0.correctableOrganisation != nil && brands.isRoomName($0.presenter)
            }
            #expect(offeredAnyway.isEmpty,
                    "rows offering a correction the gate ignores: \(offeredAnyway.count)")

            // #1966: this used to require more than 50 such rows, and on 2026-08-02 it went red at 12.
            //
            // Nothing regressed. #1952's RoomPresenterSweep shipped the night before and cleared 111 rows
            // whose presenter was their own room, which is the population this line was counting. The
            // floor was therefore asserting that a shipped fix had NOT worked, and it would have gone red
            // on whichever run came first after Dan next opened the app.
            //
            // The vacuity guard is still needed, so it moved off the wreckage and onto the RULE: the
            // equality arm must still recognise a room name when it meets one. That cannot be emptied by
            // a sweep, and it fails just as loudly if `isRoomName` ever stops matching. The live half now
            // asserts only what a live store can honestly say: whatever rows remain in this state, none of
            // them offers a correction the gate would ignore (above), and the store is a real one (below).
            let aRoomInThisStore = all.compactMap(\.venue).first { !$0.isEmpty }
            #expect(aRoomInThisStore != nil, "the live store still names rooms to recognise")
            if let room = aRoomInThisStore {
                let asItsOwnPresenter = ProducerGate.VenueBrands(
                    shows: [ProducerGate.Show(presenter: room, venue: room)])
                #expect(asItsOwnPresenter.isRoomName(room),
                        "the equality arm must still recognise a room standing in as its own presenter")
            }

            // And it did not silence everything: an organisation caught only by name overlap, or not
            // judged a building at all, must KEEP its control, or this fix has traded one defect for the
            // opposite one.
            let stillCorrectable = items.filter { $0.correctableOrganisation != nil }
            #expect(stillCorrectable.count > 50,
                    "corrections are still offered where they can actually move the verdict")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
