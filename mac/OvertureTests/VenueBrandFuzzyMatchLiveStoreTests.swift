import Testing
import Foundation
import SwiftData
@testable import Overture

// #1702: prove the venue-brand exclusion against a COPY of Dan's real store, which is the only place the
// defect is visible. The unit tests next door pin the rule on two hand-built shows; this one asks whether
// the rule, meeting 700-odd real rows and 114 real venue spellings, refuses what it should and keeps what
// he still needs.
//
// Gated on the live store existing, so a machine without one reports a visible SKIP rather than a silent
// pass. Reads a copy and writes nothing anywhere.
@Suite("Venue-brand presenters, live store (#1702)")
struct VenueBrandFuzzyMatchLiveStoreTests {
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

    // LIVE-STORE-CLAIM verified=2026-07-28 measure="rows a history record named only for a hall's series brand would flag, before and after the exclusion"
    // Measured 2026-07-28: this record flags 18 rows without the exclusion (every Carnegie Hall show in
    // the store, none of them related to it) and 0 with it. #1693 fixed the case where the act's name was
    // deleted by the subtitle strip; this is the same 18 cards reached by a record that needs no strip at
    // all, which is why that fix alone did not close the class.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func aRecordNamedForAHallsOwnSeriesFlagsNothing() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1702-live-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            let storeCopy = try copyLiveStore(to: scratch)

            let ctx = ModelContext(try openContainer(at: storeCopy))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            let venueBrands = ProducerGate.VenueBrands(
                shows: all.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) })
            let record = [HistoryRecord(groupName: "Carnegie Hall Citywide", status: "declined")]

            func flagged(_ brands: ProducerGate.VenueBrands) -> [Prospect] {
                all.filter { p in
                    HistoryMatch.matchRelationship(name: p.groupName, presenter: p.presenter,
                                                   venue: p.venue, clients: [], history: record,
                                                   venueBrands: brands).possible != nil
                }
            }

            // The defect is real on this store, not hypothetical: without the exclusion the record reaches
            // a crowd. Asserted so this test can never quietly become a tautology about an empty store.
            #expect(flagged(.none).count > 1)
            #expect(flagged(venueBrands).isEmpty)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // LIVE-STORE-CLAIM verified=2026-07-28 measure="Downbeat clients whose name is also a venue name in the store, and the rows recognised as that client through the presenter field alone"
    // The one client that is also a room. Chain Theatre is one of Dan's 30 Downbeat clients AND a venue
    // string in the store, and three shows read as his past client through the presenter field: two are
    // billed "Summer One-Act Festival", which carries no part of the name, and the third, "Chain NYC Film
    // Festival", falls under the containment guard. Excluding a venue-brand presenter from CONFIDENT
    // matching too, which is the tempting simplification, would read all three cold.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theOneClientThatIsAlsoARoomStillReadsAsAPastClient() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1702-chain-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            let storeCopy = try copyLiveStore(to: scratch)

            let ctx = ModelContext(try openContainer(at: storeCopy))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            let venueBrands = ProducerGate.VenueBrands(
                shows: all.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) })
            let chain = [DownbeatClient(id: "chain", displayName: "Chain Theatre", shortName: nil,
                                        email: "a@b.org", contractEmail: "a@b.org", phoneNumber: nil,
                                        isTaxExempt: nil, hasLeftReview: false, specialBehaviors: [],
                                        notes: nil, hostingSite: "pixieset")]

            let itsShows = all.filter { ProducerGate.key($0.presenter) == ProducerGate.key("Chain Theatre") }
            #expect(!itsShows.isEmpty, "the live store still holds shows presented by this client")
            // The presenter IS a venue brand here, which is exactly what makes it the case worth pinning.
            #expect(venueBrands.contains("Chain Theatre"))
            for show in itsShows {
                let v = HistoryMatch.matchRelationship(name: show.groupName, presenter: show.presenter,
                                                       venue: show.venue, clients: chain, history: [],
                                                       venueBrands: venueBrands)
                #expect(v.relationship == .booked)
                #expect(v.matchedClientName == "Chain Theatre")
            }
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // The three possible matches that were genuine when this was measured must survive, since the whole
    // risk of tightening a fuzzy gate is losing the true positives with the false ones. Written as "the
    // flags that exist still exist" rather than pinned to three rows, so it stays honest as the store moves.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theGenuinePossibleMatchesSurvive() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1702-keep-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            let storeCopy = try copyLiveStore(to: scratch)

            let ctx = ModelContext(try openContainer(at: storeCopy))
            let inputs = PossibleMatchRecheck.Inputs(
                clients: DownbeatBridge.loadWithHealth(
                    from: StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport,
                                                         isDebugBuild: false)
                        .appendingPathComponent("downbeat-export.json"), now: Date()).clients,
                history: LocalHistory.forMatching(
                    existing: try ctx.fetch(FetchDescriptor<Prospect>()),
                    importedFrom: StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport,
                                                                 isDebugBuild: false)
                        .appendingPathComponent("overture-history.json")))
            guard !inputs.clients.isEmpty else { return await RealStoreTestLock.shared.release() }

            PossibleMatchRecheck.run(in: ctx, loadInputs: { _ in inputs })
            try ctx.save()

            let after = try ctx.fetch(FetchDescriptor<Prospect>())
                .filter { !($0.possibleMatchName ?? "").isEmpty }
            #expect(!after.isEmpty, "the real near-misses Dan still has to answer are untouched")
            // None of them may be a question raised by a room's own brand any more.
            let venueBrands = ProducerGate.VenueBrands(
                shows: try ctx.fetch(FetchDescriptor<Prospect>())
                    .map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) })
            for p in after where venueBrands.contains(p.presenter) {
                // It survived on its title, never on the building's name.
                #expect(GroupNameMatch.isPossible(p.groupName, p.possibleMatchName ?? ""))
            }
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
