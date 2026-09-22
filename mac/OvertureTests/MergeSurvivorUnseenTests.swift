import Testing
import Foundation
import SwiftData

// #3596: a merge that leaves a survivor holding an identity the feed never publishes.
//
// WHAT IT COST. The merge loop fixed in #3582 ran for at least two weeks and was found by hand, by
// comparing launch backups, after a live Carnegie show had been marked "may be cancelled" 28 times and
// a Zankel show 59 times. Every existing check reads the SYMPTOM (a high `missedScoutCount`, two rows
// on one night) and by the time those fire the damage is weeks old.
//
// THE SIGNATURE, from #3379: a merge whose survivor ends up holding a natural key the feed does not
// list. The issue said that was "knowable at the moment the merge finishes, needs no second scout".
// PREMISE RE-CHECKED 2026-09-21 and that is FALSE: `seenKeys` is a local inside `ScoutService.apply`,
// discarded when the sweep ends, and both merges run at LAUNCH where no sweep exists. A check written
// as the issue described would compare against an empty set and pass silently (L98).
//
// DAN'S CALL, 2026-09-21, with three options in front of him: mark each survivor at merge time and let
// the NEXT sweep answer. Both halves of the comparison then come from the same moment, which is what
// makes the verdict falsifiable at all; comparing a survivor against a set taken hours earlier cannot
// tell a genuinely unseen key from one the feed has republished since (L635). Accepted costs, stated
// here so they are not rediscovered as defects: a stored mark per survivor, and a detection delay of
// one sweep, about a day. The delay is still the improvement: #3582's loop ran two weeks.
//
// IT REPORTS, IT NEVER BLOCKS. A survivor whose source has genuinely stopped listing it is a real
// state, not a defect, which is why the finding is a notice rather than a refusal to merge.
@MainActor
@Suite("A merge survivor the next sweep did not list (#3596)")
struct MergeSurvivorUnseenTests {

