import Testing
import Foundation
import SwiftData

// #4129: a source that adds a name to its own billing splits one show into two cards.
//
// MEASURED ON THE LIVE STORE 2026-09-21, and re-read from a clone of it on 2026-09-22 before this was
// written. Carnegie added two guests to the billing on one listing page and the scout inserted a second
// prospect (pk 1552) beside the row it already held (pk 57). Same page, same night (2026-10-03), same
// room (Weill Recital Hall). The two titles are the constants below, copied from that store.
//
// WHY EVERY ARM REFUSED. `matchByStableSource` exists for exactly this shape (listing URL plus date plus
// folded venue) and since #4032 it also asks `GroupNameMatch.isSameShowTitle`. That predicate is
// `isConfident || isSubtitleExtension`, and `isSubtitleExtension` needs the shorter title to be a
// contiguous LEADING run of the longer one. The conjunction MOVED:
//
//     ... dave eggar AND gregg august
//     ... dave eggar gregg august makeda hampton AND mak grgic
//
// so the stored title is not a leading run of the incoming one, `isConfident` refuses it at 0.6 and at
// 0.4, and `matchByProductionToken` needs exact folded-title equality and refuses too.
//
// THE FIX IS SCOPED TO `isSameShowTitle`, never to `isConfident`, whose 25 call sites include repeat
// client detection, where a wrong match warms a lead off the wrong organisation (#3917, #1351). The
// filler-conjunction rule is a THIRD predicate beside `isSubtitleExtension`, reachable only from
// `isSameShowTitle`, and every caller of that already holds a corroborating fact beyond the title.
//
// `&` is deliberately not in the filler set and needs none: `GroupNameMatch.normalize` replaces every
// non-alphanumeric character with a space, so an ampersand never survives as a token at all. Measured on
// the same clone: 86 stored titles carry `&` and none carries the HTML entity `&amp;`, which is the one
// spelling that would arrive as a word.
@MainActor
@Suite("A billing that gained a name (#4129)")
struct BillingConjunctionTitleTests {
    private let sandboxes = TemporarySandboxes()

    // The live store's pk 57 and pk 1552, verbatim.
    private static let storedBilling =
        "Ilya Kaler, Violin Rasa Vitkauskaite, Piano With special guests Paquito D'Rivera, "
        + "Jonathan Cohler, Dave Eggar, and Gregg August"
    private static let incomingBilling =
        "Ilya Kaler, Violin Rasa Vitkauskaite, Piano With special guests Paquito D'Rivera, "
        + "Jonathan Cohler, Dave Eggar, Gregg August, Makeda Hampton, and Mak Grgic"
    private static let page =
        "https://www.carnegiehall.org/calendar/2026/10/03/ilya-kaler-violin-rasa-vitkauskaite-piano-"
        + "with-special-guests-paquito-drivera-0730pm"
    private static let venue = "Weill Recital Hall"
    private static let night = "2026-10-03"

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

