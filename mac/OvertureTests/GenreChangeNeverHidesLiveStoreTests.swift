import Testing
import Foundation
import SwiftData

// #1658: a change to how the genre is read must never newly HIDE a show.
//
// Genre picks the geographic rule. `Discipline.staysInTheBoroughs` is true for music and band and false
// for everything else, so a row that reads `other` or `opera` today travels the tri-state area and a row
// that reads `music` stops at the five boroughs. Re-reading the genre therefore has a consequence nothing
// about genre would suggest: an upstate row moving from opera to music vanishes from the queue.
//
// It is not hypothetical. Two Chautauqua Opera rows sit in exactly that state (location "Chautauqua, NY"),
// inert only because Dan already dismissed them and `GeoRefusals.isOvertureToCut` spares a dismissed row.
// The OPERA America feed is pre-narrowed to NY/NJ/CT and routinely delivers upstate rows, so this recurs.
//
// Dan's call (2026-08-07), shown the two rows this phase moves: read the title as the genre, and keep the
// row visible where the genre change alone is what would have removed it. `GenreVisibility.write` is where
// that lives, and this guard drives THAT, on his real rows, rather than restating its rule: it re-reads
// each visible row's genre, writes it the way the app writes it, and fails if the row goes.
//
// A durable claim rather than a one-off measurement of this phase: any later classifier change that would
// quietly remove a live row from Dan's queue trips it too.
//
// Reads a copy of the live store and writes nothing anywhere.
@Suite("No genre change hides a show that is showing (#1658)")
struct GenreChangeNeverHidesLiveStoreTests {
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    // #1672: through the ONE shared clone, so what this concludes is a statement about Dan's data rather
    // than about a copy torn by a live writer.
    private func copyLiveStore(to dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        return clone
    }

    // LIVE-STORE-CLAIM verified=2026-08-07 measure="rows Overture may cut whose visibility changes when the genre is re-read from the row"
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func rereadingTheGenreHidesNothingThatIsShowing() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("genre-hides-\(UUID().uuidString)",
                                                                   isDirectory: true)
            defer { try? fm.removeItem(at: dir) }
            let url = try copyLiveStore(to: dir)
            let schema = Schema([Prospect.self, Recipient.self, ExcludedTown.self, AllowedSeedTown.self])
            let context = ModelContext(try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]))

            let all = try context.fetch(FetchDescriptor<Prospect>())
            #expect(all.count > 100, "the live store still holds a real queue to measure")

            // Dan's OWN refusals, read from the same store, because a gate built without them answers a
            // question about a queue that is not his.
            let excluded = Set((try context.fetch(FetchDescriptor<ExcludedTown>())).map(\.town))
            let seeds = Set((try context.fetch(FetchDescriptor<AllowedSeedTown>())).map(\.town))
            let refusals = GeoRefusals(userExcludedTowns: excluded, allowedSeedTowns: seeds)
            var newlyHidden: [String] = []
            for p in all where GeoRefusals.isOvertureToCut(p.status) {
                let stored = Discipline(rawValue: p.discipline) ?? .other
                // What the classifier reads from THIS row today, through the real classifier rather than
                // a restatement of its rules.
                let reread = EventClassifier.classify(ExtractedEvent(title: p.groupName,
                                                                     presenter: p.presenter,
                                                                     venue: p.venue,
                                                                     performanceDate: p.performanceDate,
                                                                     sourceUrl: nil,
                                                                     location: p.location)).discipline
                guard stored != reread else { continue }
                guard !refusals.hidesFromQueue(p) else { continue }   // already out of range: nothing to lose

                // Through the SHIPPED writer, on the real row, which is the only way this measures what
                // Dan would actually see. Written to the clone and never saved.
                GenreVisibility.write(reread, to: p)
                if refusals.hidesFromQueue(p) {
                    newlyHidden.append("\(p.groupName) [\(p.venue ?? "no venue")] \(p.location ?? "no location"): \(stored.rawValue) -> \(reread.rawValue)")
                }
            }

            #expect(newlyHidden.isEmpty,
                    "re-reading the genre would remove \(newlyHidden.count) live row(s) from the queue: \(newlyHidden.prefix(5).joined(separator: "; "))")
            await RealStoreTestLock.shared.release()
        } catch {
            // #2198: released on the THROWING path too. The `do` here had no catch, so a throw
            // inside it skipped the release and left every later suite waiting on a lock nobody
            // holds, which reads as a hung run with no failing test to point at.
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}