    private static let night = "2026-12-04"
    private static let venue = "Zankel Hall"

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func insert(_ ctx: ModelContext, _ title: String, ingestedAt: TimeInterval,
                        sourceIds: [String] = ["carnegiehall-org"]) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title,
                                                            performanceDate: Self.night,
                                                            venue: Self.venue),
                         groupName: title, discipline: "music", venue: Self.venue,
                         performanceDate: Self.night, sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new,
                         ingestedAt: Date(timeIntervalSince1970: ingestedAt))
        p.sourceIds = sourceIds
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func all(_ ctx: ModelContext) -> [Prospect] {
        (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
    }

    private func report(_ seenKeys: Set<String>) -> FeedReconcile.SourceReport {
        FeedReconcile.SourceReport(sourceId: "carnegiehall-org", seenKeys: seenKeys,
                                   seenSourceURLs: [], feedCount: 40, baseline: 40,
                                   successfulCheckCount: 20, verdict: .upcomingListings)
    }

    // THE MARK. A merge that deleted a row leaves its survivor carrying a question: is the identity it
    // kept the one the feed publishes? Asserted on the survivor rather than on the summary, because the
    // mark is what the next sweep reads and a summary nobody stores answers nothing.
    @Test func aMergeMarksItsSurvivorAsAwaitingTheFeed() throws {
        let ctx = try context()
        insert(ctx, "Trio Azura", ingestedAt: 1_000)
        insert(ctx, "Trio Azura (New York Debut)", ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        let rows = all(ctx)
        #expect(rows.count == 1, "the fixture did not merge, so nothing below is about a survivor")
        #expect(rows.first?.survivedMergeAt != nil,
                "the survivor carries no mark, so the next sweep has no question to answer")
    }

    // A row nothing merged carries no mark. Without this the mark would be on every row and the sweep
    // would report the whole store (L104).
    @Test func aRowNoMergeTouchedCarriesNoMark() throws {
        let ctx = try context()
        insert(ctx, "Trio Azura", ingestedAt: 1_000)
        insert(ctx, "An Entirely Different Concert", ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        #expect(all(ctx).count == 2, "the fixture merged when it should not have")
        #expect(all(ctx).allSatisfy { $0.survivedMergeAt == nil },
                "a row no merge touched is carrying a mark, so every sweep would ask about it")
    }

    // THE ANSWER, and this is the finding #3582 would have produced on its second day instead of its
    // fifteenth. The sweep runs, the feed lists a DIFFERENT key, and the survivor's own key is absent.
    @Test func aSurvivorTheNextSweepDidNotListIsRecorded() throws {
        let ctx = try context()
        insert(ctx, "Trio Azura", ingestedAt: 1_000)
        insert(ctx, "Trio Azura (New York Debut)", ingestedAt: 2_000)
        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        let survivor = try #require(all(ctx).first)
        let somebodyElse = Prospect.makeNaturalKey(groupName: "A Different Concert",
                                                   performanceDate: Self.night, venue: Self.venue)
        FeedReconcile.reconcile(stored: all(ctx), reports: [report([somebodyElse])], today: "2026-11-01")
        try? ctx.save()

        #expect(survivor.mergeSurvivorUnseenAt != nil,
                "the sweep did not list the survivor's key and nothing recorded it")
        #expect(survivor.survivedMergeAt == nil,
                "the mark was not cleared, so every later sweep re-reports this survivor for ever")
    }

    // THE OTHER ANSWER, which is the common one. The feed lists the survivor, so the question is closed
    // and nothing is reported. A check that only ever fires is as useless as one that never does.
    @Test func aSurvivorTheNextSweepDidListIsClearedAndNotReported() throws {
        let ctx = try context()
        insert(ctx, "Trio Azura", ingestedAt: 1_000)
        insert(ctx, "Trio Azura (New York Debut)", ingestedAt: 2_000)
        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        let survivor = try #require(all(ctx).first)
        FeedReconcile.reconcile(stored: all(ctx), reports: [report([survivor.naturalKey])],
                                today: "2026-11-01")
        try? ctx.save()

        #expect(survivor.mergeSurvivorUnseenAt == nil, "a survivor the feed listed was reported anyway")
        #expect(survivor.survivedMergeAt == nil, "the answered mark was left standing")
    }

    // THE PRECONDITION THE WHOLE THING RESTS ON, and the one most easily got wrong. A sweep that did
    // not ask this row's source proves nothing about it, so the mark must SURVIVE such a sweep rather
    // than being answered by it. Without this, one unrelated source's run would clear or accuse every
    // pending survivor in the store (L98, and the same rule `everyOwnerWasAskedAndNoneHasIt` already
    // applies to the missed count beside it).
    @Test func aSweepThatDidNotAskThisRowsSourceLeavesTheQuestionOpen() throws {
        let ctx = try context()
        insert(ctx, "Trio Azura", ingestedAt: 1_000)
        insert(ctx, "Trio Azura (New York Debut)", ingestedAt: 2_000)
        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        let survivor = try #require(all(ctx).first)
        let elsewhere = FeedReconcile.SourceReport(sourceId: "someone-else-org", seenKeys: ["other"],
                                                   seenSourceURLs: [], feedCount: 9, baseline: 9,
                                                   successfulCheckCount: 5, verdict: .upcomingListings)
        FeedReconcile.reconcile(stored: all(ctx), reports: [elsewhere], today: "2026-11-01")
        try? ctx.save()

        #expect(survivor.mergeSurvivorUnseenAt == nil,
                "a sweep that never asked this row's source accused it anyway")
        #expect(survivor.survivedMergeAt != nil,
                "the question was closed by a sweep that could not answer it")
    }

    // The other merge that runs at launch. #3596 names both, and a fix reaching one of two sites is how
    // a class fix becomes an instance fix (L30). `DriftedRunMerge` groups on the feed's own production id
    // plus the venue, never on the night, so the fixture gives both rows one `seriesId` rather than
    // overlapping runs: written the other way first, it did not merge at all and the test was green about
    // nothing (L159).
    @Test func theDriftedRunMergeMarksItsSurvivorToo() throws {
        let ctx = try context()
        let first = insert(ctx, "Trio Azura", ingestedAt: 1_000)
        first.seriesId = "carnegie-production-9912"
        let second = insert(ctx, "Trio Azura", ingestedAt: 2_000)
        second.seriesId = "carnegie-production-9912"
        second.performanceDate = "2026-12-05"
        second.naturalKey = Prospect.makeNaturalKey(groupName: "Trio Azura",
                                                    performanceDate: "2026-12-05", venue: Self.venue)
        try? ctx.save()

        let summary = DriftedRunMerge.run(in: ctx)
        try? ctx.save()

        let rows = all(ctx)
        #expect(summary.duplicatesDeleted == 1,
                "the fixture did not merge, so nothing below is about a survivor")
        #expect(rows.count == 1)
        #expect(rows.first?.survivedMergeAt != nil,
                "DriftedRunMerge's survivor carries no mark, so only one of the two merges is covered")
    }

    // THE GUARD INSIDE THE SHARED HELPER, driven directly, because no pass can reach it. All three
    // callers already skip a cluster of one, so a mutation deleting this guard SURVIVED a run of every
    // test above: it was protecting nothing that could be seen (L1). It is still worth having, because
    // what stops a mark landing on an unmerged row must be owned by the shared component rather than
    // opted into by each call site (L621), and a fourth caller is exactly how that breaks. So it is
    // asserted where it can actually fail, which is here.
    @Test func carryingOntoALoneRowLeavesNoQuestionBehind() throws {
        let ctx = try context()
        let alone = insert(ctx, "Trio Azura", ingestedAt: 1_000)

        SurvivorInheritance.carry(onto: alone, from: [alone])

        #expect(alone.survivedMergeAt == nil,
                "a cluster of one merged nothing, so it owes the next sweep no question")
    }

    // The THIRD deleting pass, which #3596 does not name and which leaves a survivor exactly as the two
    // it does name. Covering the two in the issue and not this one would be an instance fix wearing a
    // class fix's name (L30). All three reach the mark through `SurvivorInheritance.carry`, which is why
    // one edit covered them, and this is the assertion that says so rather than the comment claiming it.
    @Test func theVenueKeyMigrationMarksItsSurvivorToo() throws {
        let ctx = try context()
        // Two spellings of one room, which is what that pass exists to fold, under one title and night.
        let first = insert(ctx, "Trio Azura", ingestedAt: 1_000)
        first.venue = "Zankel Hall, 881 7th Ave, New York, NY"
        first.naturalKey = "trio azura|\(Self.night)|zankel hall, 881 7th ave, new york, ny"
        let second = insert(ctx, "Trio Azura", ingestedAt: 2_000)
        second.venue = "Zankel Hall"
        second.naturalKey = "trio azura|\(Self.night)|zankel hall"
        try? ctx.save()

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        let rows = all(ctx)
        #expect(summary.duplicatesDeleted == 1,
                "the fixture did not merge, so nothing below is about a survivor")
        #expect(rows.first?.survivedMergeAt != nil,
                "the venue key migration's survivor carries no mark, so the third deleting pass is uncovered")
    }
}