    private func context() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema,
                                                                isStoredInMemoryOnly: true)]))
    }

    // THE POSITIVE CONTROL, and the reason a green below can claim anything. Both existing predicates
    // are asserted to REFUSE the measured pair first. Without that half, a pass here would be
    // indistinguishable from a run where `isConfident` had quietly started accepting the pair and the
    // new rule was doing nothing at all (L159).
    @Test func theMeasuredPairIsRefusedByBothExistingPredicates() {
        #expect(!GroupNameMatch.isConfident(Self.storedBilling, Self.incomingBilling),
                "if this fails the containment guard has moved and this suite no longer measures what it claims")
        #expect(!GroupNameMatch.isConfident(Self.storedBilling, Self.incomingBilling,
                                            minimumContainment: GroupNameMatch.sameNightContainmentFraction),
                "refused at the same-night threshold too, which is what left the launch merges unable to collapse them")
        #expect(!GroupNameMatch.isSubtitleExtension(Self.storedBilling, Self.incomingBilling),
                "the conjunction moved, so the stored title is not a leading run of the incoming one")
    }

    // THE CLAIM. One show, so the corroborated same-show test says so.
    @Test func theBillingThatGainedTwoNamesIsTheSameShow() {
        #expect(GroupNameMatch.isSameShowTitle(Self.storedBilling, Self.incomingBilling))
        #expect(GroupNameMatch.isSameShowTitle(Self.incomingBilling, Self.storedBilling),
                "the order of the arguments must not change the answer")
    }

    // WHAT MUST NOT MOVE. `isConfident` has 25 call sites answering "are these the same act" with
    // nothing else established, and the loudest of them warms a lead off a past client. The filler rule
    // is reachable only from `isSameShowTitle`, so the same pair asked the plain question is still
    // refused, above and here on a synthetic pair with nothing else going on.
    @Test func isConfidentIsUntouchedByTheFillerRule() {
        #expect(!GroupNameMatch.isConfident("Bach and Handel", "Bach Handel Mozart Haydn"))
        #expect(GroupNameMatch.isSameShowTitle("Bach and Handel", "Bach Handel Mozart Haydn"),
                "the corroborated caller joins it; the bare same-act question does not")
    }

    // The rule answers ONLY where dropping a filler changed something, exactly as `isSubtitleExtension`
    // answers false for two equal titles: every caller reaches these predicates in order, so a rule that
    // also answered the cases above it would hide which one did the work.
    @Test func theRuleAnswersNothingWhenNoFillerWasDropped() {
        #expect(!GroupNameMatch.isBillingExtension("Space Quest", "Space Quest Live"),
                "no filler on either side: that pair is `isSubtitleExtension`'s and it already answers it")
        #expect(GroupNameMatch.isSubtitleExtension("Space Quest", "Space Quest Live"))
        #expect(!GroupNameMatch.isBillingExtension("Space Quest", "Space Quest"))
    }

    // A title made of nothing but filler words joins nothing. Dropping them empties it, and an empty
    // title is trivially a leading run of everything, so it would join whatever shared its listing.
    @Test func aTitleOfNothingButFillerJoinsNothing() {
        #expect(!GroupNameMatch.isBillingExtension("and", "Ilya Kaler, Violin"))
        #expect(!GroupNameMatch.isBillingExtension("With", "With Ilya Kaler"))
        #expect(!GroupNameMatch.isBillingExtension("", "Ilya Kaler, Violin"))
        #expect(!GroupNameMatch.isSameShowTitle("and", "Ilya Kaler, Violin"))
    }

    // THE ROOM NEXT DOOR. The live store holds six pairs sharing a listing URL, a night and a room under
    // different keys (measured on the 2026-09-22 clone, over 1,333 rows). Three of them are genuinely
    // different shows, and #4032 is the guard that keeps them apart: they are asserted here, with their
    // real titles, so a loosening that swallowed one would be red rather than merged.
    //
    // The fourth, `La Sonnambula: Orchestral Concert with Integrated ASL` against `Orchestral Concert
    // with Integrated ASL`, IS one show and is deliberately still refused. The second source dropped a
    // leading series name rather than appending to a billing, which is the shape #4032 gives up on on
    // purpose: a duplicate row is visible on the queue, a wrong re-key carries Dan's dismissal onto an
    // act he never judged. Recorded here rather than left to be rediscovered (L93).
    @Test func theOtherPairsSharingOnePageAndNightStayApart() {
        let different = [
            ("La bohème", "Lincoln in the Bardo"),
            ("Back to Shakespeare", "Marlise (A New Golden Age Musical)"),
            ("Training Choir Concert: A Royal Tapestry", "Snakes, Snails, & Puppy Dog Tails"),
        ]
        for (a, b) in different {
            #expect(!GroupNameMatch.isSameShowTitle(a, b), "\(a) is not \(b)")
        }
        #expect(!GroupNameMatch.isSameShowTitle("La Sonnambula: Orchestral Concert with Integrated ASL",
                                                "Orchestral Concert with Integrated ASL"),
                "a dropped LEADING series name is not what this rule covers, and #4032 keeps it apart")
    }

    // THE INGEST, driven through the real `ScoutService.apply` rather than the arm, for the reason
    // `SeasonPageStableSourceTests` records: what is being asked is what the pipeline DOES, and a test
    // calling the private arm could only confirm the arm.
    @Test func theSecondBillingDoesNotMintASecondRow() throws {
        let ctx = try context()
        let key = Prospect.makeNaturalKey(groupName: Self.storedBilling,
                                          performanceDate: Self.night, venue: Self.venue)
        let stored = Prospect(naturalKey: key, groupName: Self.storedBilling, discipline: "music",
                              venue: Self.venue, performanceDate: Self.night,
                              sourceListingURL: Self.page, priorRelationship: "none",
                              production: "unknown", profile: "unknown", coverage: "unknown",
                              fitScore: 3, tier: "medium", fitReason: "", matchedClientName: nil,
                              possibleMatchSource: nil, possibleMatchName: nil, runEndDate: nil,
                              partOfRelatedRun: false, runSourceURLs: [Self.page],
                              runNights: [Self.night])
        ctx.insert(stored)
        try ctx.save()

        let incoming = ExtractedEvent(title: Self.incomingBilling, presenter: "Carnegie Hall",
                                      venue: Self.venue, performanceDate: Self.night,
                                      sourceUrl: Self.page)
        _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                               today: "2026-09-21", sourceIds: ["carnegiehall-org"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1,
                "one concert whose billing gained two guests is one show: \(rows.map(\.groupName))")
        #expect(rows.first?.groupName == Self.incomingBilling,
                "and the row carries the newer billing")
    }

    // THE PRECONDITION for the ingest test, so a green there cannot come from a fixture where the titles
    // were never the problem (L159). The two keys must differ, or the first arm answers and the arms
    // this is about are never reached.
    @Test func theIngestFixtureReachesTheArmsThisIsAbout() {
        #expect(Prospect.makeNaturalKey(groupName: Self.storedBilling, performanceDate: Self.night,
                                        venue: Self.venue)
                != Prospect.makeNaturalKey(groupName: Self.incomingBilling,
                                           performanceDate: Self.night, venue: Self.venue))
    }

    // THE BLAST RADIUS, over the live store, REPORTING and never refusing. A pair here is a candidate to
    // look at rather than a defect: it walks every pair that already satisfies an ingest arm's
    // corroboration (a shared listing URL, or that plus the night and the room) and would be NEWLY
    // joined by the filler rule, which is what #4098 asks for before an arm is loosened.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theFillerRuleWouldNewlyJoinThesePairs() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "billing-conjunction")
            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                // SAYS SO rather than returning quietly: this test passes either way, so a silent
                // return is indistinguishable from a walk that found nothing (L11, L98). No figure is
                // printed on this path, because a run that measured nothing must never print one.
                print("Filler conjunction rule: UNMEASURED, the live store could not be cloned.")
                await RealStoreTestLock.shared.release()
                return
            }
            let ctx = ModelContext(try container(at: clone))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())

            var sharingAPage = 0
            var sharingPageNightAndRoom = 0
            for (index, left) in all.enumerated() {
                for right in all[(index + 1)...] {
                    // NEWLY joined, so the two predicates asked before this one are excluded first.
                    // Without that the report counts every pair they already join (identical titles, an
                    // appended parenthetical) and its own sentence stops being true: the first run of
                    // this test printed 7 pairs where 1 was new, because a filler word appears in both
                    // halves of an ordinary pair and dropping it changes nothing about the verdict (L11).
                    guard !GroupNameMatch.isConfident(left.groupName, right.groupName),
                          !GroupNameMatch.isSubtitleExtension(left.groupName, right.groupName),
                          GroupNameMatch.isBillingExtension(left.groupName, right.groupName) else {
                        continue
                    }
                    let leftURLs = ListingURL.foldedSet(left.runSourceURLs
                                                        + [left.sourceListingURL].compactMap { $0 })
                    let rightURLs = ListingURL.foldedSet(right.runSourceURLs
                                                         + [right.sourceListingURL].compactMap { $0 })
                    guard !leftURLs.isDisjoint(with: rightURLs) else { continue }
                    sharingAPage += 1
                    print("  wouldJoin[runURL] \(left.groupName) :: \(right.groupName)")
                    if left.performanceDate == right.performanceDate,
                       VenueNormalization.normalizeForKey(left.venue ?? "")
                        == VenueNormalization.normalizeForKey(right.venue ?? "") {
                        sharingPageNightAndRoom += 1
                    }
                }
            }
            print("Filler conjunction rule over \(all.count) rows: \(sharingAPage) pair(s) newly joined "
                  + "where a listing URL is shared, \(sharingPageNightAndRoom) of them also sharing the "
                  + "night and the room.")

            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
