import Testing
import Foundation
import SwiftData

// #1847: since #1761 the same-night merge NO LONGER CONSULTS THE VENUE, so the show title is the only
// thing standing between two genuinely different shows and one card, and the losing row is DELETED.
//
// That is fine for "A Workshop with the Derek Piotr Fieldwork Archive" and is exactly the risk for
// "Open Mic", "Jazz Night" or "Student Recital" at two different rooms on one evening.
//
// #1847 asks for a sweep of the live store, judged by eye, and that is what this is. It exists as a
// TEST rather than a one-off look because the risk arrives with the watchlist: a venue that runs a
// weekly open mic under one title is an ordinary thing to start watching, and the sweep has to re-run
// when that happens rather than having been run once in 2026.
//
// THROUGH THE APP'S OWN PREDICATE, never a near neighbour of it, and this took two attempts. The first
// sweep used exact folded-title equality in SQL. The second used
// `GroupNameMatch.isConfident(minimumContainment: sameNightContainmentFraction)`, which LOOKS like the
// shipped rule and is not: `SameNightTitleVariantMerge.clusters` calls `isSameNightVariant`, which is
// that OR `differsByOneTypo`. So the second sweep was still narrower than the thing it was measuring
// and would have reported a clean store while a one-character pair sat in it (L107).
//
// All three routes happen to return the same three pairs on today's store. That is luck, and it is
// worth saying so: agreeing on one corpus is not the same as being the same predicate.
@MainActor
@Suite("Two different shows sharing a title on one night (#1847)")
struct TwoShowsOneTitleOneNightTests {
    private let sandboxes = TemporarySandboxes()