// The same rule, asked of rows a test can write, because the live store holds only the states it happens
// to hold today and cannot cover the one this guard exists for. A guard that has only ever seen rows it
// passes on has not been seen to fail.
@Suite("The hiding rule itself (#1658)")
struct GenreChangeHidingRuleTests {

    // The state the live guard is watching for, spelled out: an upstate show read as opera travels, and
    // the same show read as music does not.
    @Test func anUpstateShowIsShownAsOperaAndHiddenAsMusic() {
        let refusals = GeoRefusals.none
        #expect(refusals.hidesFromQueue(location: "Chautauqua, NY", discipline: .opera) == false)
        #expect(refusals.hidesFromQueue(location: "Chautauqua, NY", discipline: .music) == true)
    }

    private func row(_ discipline: String, location: String?) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Symphony No. 9", discipline: discipline,
                 venue: "Tarrytown Music Hall", performanceDate: "2026-11-14", sourceListingURL: nil, priorRelationship: "none", production: "self", profile: "neutral",
                 coverage: "unknown", fitScore: 5, tier: "longshot", fitReason: "",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.location = location
        return p
    }

    // Dan's call: the genre change is made, and the show stays.
    @Test func aShowingRowSurvivesTheGenreThatWouldHaveHiddenIt() {
        let p = row("opera", location: "Tarrytown, NY")
        #expect(GeoRefusals.none.hidesFromQueue(p) == false)

        GenreVisibility.write(.music, to: p)
        #expect(p.discipline == "music", "the genre itself is read honestly")
        #expect(p.keptVisibleAfterGenreChange)
        #expect(GeoRefusals.none.hidesFromQueue(p) == false, "and the show stays")
    }

    // The exemption is about a CHANGE, not a licence. A row that was already out of range gains nothing.
    @Test func aRowAlreadyOutOfRangeIsNotResurrected() {
        let p = row("music", location: "Tarrytown, NY")
        #expect(GeoRefusals.none.hidesFromQueue(p))

        GenreVisibility.write(.music, to: p)
        #expect(p.keptVisibleAfterGenreChange == false)
        #expect(GeoRefusals.none.hidesFromQueue(p))
    }

    // And it never overrides a town Dan refused. The exemption puts the row back on the LOOSE rule, and a
    // refused town is refused under that rule too.
    @Test func aTownDanRefusedStaysRefused() {
        let p = row("opera", location: "Tarrytown, NY")
        GenreVisibility.write(.music, to: p)
        #expect(p.keptVisibleAfterGenreChange)

        let refusing = GeoRefusals(userExcludedTowns: ["tarrytown"], allowedSeedTowns: [])
        #expect(refusing.hidesFromQueue(p), "his own refusal outranks the exemption")
    }

    // A show read in the other direction (onto the looser rule) needs no exemption at all.
    @Test func aGenreChangeThatShowsMoreNeedsNoExemption() {
        let p = row("music", location: "Tarrytown, NY")
        GenreVisibility.write(.theater, to: p)
        #expect(p.keptVisibleAfterGenreChange == false)
        #expect(GeoRefusals.none.hidesFromQueue(p) == false)
    }

    // And the reason the guard is scoped to rows Overture may cut: a show Dan has approved or already
    // written to carries live work, so geography never removes it whatever its genre says.
    @Test func aShowCarryingLiveOutreachIsNeverCutByGeography() {
        #expect(GeoRefusals.isOvertureToCut(.approved) == false)
        #expect(GeoRefusals.isOvertureToCut(.contacted) == false)
        #expect(GeoRefusals.isOvertureToCut(.new))
        #expect(GeoRefusals.isOvertureToCut(.queued))
    }
}
