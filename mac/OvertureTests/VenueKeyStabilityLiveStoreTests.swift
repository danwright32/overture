import Testing
import Foundation
import SwiftData

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
            // #1886: judged against the key the row SHOULD carry (Prospect.scoutAnchoredNaturalKey), which
            // is the same definition the launch re-key pass acts on rather than a second copy of it beside
            // it. Recomputing from `venue` here asked a different question: it read #1846's merged room
            // name, a deliberate DISPLAY change that leaves the key alone on purpose, as drift, so the
            // guard could not tell a renamed card from a fold that had genuinely moved under the store.
            let drifted = all.filter {
                venueHalf($0.scoutAnchoredNaturalKey) != venueHalf($0.naturalKey)
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

    // True when any BALANCED bracket pair in the string contains a comma. Scanned by depth so a string
    // with several bracket groups is judged group by group, which is the whole correction in #3314.
    // An UNBALANCED bracket matches nothing here, exactly as `VenueNormalization.strippingParentheticals`
    // leaves one alone, so the two readings agree about what a bracket is.
    private func commaInsideABracket(_ venue: String) -> Bool {
        var depth = 0
        var sawCommaAtDepth = false
        for character in venue {
            if character == "(" {
                depth += 1
                if depth == 1 { sawCommaAtDepth = false }
            } else if character == ")" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0 && sawCommaAtDepth { return true }
                }
            } else if character == "," && depth > 0 {
                sawCommaAtDepth = true
            }
        }
        return false
    }

    // #3314: the predicate itself, on the two real strings that exposed it, plus the shapes either side
    // of them. The live-store test above cannot cover this: since its assertion became a property of the
    // KEY rather than a claim of absence, a wrong predicate only widens the set it checks and every
    // member still passes, so reverting this scan to its old form there is invisible (proved by
    // mutation, SURVIVED). These cases are where the scan is actually pinned.
    @Test func aCommaBetweenTwoBracketsIsNotACommaInsideOne() {
        // The false positive. Two bracket groups, neither holding a comma, and the comma the old
        // first-open-to-last-close reading found sits between them, in the open.
        #expect(commaInsideABracket(
            "Montague Street (between Henry & Hicks Streets), Brooklyn Heights, NY (offsite)") == false)
        // The genuine one, from the same store on the same day.
        #expect(commaInsideABracket("St. Peter's Episcopal Church (Morristown, NJ)"))
        // The plain shapes either side, so the scan is not simply answering yes or no to everything.
        #expect(commaInsideABracket("Carnegie Hall") == false)
        #expect(commaInsideABracket("Carnegie Hall, New York") == false)
        #expect(commaInsideABracket("Somewhere (Times Square)") == false)
        // Nested, where the comma is deeper than the outermost pair.
        #expect(commaInsideABracket("A Room (a wing (east, west) of it)"))
        // An UNBALANCED bracket matches nothing, which is the same answer
        // `VenueNormalization.strippingParentheticals` gives it, so the two readings agree about what a
        // bracket is.
        #expect(commaInsideABracket("A Room (never closed, and so not a pair") == false)
    }

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

            // #3314: asked per BALANCED BRACKET GROUP, not from the first "(" to the last ")". That
            // earlier reading treated two separate brackets as one span, so
            // `Montague Street (between Henry & Hicks Streets), Brooklyn Heights, NY (offsite)` was
            // reported: neither of its brackets holds a comma, and the comma it found sits between them,
            // in the open. It fired on an ordinary address, which is how a guard gets switched off (L93).
            let spanning = venues.filter { commaInsideABracket($0) }

            // #3314: and what is asserted is the PROPERTY, not the absence. The dangerous thing about
            // this shape was never the shape: it was that the comma split ran BEFORE the bracket strip,
            // so `... (Morristown, NJ)` was cut into a fragment ending in an unbalanced "(" that the
            // stripper could not match, and the key silently moved. #1764 fixed that by stripping before
            // the split as well as after, which means a venue of this shape is now folded correctly and
            // its arrival is not a defect.
            //
            // Kept as a live-store guard rather than deleted, because the property is worth pinning on
            // real data: for every such venue the key must carry no bracket at all. A leftover "(" in a
            // key is the #1764 defect itself, and it is what an assertion of mere absence could never
            // have caught, since absence stops being checkable the moment such a venue appears.
            for venue in spanning.sorted() {
                let key = VenueNormalization.keyName(venue)
                #expect(!key.contains("(") && !key.contains(")"),
                        "the fold left a bracket in this venue's key, which is the #1764 defect: VENUE[\(venue)] KEY[\(key)]")
            }
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
