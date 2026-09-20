import Testing
import Foundation
import SwiftData

// #1802: seven issues were one cause wearing different clothes. A venue's name was folded into a key by
// more than one code path, and its city was derived separately from its name, which produced duplicate
// cards for one room (#1761), 131 cards claiming the city was unknown while the app held it (#1762), one
// night stored as three rows with three paid contact answers (#1764), 163 cards naming their own room as
// the presenter (#1795), and an address typed on a source row that never reached the shows already in the
// queue (#1751, #1752).
//
// Each had been fixed in isolation before, and a fix to one silently re-broke another, because the folds
// were parallel rather than shared. So the closing condition #1802 set for itself was never "the seven are
// fixed" but "the seven are MEASURED TOGETHER, on the real store, after one shared identity landed".
//
// This is that measurement, kept rather than run once, so the symptoms cannot come back one at a time
// while every issue behind them reads closed. Each expectation below is the invariant, not the count that
// happened to be true on the day: the counts move with every scout, the rules do not.
//
// #3769 asked whether the identity check should be WIDENED or RETIRED, because it reports zero candidate
// buckets on every run and its neighbours do not. The answer taken on 2026-09-19 is NEITHER, and it is
// recorded here rather than in the issue because this is the file somebody reads next.
//
// The zero is the invariant HOLDING. That was not provable before: nothing here had ever been seen to
// fail, so a rule that found nothing and a rule that could see nothing read identically (L1, L182). Three
// negative controls below now build the fault by hand, and both arms were confirmed red by breaking the
// fold on purpose with `scripts/mutate.sh` (CAUGHT on the venue fold and on the title fold).
//
// Not widened, because the reason it is thin is not the one the issue guessed. It named the exact-date
// component and the non-dismissed filter. Measured: 124 room-and-nights hold more than one row, and the
// TITLE is what separates them. Most of those are correct, since a busy room plays two different shows in
// an evening, and relaxing the title here would silence warnings that are right. The two mechanisms that
// legitimately relax it already exist and are not this one, so widening would be a third copy of that
// judgement (#4022 records which mechanism covers which).
//
// Reads a copy of the live store and writes nothing anywhere.
@Suite("One venue identity, measured on the real store (#1802)")
// #3065: `final class` so the sandbox goes with each test. These held a whole clone of the live store,
// about 4 MB each, which is why 56 of them accounted for 1.62 GB when the issue was measured.
final class OneVenueIdentityLiveStoreTests {
    private let sandboxes = TemporarySandboxes()

    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath:
            StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false).path)
    }

    // #3615: the CONTEXT as well as the rows, because one of the symptoms below is an invariant a launch
    // repair restores and has to be measured after that repair has run (L385). It is a copy, so running
    // one against it writes nothing anywhere near the live store (L2).
    private func liveContext() throws -> ModelContext {
        let dir = try sandboxes.make(named: "venue-identity")
        guard let url = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]))
    }

    private func liveProspects() throws -> [Prospect] {
        try liveContext().fetch(FetchDescriptor<Prospect>())
    }

    // LIVE-STORE-CLAIM verified=2026-08-07 measure="the seven venue-identity symptoms, re-counted together on the real store"
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theSevenSymptomsAreMeasuredTogether() async throws {
        await RealStoreTestLock.shared.acquire()
        // #2198: released INLINE on both paths, never from a Task. A `defer { Task { ... } }` hands
        // the release to an unstructured task that runs after the test has already returned, so the
        // critical section is not exclusive at all. That is #2190: the process died partway and three
        // consecutive runs each blamed a different innocent test while 600 to 1,500 tests silently
        // never ran (#2195).
        do {

            let ctx = try liveContext()
            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            #expect(all.count > 100, "the live store still holds a real queue to measure")
            let live = all.filter { $0.status != .dismissed }

            // #1795: a room standing in as its own show's presenter. `RoomPresenterSweep` runs every launch and
            // is idempotent by construction, so a row in this state can only be one written since the last
            // launch, which is a claim about the boundary guard rather than about the sweep.
            let roomAsPresenter = live.filter { p in
                guard let named = p.presenter, !named.isEmpty else { return false }
                let asRead = ExtractedEvent(title: p.groupName, presenter: named, venue: p.venue)
                return ExtractedEventGuard.presenterThatIsNotTheRoom(asRead).presenter == nil
            }
            #expect(roomAsPresenter.isEmpty,
                    "#1795: \(roomAsPresenter.count) row(s) still name their own room as the presenter: \(roomAsPresenter.prefix(3).map(\.groupName))")

            // #1762: a card saying the city is unknown for a room the app can place. The queue's own table is
            // the authority, so a blank location on a row whose venue the table knows is the app failing to
            // apply what it already holds.
            let placeableButBlank = live.filter { p in
                (p.location ?? "").isEmpty && VenuePlaces.location(for: p.venue) != nil
            }
            #expect(placeableButBlank.isEmpty,
                    "#1762: \(placeableButBlank.count) row(s) have no city while the venue table holds one: \(placeableButBlank.prefix(3).map { "\($0.groupName) [\($0.venue ?? "-")]" })")

            // #1761 / #1764: one room spelled two ways, minting a second card for the same night. Judged
            // through the SHARED identity (`VenuePlaces.canonicalKey`), which is the whole point of the issue:
            // two rows that are one show must collide on it.
            //
            // #3615: measured AFTER the launch repair, on the same copy, which is what the two symptoms
            // above already assume of their own sweeps ("runs every launch and is idempotent, so a row in
            // this state can only be one written since the last launch"). Without it this asserts an
            // invariant a SCHEDULED repair restores, so between two launches the violated state is the
            // store's normal one and the check reports the interval rather than a defect (L385). It went
            // red exactly that way on 2026-09-07, on two shows the pass now collapses.
            //
            // What survives the repair is what this is for, and it is the population that matters: a
            // deferred conflict (two rows each carrying a decision of Dan's) is one the pass refuses to
            // resolve blind, so it stays and is still reported here.
            // #3496: the WHOLE launch, not this one pass. `DriftedRunMerge` and
            // `SameNightTitleVariantMerge` both run after it and are the passes that actually clear a
            // same-night duplicate, so replaying only this one asserted "no duplicates remain" having
            // replayed none of the work that removes them (L385, L41).
            // #3496: the candidate population, counted BEFORE the replay. Counting after answers "is the
            // store clean now", which the assertion below already answers, and it cannot tell a store that
            // had nothing to fix from one the replay fixed. Those are opposite facts, and the question this
            // line exists to answer is whether the check had anything to examine at all (L182, L98, L11).
            let bucketsBefore = Self.identityBuckets(live)
            let doubledBefore = bucketsBefore.filter { $0.value.count > 1 }.count
            LaunchReplay.run(in: ctx, handoffDirectory: try sandboxes.make(named: "venue-identity-handoff"))
            try ctx.save()
            let repaired = (try ctx.fetch(FetchDescriptor<Prospect>())).filter { $0.status != .dismissed }
            let seen = Self.identityBuckets(repaired)
            let duplicates = seen.filter { $0.value.count > 1 }
            // #3769: the POPULATION THE RULE SEPARATED, printed beside the population it examined,
            // because `0 of 628` on its own cannot tell a rule that found nothing from a rule that can
            // see nothing, and that ambiguity is what #3769 was filed about (L182, L98).
            //
            // The same rows, bucketed by room and night with the TITLE left out. Anything in a doubled
            // bucket here is two rows in one room on one night that the identity rule separated on their
            // titles. Most of them are correct: a busy room plays two different shows in an evening, and
            // #3278 measured roughly nine such pairs it must keep apart. It is a readout and never an
            // assertion, for exactly that reason.
            //
            // It also answers the question #3769 asked and guessed wrong about. That issue named the
            // exact-date component and the non-dismissed filter as the two candidate reasons the rule
            // has no subjects. Measured 2026-09-19 by folding the title to a constant: 124 buckets hold
            // more than one row. So the rows exist, share a room and share a night, and it is the TITLE
            // that separates them. Relaxing the title is not this rule's job: `SameNightTitleVariantMerge`
            // (same night, title plus or minus a subtitle) and `ShowLink` (folded title, intersecting
            // night) are the two mechanisms that already own it, and #4022 records which covers which.
            var byRoomAndNight: [String: Int] = [:]
            for p in repaired {
                guard let date = p.performanceDate, !date.isEmpty else { continue }
                byRoomAndNight["\(date)|\(VenuePlaces.canonicalKey(for: p.venue) ?? "unplaced")",
                               default: 0] += 1
            }
            let sharedRoomNights = byRoomAndNight.filter { $0.value > 1 }.count

            print("One venue identity corpus: \(doubledBefore) identity bucket(s) held more than one live "
                  + "row before the launch replay, out of \(bucketsBefore.count); "
                  + "\(seen.filter { $0.value.count > 1 }.count) after")
            print("  of those, \(sharedRoomNights) room-and-night(s) held more than one row and were "
                  + "separated on their titles, so the rule had subjects to discriminate among")
            #expect(duplicates.isEmpty,
                    "#1761/#1764: \(duplicates.count) show(s) are stored more than once under one identity: \(duplicates.keys.sorted().prefix(3))")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // ONE definition of the identity bucket, used for the before count and the after assertion alike. Two
    // spellings of the same fold is how these symptoms came back last time, and a readout computed by a
    // second copy of the rule would be reporting about a different population than the check (L70, L107).
    private static func identityBuckets(_ rows: [Prospect]) -> [String: [Prospect]] {
        var seen: [String: [Prospect]] = [:]
        for p in rows {
            guard let date = p.performanceDate, !date.isEmpty else { continue }
            let venueKey = VenuePlaces.canonicalKey(for: p.venue) ?? "unplaced"
            let titleKey = TitleNormalization.normalizeForKey(p.groupName)
            seen["\(titleKey)|\(date)|\(venueKey)", default: []].append(p)
        }
        return seen
    }

    // #3769: the NEGATIVE CONTROL, and the direct answer to "this check passes by having nothing to
    // test".
    //
    // The live assertion above has reported ZERO candidate buckets on every run since #3496 taught it to
    // say how many it had: 0 of 593 on 2026-09-10, 0 of 628 on 2026-09-19. That zero is the invariant
    // HOLDING rather than a rule that cannot see anything, and the distinction is exactly what nothing
    // proved. A ratchet driven to zero stops being read as a measurement and starts being read as proof
    // the fault cannot occur, so nobody re-examines it (L182), and a guard is only real once it has been
    // seen to fail (L1).
    //
    // So this builds the fault by hand and asserts the SAME `identityBuckets` function catches it. It
    // uses no live store, writes nothing, and runs in milliseconds, which is why it can be an ordinary
    // test rather than a second clone.
    private func memoryContext() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema,
                                                                isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func row(_ ctx: ModelContext, key: String, title: String, venue: String,
                     date: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: title, discipline: "music", venue: venue,
                         performanceDate: date, sourceListingURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "unknown", coverage: "unknown", fitScore: 3,
                         tier: "medium", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: nil, partOfRelatedRun: false, runSourceURLs: [],
                         runNights: [date])
        ctx.insert(p)
        return p
    }

    // The #1761/#1764 fault itself: one show, one night, one room spelled two ways. The two spellings
    // are the ones `oneIdentityAnswersForEverySpellingOfARoom` below already pins as one place, so this
    // cannot pass by accident of a fold that stopped agreeing.
    @Test func theRuleStillCatchesOneShowStoredTwiceUnderTwoSpellingsOfOneRoom() throws {
        let ctx = try memoryContext()
        let a = row(ctx, key: "a", title: "Berliner Philharmoniker", venue: "Carnegie Hall",
                    date: "2026-11-14")
        let b = row(ctx, key: "b", title: "Berliner Philharmoniker",
                    venue: "Carnegie Hall, 881 Seventh Avenue", date: "2026-11-14")

        let buckets = Self.identityBuckets([a, b])
        let doubled = buckets.filter { $0.value.count > 1 }
        #expect(doubled.count == 1,
                "one show at one room on one night, the room spelled two ways, must land in ONE bucket")
        #expect(buckets.count == 1, "and must not also leave a second bucket behind")
    }

    // The other direction, so the control above cannot be satisfied by a rule that buckets everything
    // together. Two genuinely different shows in one room on one night stay apart.
    @Test func theRuleKeepsTwoDifferentShowsInOneRoomApart() throws {
        let ctx = try memoryContext()
        let a = row(ctx, key: "a", title: "Tuudr Piano Competition Gala", venue: "Weill Recital Hall",
                    date: "2026-10-10")
        let b = row(ctx, key: "b", title: "Special Venue Music Awards Winners Recital",
                    venue: "Weill Recital Hall", date: "2026-10-10")

        let buckets = Self.identityBuckets([a, b])
        #expect(buckets.filter { $0.value.count > 1 }.isEmpty,
                "two different shows sharing a room on one night are not one identity")
        #expect(buckets.count == 2)
    }

    // And the same night in two DIFFERENT rooms, which is the arm a fold collapsing every venue to one
    // key would break while both tests above still passed.
    @Test func theRuleKeepsOneShowInTwoDifferentRoomsApart() throws {
        let ctx = try memoryContext()
        let a = row(ctx, key: "a", title: "Berliner Philharmoniker", venue: "Carnegie Hall",
                    date: "2026-11-14")
        let b = row(ctx, key: "b", title: "Berliner Philharmoniker", venue: "The Green Room 42",
                    date: "2026-11-14")

        #expect(Self.identityBuckets([a, b]).count == 2,
                "one act in two rooms on one night is two rows on purpose")
    }

    // The other half of #1802, and the one a count cannot show: that there is ONE fold. A second spelling
    // of the same question is how these symptoms came back last time, so the identity every rule uses is
    // asserted to agree with itself across the spellings the store really holds.
    @Test func oneIdentityAnswersForEverySpellingOfARoom() {
        let spellings = [
            ["Carnegie Hall", "Carnegie Hall, 881 Seventh Avenue", "carnegie hall"],
            ["The Green Room 42", "The Green Room 42, 570 Tenth Avenue", "Green Room 42"],
            ["54 Below", "54 Below, 254 W 54th St. Cellar, NYC 10019", "54 Below, New York, NY"],
        ]
        for group in spellings {
            let keys = Set(group.map { VenuePlaces.canonicalKey(for: $0) ?? "nil" })
            #expect(keys.count == 1,
                    "one room resolved to \(keys.count) identities: \(group) -> \(keys.sorted())")
        }
    }
}