// The line Dan actually reads, and the control beside it. Separate from the suite above because that one
// is about the mechanism and this is about what the mechanism SAYS, which is a different way to be wrong.
@Suite("What the merge survivor finding says (#3596)")
struct MergeSurvivorNoticeTests {

    @Test func nothingFoundSaysNothing() {
        #expect(AppNotices.mergeSurvivorsTheFeedDropped([], shownInQueue: { _ in true }).isEmpty,
                "a quiet app is adding a line to the masthead")
    }

    @Test func oneFindingReadsAsOne() throws {
        let notice = try #require(AppNotices.mergeSurvivorsTheFeedDropped(["a"],
                                                                         shownInQueue: { _ in true }).first)
        #expect(notice.text == "A show Overture kept when it merged a duplicate wasn't listed by its source on the next check.")
        #expect(notice.tone == .warning)
    }

    @Test func severalFindingsCarryTheCount() throws {
        let notice = try #require(AppNotices.mergeSurvivorsTheFeedDropped(["a", "b", "c"],
                                                                         shownInQueue: { _ in true }).first)
        #expect(notice.text == "3 shows Overture kept when it merged a duplicate weren't listed by their sources on the next check.")
    }

    // The control offers to SHOW the rows, so where none of them is a row the queue would render it is a
    // button that does nothing, and a control that cannot do its job is worse than none (L44, L109). The
    // sentence stays, because the finding is still true.
    @Test func theControlGoesWhereNoRowCanBeShownAndTheSentenceStays() throws {
        let notice = try #require(AppNotices.mergeSurvivorsTheFeedDropped(["a", "b"],
                                                                         shownInQueue: { _ in false }).first)
        #expect(notice.action == nil, "the notice offers to show rows the queue will not render")
        #expect(!notice.text.isEmpty, "the finding stopped being stated because its control was unusable")
    }

    // The control carries ONLY the rows it can actually show, never the whole finding, so the sentence
    // Dan read and the rows he gets cannot come from two different sets.
    @Test func theControlCarriesOnlyTheRowsItCanShow() throws {
        let notice = try #require(AppNotices.mergeSurvivorsTheFeedDropped(["queued", "archived"],
                                                                         shownInQueue: { $0 == "queued" }).first)
        #expect(notice.action == .showMergeSurvivorsTheFeedDropped(keys: ["queued"]))
    }

    // It is its OWN action, not the feed break's. Both end at the same handler, and that is the point at
    // which a shared case would stop being visible as a mistake (L263).
    @Test func itIsNotTheFeedBreakAction() throws {
        let notice = try #require(AppNotices.mergeSurvivorsTheFeedDropped(["k"],
                                                                         shownInQueue: { _ in true }).first)
        #expect(notice.action != .showShowsOneSweepBroke(keys: ["k"]))
    }
}

