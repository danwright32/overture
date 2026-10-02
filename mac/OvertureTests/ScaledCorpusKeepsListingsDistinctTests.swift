import Testing
import Foundation
import SwiftData

// #4106: `Phase0.scaledCopy` builds the 4x corpus every Phase 0, 0b and 0c probe reads. It gave each copy a
// new identity (key, presenter, venue, title) but copied `sourceListingURL` and `runSourceURLs` unchanged, so
// at 4x every listing held four times the rows under four different titles. Any term grouped by listing
// (`ShowLink.ambiguousURLs` compares each row against every distinct show at its URL, pairwise) then read
// about sixteen times dearer than a real store four times the size would make it. Found by the #4275
// attribution (comment 5850754843 there) and recorded on #4106 before Gate 0c relied on those figures.
//
// The corpus must scale the DISTRIBUTION, not stack rows (L391): a listing in the clone holding N shows holds
// N shows in each copy, never 4N in one.
@Suite("The scaled corpus gives each copy its own listings (#4106)")
struct ScaledCorpusKeepsListingsDistinctTests {
    private struct Listings: Equatable {
        let listing: Int
        let run: Int
        let largestListing: Int
    }

    private func listings(_ rows: [Prospect]) -> Listings {
        var perListing: [String: Int] = [:]
        for r in rows { if let u = r.sourceListingURL, !u.isEmpty { perListing[u, default: 0] += 1 } }
        let run = Set(rows.flatMap(\.runSourceURLs).filter { !$0.isEmpty }).count
        return Listings(listing: perListing.count, run: run, largestListing: perListing.values.max() ?? 0)
    }

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func eachCopyHasItsOwnListings() async throws {
        await RealStoreTestLock.shared.acquire()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("scaled-urls-\(UUID().uuidString)", isDirectory: true)
        // #4061: the stores are released and the directory removed INSIDE the real-store lock on both paths,
        // the ordering #1608 fixed in ImmutableStoreFixture; a `defer` here would run after the release.
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let base = listings(try ModelContext(Phase0.openContainer(at: clone)).fetch(FetchDescriptor<Prospect>()))
            #expect(base.listing > 0 && base.run > 0,
                    "the clone holds no listing addresses, so nothing below measured anything")

            let scaled = try Phase0.scaledCopy(of: clone, factor: 2, in: dir)
            let got = listings(try ModelContext(Phase0.openContainer(at: scaled)).fetch(FetchDescriptor<Prospect>()))

            #expect(got.listing == 2 * base.listing,
                    "listing addresses: clone \(base.listing), 2x copy \(got.listing), expected \(2 * base.listing)")
            #expect(got.run == 2 * base.run,
                    "run addresses: clone \(base.run), 2x copy \(got.run), expected \(2 * base.run)")
            #expect(got.largestListing == base.largestListing,
                    "the fullest listing held \(base.largestListing) shows in the clone and \(got.largestListing) in the copy")
            FileStores.remove(dir)
            await RealStoreTestLock.shared.release()
        } catch {
            FileStores.remove(dir)
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // #4372: the corpus as it stood before #4288, which the attribution probe rebuilds to reproduce 0b.6's
    // reading. Every copy keeps its original's listing addresses, so no address is added and the fullest
    // listing holds twice the shows. If this option silently glued anyway, the probe's historical arm would
    // measure today's corpus under the old name and report that the old reading cannot be reproduced.
    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theHistoricalCorpusSharesEachListingWithItsCopies() async throws {
        await RealStoreTestLock.shared.acquire()
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("scaled-urls-old-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let base = listings(try ModelContext(Phase0.openContainer(at: clone)).fetch(FetchDescriptor<Prospect>()))
            #expect(base.listing > 0 && base.run > 0,
                    "the clone holds no listing addresses, so nothing below measured anything")

            let scaled = try Phase0.scaledCopy(of: clone, factor: 2, in: dir, reidentifyListings: false)
            let got = listings(try ModelContext(Phase0.openContainer(at: scaled)).fetch(FetchDescriptor<Prospect>()))

            #expect(got.listing == base.listing,
                    "listing addresses: clone \(base.listing), shared 2x copy \(got.listing), expected \(base.listing)")
            #expect(got.run == base.run,
                    "run addresses: clone \(base.run), shared 2x copy \(got.run), expected \(base.run)")
            #expect(got.largestListing == 2 * base.largestListing,
                    "the fullest listing held \(base.largestListing) shows in the clone and \(got.largestListing) in the shared copy")
            FileStores.remove(dir)
            await RealStoreTestLock.shared.release()
        } catch {
            FileStores.remove(dir)
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
