import Testing
import Foundation
import SwiftData

// #1785: ProducerGate reaches ONE judgment about a name, and four things consume it, each asking a
// slightly different question. Nothing failed when their answers disagreed.
//
// That is not hypothetical. Measured 2026-07-29: `ProducerGate.houses` hands the prep run 127 entries
// while the venue-brand arms refuse 22 presenters. Both are correct for their own question (the house
// list carries every venue string, not only presenters), and the milestone 34 plan was nonetheless
// drafted stating 22 for a surface whose refusals during a real prep run come from 127. That is #1702's
// failure mode one layer up: the judgment is single, the readings of it are not.
//
// The consumers cannot simply be collapsed, because each genuinely needs a different slice. What was
// missing is anything that fails when they disagree about the SAME name, which is the only part that is
// ever a bug. So these assert INVARIANTS between them rather than counts, which move nightly.
//
// Gated on the live store existing, so a machine without one reports a visible SKIP rather than a silent
// pass. Reads a copy and writes nothing anywhere.
@Suite("The gate's consumers agree about the same name, live store (#1785)")
struct GateConsumersAgreeLiveStoreTests {
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    // #1672: through the ONE shared clone. Copying the .store, its -wal and its -shm one file at a
    // time races a live writer, and a clone whose -wal does not match the .store beside it makes
    // whatever this suite concludes a statement about a torn copy rather than about Dan's data.
    // LiveStoreClone takes it through SQLite's online backup instead.
    private func copyLiveStore(to dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        return clone
    }

    private func openContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      url: url, cloudKitDatabase: .none)])
    }

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="presenters the venue-brand arms refuse, against the house list handed to the prep run and the verdict the organisation listing states"
    // Three sentences that are each either true or a bug, over every presenter in the real store.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func everyConsumerSaysTheSameThingAboutTheSameName() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1785-live-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            let storeCopy = try copyLiveStore(to: scratch)

            let ctx = ModelContext(try openContainer(at: storeCopy))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            #expect(all.count > 100, "the live store still holds a real queue to measure")

            let gateShows = all.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) }
            let brands = ProducerGate.VenueBrands(shows: gateShows)
            let houseKeys = Set(ProducerGate.houses(shows: gateShows).map(\.key))
            let listing = OrganisationListing.build(shows: all.map {
                OrganisationListing.Show(presenter: $0.presenter, venue: $0.venue, title: $0.groupName)
            })
            #expect(listing.count > 50, "the derivation still reaches a real spread of organisations")

            // 1. A presenter the arms refuse is a house, so the prep run must be told about it. If it is
            //    not, the run is free to walk to that organisation and offer the building's own address,
            //    which is the whole thing #1720 handed it a list to prevent.
            //
            //    KNOWN LIMIT, found by breaking it: this bites only on a presenter that is NOT itself a
            //    venue string. `houses` seeds its keys from every venue in the store, so the 15 names the
            //    EQUALITY arm refuses are already on the list by another route and dropping them from the
            //    presenter pass changes nothing. Sabotaging "jalopy theatre" left this green; sabotaging
            //    "carnegie hall presents" (containment only, 28 rows) turned it red. Recorded rather than
            //    left implicit, because a guard whose coverage is narrower than it reads is how one goes
            //    quietly vacuous.
            let refusedButNotHanded = listing
                .filter { $0.verdict == .theBuilding }
                .filter { !houseKeys.contains($0.key) }
            #expect(refusedButNotHanded.isEmpty,
                    "read as the building but missing from the prep run's house list: \(refusedButNotHanded.map(\.name).sorted())")

            // 2. The opposite direction. An organisation whose single answer is reused across its shows is
            //    a producer by definition, so it must NOT be on the list of names the run refuses. Being on
            //    both is a contradiction: the app would pay to find its contact and the run would decline
            //    to use it.
            let sharingButRefused = listing
                .filter { $0.verdict == .sharesOneAnswer }
                .filter { houseKeys.contains($0.key) }
            #expect(sharingButRefused.isEmpty,
                    "shares one answer yet handed to the run as a house: \(sharingButRefused.map(\.name).sorted())")

            // 3. The card and the sheet must state the same verdict. `treatedAsVenue` is what the row reads
            //    to decide whether to print a presenter's name; the listing is what the Presenters sheet
            //    states. Two surfaces disagreeing about one name is exactly the defect this issue names.
            let disagreements = listing.filter { entry in
                brands.contains(entry.name) != (entry.verdict == .theBuilding)
            }
            #expect(disagreements.isEmpty,
                    "the row and the sheet disagree about: \(disagreements.map(\.name).sorted())")

            // Non-vacuous: each comparison is actually reaching a real population rather than passing
            // because one side is empty.
            #expect(listing.contains { $0.verdict == .theBuilding })
            #expect(listing.contains { $0.verdict == .sharesOneAnswer })
            #expect(houseKeys.count > listing.filter { $0.verdict == .theBuilding }.count,
                    "the house list still carries the rooms as well as the presenters")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
