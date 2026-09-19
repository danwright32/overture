import Testing
import Foundation
import SwiftData

// #3917: a one word show title can never confidently match the same show listed with a subtitle.
//
// `GroupNameMatch.isConfident` refuses any comparison where the shorter side is a single token
// (`GroupNameMatch.swift`, the `short.count < 2` guard), and refuses anything under a 0.6 containment
// fraction below that. Both guards are correct for the question `isConfident` is usually asked, which
// is "are these the same act" with NOTHING else established: it has 25 call sites and the loudest of
// them warms a lead off a past client, where a wrong match emails the wrong organisation.
//
// This is a DIFFERENT question, asked only by a caller that has already established the same folded
// venue and an overlapping run. With those two facts in hand the remaining question is not whether two
// acts are the same but whether one title is the other with a subtitle appended. So the guard is not
// loosened: a separate, narrower predicate is added beside it and the corroborated caller opts in.
//
// The pairs below are MEASURED, not invented. Every positive is a real pair from #3278's live-store
// write-up, and every negative is a pair the same measurement found at one venue on one night that a
// looser rule would have wrongly joined (L48).
@MainActor
@Suite("A title that is another title plus a subtitle (#3917)")
struct SubtitleVariantMatchTests {
    private let sandboxes = TemporarySandboxes()

    nonisolated private static var liveStoreExists: Bool {
        FileManager.default.fileExists(
            atPath: StoreLocation.storeURL(appSupport: StoreLocation.appSupport,
                                           isDebugBuild: false).path)
    }

