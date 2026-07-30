import Testing
import Foundation
import SwiftData
@testable import Overture

// #1764: the venue fold builds every prospect's natural key, so a change to it can silently re-key the
// live store, which is a migration rather than a fix (#1064 needed NaturalKeyVenueMigration for exactly
// that reason). The reordering in VenueNormalization.keyName was made in the fold itself only because
// it was measured to move no venue in the store. This pins that measurement, so the next person to
// widen the fold finds out here rather than after Dan's queue has split in two.
//
// Gated on the live store existing, so a machine without one reports a visible SKIP rather than a silent
// pass. Reads a copy and writes nothing anywhere.
@Suite("The venue fold re-keys nothing in the live store (#1764)")
struct VenueKeyStabilityLiveStoreTests {
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

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="stored prospect natural keys whose VENUE half still recomputes to itself under the current fold"
    // The direct proof, and the one that matters: recompute each row's key and compare its VENUE half
    // with the half actually stored. A fold change that moves any venue shows up here as a row whose
    // stored key no longer reproduces, which is precisely a row Dan would start seeing twice.
    //
    // Deliberately the venue COMPONENT rather than the whole key, and this is not a convenience. Running
    // it over the whole key on 2026-07-29 found four rows already drifting in their TITLE half, from
    // #1590 strengthening the title fold without re-keying the rows written before it. Those four are two
    // real duplicate pairs sitting in the queue now ("Bone Wars: A New Musical" against "Bone Wars (A New
    // Musical)", and "macMcCarty +KiddTwist" against "macMcCarty + KiddTwist"), filed separately. Folding
    // them into this guard would have meant either weakening it until it proved nothing or blocking a
    // venue fix behind an unrelated title backfill, and it would have given one status to two independent
    // checks, which is how a real failure gets hidden by an unrelated pass (LESSONS L53).
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func everyStoredVenueKeyStillReproducesUnderTheCurrentFold() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1764-live-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            let storeCopy = try copyLiveStore(to: scratch)

            let ctx = ModelContext(try openContainer(at: storeCopy))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            #expect(all.count > 100, "the live store still holds a real queue to measure")

            // The key is "title|date|venue", so the venue half is the last component.
            func venueHalf(_ key: String) -> String {
                String(key.split(separator: "|", omittingEmptySubsequences: false).last ?? "")
            }
            let drifted = all.filter {
                let recomputed = Prospect.makeNaturalKey(groupName: $0.groupName,
                                                         performanceDate: $0.performanceDate,
                                                         venue: $0.venue)
                return venueHalf(recomputed) != venueHalf($0.naturalKey)
            }
            let detail = drifted.map {
                "STORED[\($0.naturalKey)] VENUE[\($0.venue ?? "")]"
            }.joined(separator: " ;; ")
            #expect(drifted.isEmpty, "rows whose stored venue key no longer reproduces: \(drifted.count) :: \(detail)")

            // Non-vacuous: the comparison is actually reaching venues that the fold reduces, rather than
            // passing because every venue happens to be a bare name the fold leaves alone.
            let reduced = all.filter {
                guard let v = $0.venue, !v.isEmpty else { return false }
                return VenueNormalization.keyName(v) != v
            }
            #expect(reduced.count > 20, "the fold is still doing real work on this store's venues")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="distinct venue strings holding a bracket pair that spans a comma"
    // The shape whose key the #1764 reordering moves, counted directly. Measured at ZERO venues (of 140
    // distinct, 3 of which carry a bracket at all), which is why the change needed no migration. The
    // presenter side had exactly one, The Golden Hour Series, and presenters do not feed the natural key.
    //
    // Asserted separately from the test above because the two fail for different reasons and a single
    // status shared between them would let one hide the other: this one says "a venue of the dangerous
    // shape has appeared", the other says "a key has actually moved".
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func noVenueCarriesABracketSpanningAComma() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1764-shape-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            let storeCopy = try copyLiveStore(to: scratch)

            let ctx = ModelContext(try openContainer(at: storeCopy))
            let venues = Set(try ctx.fetch(FetchDescriptor<Prospect>()).compactMap { $0.venue })
            #expect(venues.count > 50, "the live store still holds a real spread of venues to measure")

            let spanning = venues.filter { venue in
                guard let open = venue.firstIndex(of: "("),
                      let close = venue.lastIndex(of: ")"),
                      let comma = venue.firstIndex(of: ","),
                      open < close else { return false }
                return open < comma && comma < close
            }
            #expect(spanning.isEmpty,
                    "venues whose bracket spans a comma, so the fold now reduces them further: \(spanning.sorted())")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