    nonisolated private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }
    nonisolated private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    private func container(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, url: url,
                                                                      cloudKitDatabase: .none)])
    }

    // A pair the same-night merge would collapse, named so a reader can judge it.
    private struct Candidate {
        let night: String
        let a: Prospect
        let b: Prospect

        var line: String {
            "\(night)  \(a.groupName) @ \(a.venue ?? "?")  ||  \(b.groupName) @ \(b.venue ?? "?")"
        }
    }

    // Every pair on one night whose titles the merge would call confident, at DIFFERENT venue keys.
    // Same-venue pairs are the merge's whole purpose and are not the question.
    private func crossVenueCandidates(_ rows: [Prospect]) -> [Candidate] {
        var byNight: [String: [Prospect]] = [:]
        for row in rows {
            guard let night = row.performanceDate else { continue }
            byNight[night, default: []].append(row)
        }

        var out: [Candidate] = []
        for (night, sameNight) in byNight where sameNight.count > 1 {
            for (index, left) in sameNight.enumerated() {
                for right in sameNight[(index + 1)...] {
                    let leftRoom = VenueNormalization.normalizeForKey(left.venue ?? "")
                    let rightRoom = VenueNormalization.normalizeForKey(right.venue ?? "")
                    guard leftRoom != rightRoom else { continue }
                    // `isSameNightVariant`, which is EXACTLY what `SameNightTitleVariantMerge.clusters`
                    // calls, and not `isConfident` at the same-night fraction. The two are not the same
                    // predicate: `isSameNightVariant` is that OR `differsByOneTypo`, so it is strictly
                    // wider, and a sweep using the narrower one silently misses every pair whose titles
                    // differ by a single character. This sweep was written with the narrow one first,
                    // which is the very mistake its own header warns about one paragraph up.
                    guard GroupNameMatch.isSameNightVariant(left.groupName, right.groupName)
                    else { continue }
                    out.append(Candidate(night: night, a: left, b: right))
                }
            }
        }
        return out.sorted { $0.night < $1.night }
    }

    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theStoreHoldsNoPairTheSameNightMergeWouldWronglyCollapse() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "one-title-one-night")
            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                await RealStoreTestLock.shared.release()
                return
            }
            let ctx = ModelContext(try container(at: clone))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            let candidates = crossVenueCandidates(all)

            print("""
            One title one night corpus: \(all.count) row(s), \
            \(candidates.count) cross-venue pair(s) the same-night merge would collapse
            \(candidates.map { "  " + $0.line }.joined(separator: "\n"))
            """)

            // THE JUDGEMENT, recorded rather than re-made. Every pair below was read by eye on
            // 2026-09-19 and is ONE show at ONE venue complex whose rooms are named differently, so
            // collapsing it is correct and #1761's venue-blind merge does the right thing.
            //
            // A pair NOT on this list has never been judged, and the cost of guessing is a deleted row,
            // so it fails and names itself. The remedy is to look at it and either add it here with a
            // reason or, if it really is two different shows, to give the merge back a guard that can
            // tell them apart. Which of those it is cannot be decided in code, which is the whole of
            // why #1847 asked for eyes.
            // The first three are ONE VENUE COMPLEX, Abrons Arts Center, listed once as the building and
            // once as a room inside it.
            //
            // THAT IS NO LONGER TRUE OF THE WHOLE LIST, and the sentence that used to stand here said it
            // was: "the store holds no pair of genuinely different shows under one title... it is a fact
            // about today rather than a property of the rule: nothing stops one arriving with the next
            // watchlist addition." One arrived on 2026-09-21, in a single scout run that brought fifteen
            // new pairs. Fourteen were rooms named two ways; the GLOW pair at the end is two different
            // churches and is here on Dan's decision rather than on a reading of the rooms. So a reader
            // must NOT take this list as evidence that a venue-blind merge is safe.
            // #4067: keyed on WHAT WAS JUDGED (the folded title, the shared night, the two rooms) rather
            // than on the rows' natural keys, which every re-key arm in this milestone rewrites. See
            // `JudgedPair` for what moved these entries out from under their own verdicts.
            let judged: Set<JudgedPair> = [
                JudgedPair(foldedTitles: ["urban youth theater summer presentation the show will be named by making it",
                                          "urban youth theater summer presentation the show will be named by making it"],
                           night: "2026-08-01",
                           venues: ["Abrons Arts Center", "Main Gallery at Abrons Arts Center"]),
                JudgedPair(foldedTitles: ["orbit", "orbit"], night: "2026-08-09",
                           venues: ["Experimental Theater at Abrons Arts Center", "Abrons Arts Center"]),
                JudgedPair(foldedTitles: ["silsila resonance the living journey of south asian classical music",
                                          "silsila resonance the living journey of south asian classical music"],
                           night: "2026-08-30",
                           venues: ["Playhouse Theater at Abrons Arts Center", "Abrons Arts Center"]),

                // Judged 2026-09-21 (#4102). Fourteen arrived in one scout run, and every one is a room
                // named two ways rather than two shows. Four shapes, and none needs eyes on the show
                // itself, only on the rooms: the venue's full name against its short one (Roulette
                // Intermedium), a room against the building that contains it (Zankel Hall in Carnegie
                // Hall, Leonard Nimoy Thalia and the Peter Jay Sharp Theatre in Symphony Space, the
                // Playhouse Theater in Abrons Arts Center), a room with and without its building
                // appended (Adler Hall, Stern Auditorium), and one institution under two of its own
                // names (Trinity Church NYC, Brick Presbyterian Church).
                JudgedPair(foldedTitles: ["the monkathon miles okazaki plays thelonious monk world premiere screening",
                                          "the monkathon miles okazaki plays thelonious monk world premiere screening"],
                           night: "2026-09-22", venues: ["Roulette", "Roulette Intermedium"]),
                JudgedPair(foldedTitles: ["selected shorts the five boroughs", "selected shorts the five boroughs"],
                           night: "2026-09-23", venues: ["Peter Jay Sharp Theatre", "Symphony Space"]),
                JudgedPair(foldedTitles: ["the scores project a book release show w the rise of the novel",
                                          "the scores project a book release show w the rise of the novel"],
                           night: "2026-09-24", venues: ["Roulette", "Roulette Intermedium"]),
                JudgedPair(foldedTitles: ["john zorn s alea iacta est world premiere",
                                          "john zorn s alea iacta est world premiere"],
                           night: "2026-09-27", venues: ["Roulette", "Roulette Intermedium"]),
                JudgedPair(foldedTitles: ["bathed in sound james brandon lewis trio trap music orchestra angelica sanchez clinton patterson sheela bringi elden kelly",
                                          "bathed in sound james brandon lewis trio trap music orchestra angelica sanchez clinton patterson sheela bringi elden kelly"],
                           night: "2026-09-29", venues: ["Roulette", "Roulette Intermedium"]),
                JudgedPair(foldedTitles: ["the fixx colin blunstone the voice of the zombies and peter asher",
                                          "the fixx colin blunstone the voice of the zombies and peter asher"],
                           night: "2026-10-01",
                           venues: ["Adler Hall", "Adler Hall at New York Society for Ethical Culture"]),
                JudgedPair(foldedTitles: ["broadway does punk", "broadway does punk"],
                           night: "2026-10-02",
                           venues: ["Abrons Arts Center", "Playhouse Theater at Abrons Arts Center"]),
                JudgedPair(foldedTitles: ["uptown showdown hot vs cold", "uptown showdown hot vs cold"],
                           night: "2026-10-06",
                           venues: ["Leonard Nimoy Thalia", "Leonard Nimoy Thalia at Symphony Space"]),
                JudgedPair(foldedTitles: ["revelry the lovestruck balladeers", "revelry the lovestruck balladeers"],
                           night: "2026-10-07", venues: ["Leonard Nimoy Thalia", "Symphony Space"]),
                JudgedPair(foldedTitles: ["trio azura", "trio azura new york debut"],
                           night: "2026-10-14", venues: ["Zankel Hall", "Zankel Hall at Carnegie Hall"]),
                JudgedPair(foldedTitles: ["voces8 at trinity church", "voces8 at trinity church"],
                           night: "2026-10-30", venues: ["Trinity Church", "Trinity Church NYC"]),
                JudgedPair(foldedTitles: ["daily diversions world premiere", "daily diversions world premiere"],
                           night: "2026-11-12",
                           venues: ["Abrons Arts Center", "Playhouse Theater at Abrons Arts Center"]),
                JudgedPair(foldedTitles: ["cantata 140 at brick church sunday service",
                                          "cantata 140 at brick church sunday service"],
                           night: "2026-11-22", venues: ["Brick Church", "Brick Presbyterian Church"]),
                JudgedPair(foldedTitles: ["handel judas maccabaeus", "handel judas maccabeus"],
                           night: "2026-12-04",
                           venues: ["Stern Auditorium / Perelman Stage",
                                    "Stern Auditorium / Perelman Stage at Carnegie Hall"]),

                // THE FIRST ENTRY HERE THAT IS NOT ONE VENUE COMPLEX, and it is recorded as Dan's
                // explicit decision rather than as a reading of the rooms, because the rooms say the
                // opposite. St. Peter's Episcopal Church and Trinity Episcopal Church are two different
                // churches. Both rows come from ONE source page (`emberarts.org/20262027-season`) under
                // one presenter (Ember Choral Arts) with one title and one date, so the pair is either a
                // choir performing twice in a day or a misread of a season page listing two dates.
                //
                // Dan's call, 2026-09-21 (this session, in chat), asked with the alternative in front of
                // him. He was offered a venue guard on the merge, or reading the source page first, and
                // chose to record it as collapsible. The consequence, stated here because the entry
                // cannot show it: `SameNightTitleVariantMerge` will collapse these two at the next
                // launch and DELETE the losing row, so one of the two churches leaves the queue.
                // Neither row carries outreach history, so nothing in the merge refuses it.
                //
                // This entry is therefore NOT evidence that a venue-blind merge is safe. It is one
                // decision about one pair, and the next genuinely different pair gets the same treatment
                // only if somebody decides that again.
                JudgedPair(foldedTitles: ["glow healing and connection", "glow healing and connection"],
                           night: "2026-12-06",
                           venues: ["St. Peter's Episcopal Church", "Trinity Episcopal Church"]),
            ]

            let unjudged = candidates.filter { candidate in
                !judged.contains(JudgedPair.of(candidate.a, candidate.b, night: candidate.night))
            }

            #expect(unjudged.isEmpty, Comment(rawValue: """
                \(unjudged.count) same-night pair(s) at DIFFERENT venues would be collapsed by a merge \
                that no longer consults the room, and the losing row is deleted. Judge each and record \
                it, or give the merge a guard:
                \(unjudged.map { "  " + $0.line + "\n    verdict key: " + JudgedPair.of($0.a, $0.b, night: $0.night).description }.joined(separator: "\n"))
                """))

            try? FileManager.default.removeItem(at: clone)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // The sweep must be able to SEE the shape it exists for, or an empty finding says nothing (L159).
    // Two genuinely different shows under one generic title, one night, two rooms: the exact case
    // #1847 describes and the one the store does not currently hold.
    @Test func theSweepFindsTwoDifferentShowsUnderOneGenericTitle() throws {
        let schema = Schema([Prospect.self, Recipient.self])
        let ctx = ModelContext(try ModelContainer(for: schema,
                               configurations: [ModelConfiguration(schema: schema,
                                                                   isStoredInMemoryOnly: true)]))
        func row(_ key: String, _ title: String, _ venue: String) {
            ctx.insert(Prospect(naturalKey: key, groupName: title, discipline: "music", venue: venue,
                                performanceDate: "2026-11-04", sourceListingURL: nil,
                                priorRelationship: "none", production: "unknown", profile: "unknown",
                                coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                                matchedClientName: nil, possibleMatchSource: nil,
                                possibleMatchName: nil))
        }
        row("a", "Open Mic Night", "The Cutting Room")
        row("b", "Open Mic Night", "Asylum NYC")

        let found = crossVenueCandidates(try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(found.count == 1, "the sweep cannot see the shape it exists to find")
    }

    // THE CONTROL THAT SEPARATES THE TWO PREDICATES, and without it the widening above is unguarded:
    // swapping `isSameNightVariant` back to `isConfident` left the suite green (measured with
    // `scripts/mutate.sh`: SURVIVED), because neither the other fixtures nor the live store holds a
    // one-typo pair. A guard that cannot tell the rule it uses from the one it replaced is not
    // guarding the choice (L159).
    //
    // One letter inside a title, which is the real case #1764 added the typo arm for. `isConfident`
    // refuses it, because its containment test compares tokens exactly; `isSameNightVariant` accepts
    // it. So the merge WOULD collapse these two different shows at two different rooms, and the sweep
    // has to see them.
    @Test func theSweepFindsAPairThatDiffersByOneLetterInsideTheTitle() throws {
        let schema = Schema([Prospect.self, Recipient.self])
        let ctx = ModelContext(try ModelContainer(for: schema,
                               configurations: [ModelConfiguration(schema: schema,
                                                                   isStoredInMemoryOnly: true)]))
        func row(_ key: String, _ title: String, _ venue: String) {
            ctx.insert(Prospect(naturalKey: key, groupName: title, discipline: "music", venue: venue,
                                performanceDate: "2026-11-04", sourceListingURL: nil,
                                priorRelationship: "none", production: "unknown", profile: "unknown",
                                coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                                matchedClientName: nil, possibleMatchSource: nil,
                                possibleMatchName: nil))
        }
        row("a", "Greely Square Sessions", "The Cutting Room")
        row("b", "Greeley Square Sessions", "Asylum NYC")

        // Asserted first, so a change to either function that made them agree would show up here as
        // the fixture losing its meaning rather than as a silent pass.
        #expect(!GroupNameMatch.isConfident("Greely Square Sessions", "Greeley Square Sessions",
                                            minimumContainment: GroupNameMatch.sameNightContainmentFraction),
                "the fixture is only meaningful while the narrower predicate refuses this pair")
        #expect(GroupNameMatch.isSameNightVariant("Greely Square Sessions", "Greeley Square Sessions"))

        #expect(crossVenueCandidates(try ctx.fetch(FetchDescriptor<Prospect>())).count == 1,
                "the sweep misses a pair the merge would collapse on its typo arm")
    }

    // And it must NOT report the merge's own purpose: one show, one room, two spellings of the title.
    @Test func theSweepIgnoresTwoSpellingsAtOneRoom() throws {
        let schema = Schema([Prospect.self, Recipient.self])
        let ctx = ModelContext(try ModelContainer(for: schema,
                               configurations: [ModelConfiguration(schema: schema,
                                                                   isStoredInMemoryOnly: true)]))
        func row(_ key: String, _ title: String, _ venue: String) {
            ctx.insert(Prospect(naturalKey: key, groupName: title, discipline: "music", venue: venue,
                                performanceDate: "2026-11-04", sourceListingURL: nil,
                                priorRelationship: "none", production: "unknown", profile: "unknown",
                                coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                                matchedClientName: nil, possibleMatchSource: nil,
                                possibleMatchName: nil))
        }
        row("a", "Fleetwood Mac: Stripped", "Asylum NYC")
        row("b", "Fleetwood Mac: Stripped (Broadway Sings)", "Asylum NYC")

        #expect(crossVenueCandidates(try ctx.fetch(FetchDescriptor<Prospect>())).isEmpty)
    }
}