    private func container(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, url: url,
                                                                      cloudKitDatabase: .none)])
    }

    // The same fold the natural key and `ScoutService.sameVenue` use. `ScoutService`'s own is private,
    // and a second spelling of it here would be a second definition of the population (L107), so this
    // goes through `VenueNormalization` exactly as `ContradictedCancellation.canonicalVenue` does.
    private func sameVenue(_ a: String?, _ b: String?) -> Bool {
        func fold(_ raw: String?) -> String {
            guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
            return VenueNormalization.normalizeForKey(raw)
        }
        return fold(a) == fold(b)
    }


    // THE POSITIVE CONTROL, and it is the whole reason this suite can claim anything. Each pair is
    // asserted to be REFUSED by `isConfident` first. Without that half a green here would be
    // indistinguishable from a run where `isConfident` had quietly started accepting them and the new
    // predicate was doing nothing at all (L159).
    @Test func theMeasuredPairsAreRefusedByIsConfidentAndAcceptedHere() {
        let pairs = [
            // The single-token refusal. Dan's own report, #3278, The Players Theatre.
            ("Marlise", "Marlise (A New Golden Age Musical)"),
            ("Masticate", "Masticate (A Dark Comedy)"),
            // The containment refusal: three tokens against six is 0.5, under the 0.6 guard.
            ("You Go On", "You Go On (A New Musical)"),
        ]
        for (short, long) in pairs {
            #expect(!GroupNameMatch.isConfident(short, long),
                    "\(short) against \(long) must be refused by isConfident: if this fails the guard has moved and this suite no longer measures what it claims")
            #expect(GroupNameMatch.isSubtitleExtension(short, long),
                    "\(short) against \(long) is one title plus a subtitle")
            #expect(GroupNameMatch.isSubtitleExtension(long, short),
                    "the order of the arguments must not change the answer")
        }
    }

    // MEASURED AND NOT PART OF THE GAP. Carnegie's slug rename produces "Jinhyung Park" against
    // "Jinhyung Park, Piano", which #3278 lists beside the Players Theatre pairs as though it were the
    // same defect. It is not: two tokens of three is 0.67, over the 0.6 containment guard, so
    // `isConfident` accepts it unmodified and nothing here was ever needed for it. Recorded because the
    // first draft of this suite asserted the opposite and the positive control above caught it.
    @Test func theCarnegieRenameWasAlreadyCoveredByIsConfident() {
        #expect(GroupNameMatch.isConfident("Jinhyung Park", "Jinhyung Park, Piano"))
    }

    // The pairs a rule of "same venue plus an intersecting night, any title" would have wrongly joined.
    // #3278 measured roughly nine of these and they are why the title test is load bearing rather than
    // incidental: a real cancellation that stops being announced is found by Dan turning up to shoot it.
    @Test func twoDifferentShowsSharingARoomAreStillRefused() {
        let pairs = [
            ("Tuudr Piano Competition Gala", "Special Venue Music Awards Winners Recital"),
            ("Josie De Guzman", "Miggie Snyder"),
            ("What If...", "The Lineup with Susie Mosher"),
            ("Late For Dinner Comedy!", "Reunion"),
        ]
        for (a, b) in pairs {
            #expect(!GroupNameMatch.isSubtitleExtension(a, b), "\(a) is not \(b) plus a subtitle")
        }
    }

    // A LEADING run, never any contiguous one. `isConfident` accepts a token run anywhere inside the
    // longer name, which is right for a presenter buried in a program line. Here the short side has no
    // corroboration of its own beyond the venue and the night, and a title that merely CONTAINS another
    // title is ordinary in a busy room, so only an appended subtitle counts.
    @Test func aTitleBuriedInsideAnotherIsNotASubtitleVariant() {
        #expect(!GroupNameMatch.isSubtitleExtension("Piano", "The Piano Lesson"))
        #expect(!GroupNameMatch.isSubtitleExtension("Carol", "A Christmas Carol the Musical"))
    }

    // Two titles that fold to the same string are EQUAL, not one plus a subtitle. `isConfident` already
    // answers that case and every caller reaches this predicate only after it has said no, so answering
    // true here would make the two indistinguishable and hide which one did the work.
    @Test func anIdenticalTitleIsNotASubtitleVariant() {
        #expect(!GroupNameMatch.isSubtitleExtension("Space Quest", "Space Quest"))
        #expect(!GroupNameMatch.isSubtitleExtension("Space Quest", "space  quest"))
    }

    // An empty side can never be a subtitle variant of anything: every title is trivially a prefix of
    // itself plus everything, so an unnamed row would join whatever shared its room.
    @Test func anEmptyTitleJoinsNothing() {
        #expect(!GroupNameMatch.isSubtitleExtension("", "Space Quest"))
        #expect(!GroupNameMatch.isSubtitleExtension("Space Quest", ""))
        #expect(!GroupNameMatch.isSubtitleExtension("", ""))
    }

    // THE CALLER. The corroborated one, and the only one this change opts in.
    private func memoryContext() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema,
                                                                isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func row(_ ctx: ModelContext, key: String, title: String, venue: String,
                     opens: String, runEnd: String?, missed: Int) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: title, discipline: "theater", venue: venue,
                         performanceDate: opens, sourceListingURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "unknown", coverage: "unknown", fitScore: 3,
                         tier: "medium", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: runEnd, partOfRelatedRun: runEnd != nil,
                         runSourceURLs: [], runNights: [opens])
        p.missedScoutCount = missed
        ctx.insert(p)
        return p
    }

    // Dan's own case, with the titles the live store actually holds rather than the pair the existing
    // suite uses. `ContradictedCancellationTests` fixes the flagged row against "Marlise (A New Golden
    // Age)", which shares five of six tokens and passes `isConfident` unmodified, so it never exercised
    // the refusal this issue is about.
    @Test func theSingleTokenTwinNowContradictsTheWarning() throws {
        let ctx = try memoryContext()
        let flagged = row(ctx, key: "a", title: "Marlise (A New Golden Age Musical)",
                          venue: "The Players Theatre", opens: "2026-09-04", runEnd: "2026-09-06",
                          missed: 13)
        let live = row(ctx, key: "b", title: "Marlise", venue: "The Players Theatre",
                       opens: "2026-08-30", runEnd: "2026-09-06", missed: 0)
        let all = [flagged, live]

        #expect(ContradictedCancellation.liveTwin(of: flagged, among: all)?.naturalKey == "b")
        #expect(ContradictedCancellation.contradictedKeys(among: all) == ["a"])
    }

    // THE INGEST ARM, driven through the real pipeline rather than the private function, for the reason
    // `RunURLRecognitionTests` records: what is being asked is what `ScoutService.apply` does, and a test
    // calling the arm could only confirm the arm.
    //
    // The pair is MEASURED, not invented: it is one of the three the live-store report below finds, a
    // stored row and an incoming listing sharing a URL at one venue where the source dropped a
    // parenthetical. The other two are Dan's own Jalopy open mic pair from #1590 and a Kinstillatory
    // Mappings pair.
    @Test func aSharedURLListingThatDroppedItsSubtitleDoesNotMintASecondRow() throws {
        let schema = Schema([Prospect.self, Recipient.self])
        let ctx = ModelContext(try ModelContainer(for: schema,
                               configurations: [ModelConfiguration(schema: schema,
                                                                   isStoredInMemoryOnly: true)]))
        let long = "Blues For Greeny (The Music of Peter Green)"
        let short = "Blues For Greeny"
        let venue = "The Cutting Room"
        let url = "https://thecuttingroomnyc.com/events/blues-for-greeny"

        let stored = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: long,
                                                                  performanceDate: "2026-11-14",
                                                                  venue: venue),
                              groupName: long, discipline: "music", venue: venue,
                              performanceDate: "2026-11-14", sourceListingURL: url,
                              priorRelationship: "none", production: "unknown", profile: "unknown",
                              coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                              matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                              runEndDate: nil, partOfRelatedRun: false,
                              runSourceURLs: [url], runNights: ["2026-11-14"])
        ctx.insert(stored)
        try ctx.save()

        // A DIFFERENT NIGHT, and that is load bearing rather than incidental. The first draft of this
        // test used the same night and PASSED with no change to `ScoutService` at all, because
        // `matchByStableSource` takes the same listing URL plus the same date plus the same venue and
        // deliberately does not test the title (`ScoutService.swift`, #797). So the arm under test was
        // never reached and the fixture proved nothing (L143, L159). A second night of the same run
        // leaves that arm unable to fire and leaves `matchByAnyRunURL` as the only one that can.
        let incoming = ExtractedEvent(title: short, presenter: "Blues For Greeny", venue: venue,
                                      performanceDate: "2026-11-15", sourceUrl: url)
        _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                               today: "2026-09-19", sourceIds: ["thecuttingroomnyc-com"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1,
                "the listing dropped its subtitle and shares the stored row's URL, so it is one show: \(rows.map(\.groupName))")
    }

    // THE PRECONDITION, so a green above cannot come from a fixture where the titles were never the
    // problem in the first place (L159).
    @Test func theIngestFixtureIsExactlyTheCaseIsConfidentRefuses() {
        #expect(!GroupNameMatch.isConfident("Blues For Greeny",
                                            "Blues For Greeny (The Music of Peter Green)"))
        #expect(GroupNameMatch.isSubtitleExtension("Blues For Greeny",
                                                   "Blues For Greeny (The Music of Peter Green)"))
    }

    // THE CLASS, not the instance. `ContradictedCancellation` is one of three places in the app that
    // corroborate a pair and then ask `isConfident` about the title. The other two are ingest re-key
    // arms in `ScoutService`, and each carries STRONGER corroboration than this change's caller does: a
    // shared `seriesId` (`matchByConcertIdentity`) or a shared listing URL (`matchByAnyRunURL`), on top
    // of the same venue.
    //
    // They are deliberately NOT changed here, and this test is why that decision can be re-taken rather
    // than argued. A re-key changes a row's identity, so a wrong match there costs a row while a wrong
    // match in the display arm costs a re-render. #3330 asks for a would-have-matched report before
    // anything is allowed to block or redirect an insert, and this is that report for the subtitle arm:
    // it walks the live store for pairs that ALREADY satisfy each ingest arm's corroboration and would
    // newly be joined by the subtitle test.
    //
    // It REPORTS and never refuses. A pair appearing here is a candidate to look at, not a defect.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theIngestArmsWouldJoinThesePairsIfTheyTookTheSubtitleTest() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "subtitle-variant-ingest")
            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                await RealStoreTestLock.shared.release()
                return
            }
            let ctx = ModelContext(try container(at: clone))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())

            var seriesPairs = 0
            var urlPairs = 0
            for (index, left) in all.enumerated() {
                for right in all[(index + 1)...] {
                    // The subtitle arm is the only thing that could change the answer, so a pair
                    // `isConfident` already accepts is not a candidate and is skipped first.
                    guard !GroupNameMatch.isConfident(left.groupName, right.groupName),
                          GroupNameMatch.isSubtitleExtension(left.groupName, right.groupName),
                          sameVenue(left.venue, right.venue) else { continue }
                    let overlaps = ScoutService.runsOverlap(storedStart: left.performanceDate,
                                                            storedEnd: left.runEndDate,
                                                            incomingStart: right.performanceDate,
                                                            incomingEnd: right.runEndDate)
                    let sharesSeries = (left.seriesId.map { !$0.isEmpty && $0 == right.seriesId } ?? false)
                    let sharesURL = !Set(left.runSourceURLs + [left.sourceListingURL ?? ""])
                        .subtracting([""])
                        .isDisjoint(with: Set(right.runSourceURLs + [right.sourceListingURL ?? ""]))
                    if sharesSeries && overlaps {
                        seriesPairs += 1
                        print("  wouldJoin[seriesId] \(left.groupName) :: \(right.groupName)")
                    }
                    if sharesURL {
                        urlPairs += 1
                        print("  wouldJoin[runURL] \(left.groupName) :: \(right.groupName)")
                    }
                }
            }
            print("Subtitle arm at ingest, over \(all.count) rows: "
                  + "\(seriesPairs) pair(s) newly joined by matchByConcertIdentity, "
                  + "\(urlPairs) by matchByAnyRunURL")

            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // And the room next door, which must not move. Same venue, overlapping run, unrelated title.
    @Test func anUnrelatedShowInTheSameRoomStillLeavesTheWarningStanding() throws {
        let ctx = try memoryContext()
        let flagged = row(ctx, key: "a", title: "Tuudr Piano Competition Gala",
                          venue: "Weill Recital Hall", opens: "2026-10-10", runEnd: "2026-10-12",
                          missed: 9)
        let live = row(ctx, key: "b", title: "Special Venue Music Awards Winners Recital",
                       venue: "Weill Recital Hall", opens: "2026-10-10", runEnd: "2026-10-12",
                       missed: 0)
        let all = [flagged, live]

        #expect(ContradictedCancellation.liveTwin(of: flagged, among: all) == nil)
        #expect(ContradictedCancellation.contradictedKeys(among: all).isEmpty)
    }
}