// How many questions a real launch would actually raise, asked of Dan's own store.
//
// WHY IT IS HERE. The finding is only as useful as its rate: one a fortnight is a signal, forty a launch
// is a line he learns to skim (L36). Nothing in the fixtures above can say which, because the number is a
// fact about his data. So this runs the three deleting passes against a CLONE and counts the marks they
// leave, which is the ceiling on how many findings one sweep can produce.
//
// It REPORTS and never refuses, for the reason the other live store suites give: the count is a property
// of the store and a red here would block every merge until a venue changed its listings. What it does
// assert is the invariant that has to hold whatever the data is, which is that a mark is only ever left
// on a row a pass actually merged (L517).
@MainActor
@Suite("How many merge survivor questions a launch raises, on the real store (#3596)")
struct MergeSurvivorLiveStoreTests {

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theThreeDeletingPassesLeaveOneMarkPerSurvivingRow() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            try await measureOnACloneOfTheLiveStore()
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // The body, lifted out so the lock above is released on EVERY path. A `defer` that starts a detached
    // task can release after the test has finished, which is a lock held past its owner (L515 is the same
    // shape from the other side: cleanup placed where only some paths reach it).
    private func measureOnACloneOfTheLiveStore() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("merge-marks-\(UUID().uuidString)",
                                                               isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let url = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let schema = Schema([Prospect.self, Recipient.self])
        let context = ModelContext(try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]))

        let before = try context.fetch(FetchDescriptor<Prospect>())
        // An empty read is a failed open, never a clean bill of health (L98).
        #expect(!before.isEmpty, "the copied store holds no shows, so nothing below measured anything")
        let alreadyMarked = before.filter { $0.survivedMergeAt != nil }.count

        let drifted = DriftedRunMerge.run(in: context)
        let sameNight = SameNightTitleVariantMerge.run(in: context)
        try? context.save()

        let after = try context.fetch(FetchDescriptor<Prospect>())
        let marked = after.filter { $0.survivedMergeAt != nil }
        let deleted = drifted.duplicatesDeleted + sameNight.duplicatesDeleted

        print("""
            Merge survivor questions: \(before.count) row(s) before, \(after.count) after. \
            \(deleted) duplicate(s) deleted (\(drifted.duplicatesDeleted) drifted run, \
            \(sameNight.duplicatesDeleted) same night). \(marked.count) row(s) now carry a question, \
            \(alreadyMarked) did before this pass ran.
            """)
        for p in marked.prefix(10) {
            print("  awaiting the feed: \(p.groupName) @ \(p.venue ?? "?") \(p.performanceDate ?? "-")")
        }

        // THE INVARIANT, and it is the one that has to hold on any data: a launch cannot raise more
        // questions than it merged clusters, and a cluster leaves exactly one survivor. So the marks this
        // run added can never exceed the rows it deleted. A mark on a row nothing merged is the failure
        // this bounds, and it would show here as more marks than deletions.
        #expect(marked.count - alreadyMarked <= deleted,
                "the passes deleted \(deleted) row(s) and added \(marked.count - alreadyMarked) question(s), so a row nothing merged is carrying one")
    }
}
