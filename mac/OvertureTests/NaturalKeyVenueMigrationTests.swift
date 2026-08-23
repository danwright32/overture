import Testing
import Foundation
import SwiftData

// #1064: existing prospects carry their OLD, unfolded natural keys, so a fresh scout of a differently
// spelled venue would not dedupe against them. NaturalKeyVenueMigration re-keys stored rows with the new
// venue normalization and reconciles the duplicates that fold together, merging only provably-empty
// duplicates and deferring (never blindly merging) a collision where two rows both carry outreach history.
@MainActor
@Suite("Natural-key venue re-keying migration (#1064)")
struct NaturalKeyVenueMigrationTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // Inserts a prospect with an explicitly chosen (possibly legacy) stored key, so a test can reproduce a
    // store where the same show sits twice under two different venue spellings.
    @discardableResult
    private func insert(_ ctx: ModelContext, key: String, group: String, date: String, venue: String,
                        ingestedAt: Date = Date(), configure: (Prospect) -> Void = { _ in }) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: venue,
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new, ingestedAt: ingestedAt)
        configure(p)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func allProspects(_ ctx: ModelContext) -> [Prospect] {
        (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
    }

    private func foldedKey(_ group: String, _ date: String, _ venue: String) -> String {
        Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: venue)
    }

    // The Cutting Room pair, both untriaged: they collapse to one row, keyed by the folded key, and the
    // unrelated show is left completely alone.
    @Test func twoPristineDuplicatesCollapseToOneAndOthersAreUntouched() throws {
        let ctx = try context()
        let group = "GATA Jazz Trio", date = "2026-07-18"
        let folded = foldedKey(group, date, "The Cutting Room")

        insert(ctx, key: folded, group: group, date: date, venue: "The Cutting Room",
               ingestedAt: Date(timeIntervalSince1970: 1_000))
        insert(ctx, key: "legacy-address-key", group: group, date: date,
               venue: "The Cutting Room, 44 East 32nd Street, New York, NY",
               ingestedAt: Date(timeIntervalSince1970: 2_000))
        // An unrelated show that must never be touched.
        let otherKey = foldedKey("Some Other Act", "2026-08-15", "Zankel Hall")
        insert(ctx, key: otherKey, group: "Some Other Act", date: "2026-08-15", venue: "Zankel Hall")

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 1)
        #expect(summary.conflictsDeferred == 0)
        let all = allProspects(ctx)
        #expect(all.count == 2)   // the duplicate pair became one, plus the unrelated show
        #expect(all.filter { $0.naturalKey == folded }.count == 1)
        #expect(all.contains { $0.naturalKey == otherKey })   // unrelated show survived untouched
    }

    // LIVE-STORE-CLAIM verified=2026-07-28 measure="the duplicate pairs a parenthetical venue split, and which row of each carries the current client match"
    // #1686: which of two PRISTINE duplicates survives is not a coin toss, because the rows disagree.
    // A row is only re-matched and re-scored when a sweep finds it BY KEY, so the row whose key split
    // stopped being found and silently kept whatever the rules said the day it was ingested. On the live
    // store row 163 still reads "no prior relationship, score 7" from 2026-07-17, two days before #1216
    // taught the matcher to read the presenter field; its twin, seen on 2026-07-26, reads "booked, score
    // 27" against the Downbeat client Young New Yorkers Chorus. Both are correct arithmetic on different
    // facts, and only one of them is current.
    //
    // `ingestedAt` is rewritten on every re-scout (ScoutService "existing.ingestedAt = Date()"), so it
    // means LAST SEEN. Keeping the earliest therefore kept exactly the stale row and deleted the correct
    // one, leaving one card that actively lies about the relationship. The freshest row survives instead,
    // and inherits the earliest firstSeenAt in the group so the funnel's opening node is not lost.
    @Test func theFreshestOfTwoPristineDuplicatesSurvivesAndKeepsTheEarliestFirstSighting() throws {
        let ctx = try context()
        let group = "Summer Community Sings", date = "2026-08-04"
        let stale = Date(timeIntervalSince1970: 1_000)
        let fresh = Date(timeIntervalSince1970: 2_000)

        insert(ctx, key: "legacy-parenthetical-key", group: group, date: date,
               venue: "St. Paul's Episcopal Church (Carroll Gardens)", ingestedAt: stale) {
            $0.fitScore = 7
            $0.priorRelationship = "none"
            $0.firstSeenAt = stale
        }
        insert(ctx, key: foldedKey(group, date, "St. Paul's Episcopal Church"), group: group, date: date,
               venue: "St. Paul's Episcopal Church", ingestedAt: fresh) {
            $0.fitScore = 27
            $0.priorRelationship = "booked"
            $0.matchedClientName = "Young New Yorkers Chorus"
            $0.firstSeenAt = fresh
        }

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 1)
        let all = allProspects(ctx)
        #expect(all.count == 1)
        let survivor = try #require(all.first)
        #expect(survivor.fitScore == 27)
        #expect(survivor.priorRelationship == "booked")
        #expect(survivor.matchedClientName == "Young New Yorkers Chorus")
        #expect(survivor.firstSeenAt == stale, "the show was first seen on the earlier date, not the merge date")
    }

    // When exactly one of the colliding rows carries outreach history, that row survives (with its
    // history), the pristine duplicate is deleted, and the survivor takes the folded key.
    @Test func theRowWithHistorySurvivesAndKeepsItsHistory() throws {
        let ctx = try context()
        let group = "Love Is Live", date = "2026-08-01"
        let folded = foldedKey(group, date, "The Players Theatre")

        // The pristine bare row happens to already hold the folded key.
        insert(ctx, key: folded, group: group, date: date, venue: "The Players Theatre")
        // The address-spelled row was actually contacted: it must be the survivor.
        let contacted = insert(ctx, key: "legacy-address-key", group: group, date: date,
                               venue: "The Players Theatre, 115 MacDougal Street, New York, NY") { p in
            p.status = .contacted
            p.sentAt = Date(timeIntervalSince1970: 5_000)
            p.gmailMessageId = "msg-123"
        }

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 1)
        let all = allProspects(ctx)
        #expect(all.count == 1)
        let survivor = all[0]
        #expect(survivor === contacted)              // the contacted row won
        #expect(survivor.sentAt != nil)              // its history is intact
        #expect(survivor.gmailMessageId == "msg-123")
        #expect(survivor.naturalKey == folded)       // and it now carries the folded key
    }

    // When TWO colliding rows each carry history, the migration refuses to merge blind: both rows stay,
    // with their original keys, and the conflict is reported for Dan to reconcile.
    @Test func twoRowsBothCarryingHistoryAreDeferredNotMerged() throws {
        let ctx = try context()
        let group = "Off the Chart", date = "2026-07-22"

        let a = insert(ctx, key: "legacy-key-a", group: group, date: date, venue: "The Cutting Room") { p in
            p.status = .contacted
            p.sentAt = Date(timeIntervalSince1970: 3_000)
        }
        let b = insert(ctx, key: "legacy-key-b", group: group, date: date,
                       venue: "The Cutting Room, 44 East 32nd Street, New York, NY") { p in
            p.status = .dismissed
            p.showOutcomeRaw = ShowOutcome.notAFit.rawValue
        }

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        #expect(summary.conflictsDeferred == 1)
        #expect(summary.duplicatesDeleted == 0)
        let all = allProspects(ctx)
        #expect(all.count == 2)                       // nothing dropped
        #expect(a.naturalKey == "legacy-key-a")       // keys left exactly as they were
        #expect(b.naturalKey == "legacy-key-b")
    }

    // Running twice is a no-op the second time: after the first pass every row already holds its folded
    // key, so nothing is re-keyed or deleted again.
    // MARK: - #3124: a decision of Dan's is carried onto the survivor, never deleted with its row
    //
    // The merge picks one survivor and deletes the rest, and none of the three tests standing between a
    // row and that delete can see a decision that did not move the row's stage. A row still at `new`
    // holding only his rename loses to any fresher pristine duplicate, and the scout never reproduces
    // his name.

    @Test func aRenameOnTheLosingRowIsCarriedOntoTheSurvivor() throws {
        let ctx = try context()
        let group = "GATA Jazz Trio", date = "2026-07-18"
        let folded = foldedKey(group, date, "The Cutting Room")

        // The renamed row is the OLDER one, so the freshest-wins tie-break would delete it.
        insert(ctx, key: "legacy-address-key", group: "Dan's own name for them", date: date,
               venue: "The Cutting Room, 44 East 32nd Street, New York, NY",
               ingestedAt: Date(timeIntervalSince1970: 1_000)) { p in
            p.groupNameOverriddenByDan = true
            p.scoutGroupName = group
        }
        insert(ctx, key: folded, group: group, date: date, venue: "The Cutting Room",
               ingestedAt: Date(timeIntervalSince1970: 2_000))

        _ = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        let rows = allProspects(ctx)
        #expect(rows.count == 1, "the duplicates should still collapse: carrying is not deferring")
        let survivor = try #require(rows.first)
        #expect(survivor.groupNameOverriddenByDan,
                "the survivor must know Dan renamed this show, or the next scout overwrites his name")
        #expect(survivor.groupName == "Dan's own name for them",
                "the flag and the NAME move together: a survivor claiming a rename while showing the scout's wording asserts the opposite of what happened")
    }

    @Test func keptVisibleAfterAGenreChangeSurvivesTheMerge() throws {
        let ctx = try context()
        let group = "GATA Jazz Trio", date = "2026-07-18"
        let folded = foldedKey(group, date, "The Cutting Room")

        insert(ctx, key: "legacy-address-key", group: group, date: date,
               venue: "The Cutting Room, 44 East 32nd Street, New York, NY",
               ingestedAt: Date(timeIntervalSince1970: 1_000)) { $0.keptVisibleAfterGenreChange = true }
        insert(ctx, key: folded, group: group, date: date, venue: "The Cutting Room",
               ingestedAt: Date(timeIntervalSince1970: 2_000))

        _ = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        let survivor = try #require(allProspects(ctx).first)
        #expect(allProspects(ctx).count == 1)
        #expect(survivor.keptVisibleAfterGenreChange,
                "a false flag is what a row holds for never having been asked, so any member saying yes is the decision")
    }

    // Dan's call, 2026-08-22, on the case the issue said to decide rather than assume: keep ONE card and
    // carry BOTH decisions onto it, rather than deferring the merge or dropping one of them.
    @Test func twoMembersEachCarryingADifferentDecisionKeepBothOnOneCard() throws {
        let ctx = try context()
        let group = "GATA Jazz Trio", date = "2026-07-18"
        let folded = foldedKey(group, date, "The Cutting Room")

        insert(ctx, key: "legacy-address-key", group: "Dan's own name for them", date: date,
               venue: "The Cutting Room, 44 East 32nd Street, New York, NY",
               ingestedAt: Date(timeIntervalSince1970: 1_000)) { p in
            p.groupNameOverriddenByDan = true
            p.scoutGroupName = group
        }
        insert(ctx, key: folded, group: group, date: date, venue: "The Cutting Room",
               ingestedAt: Date(timeIntervalSince1970: 2_000)) { $0.keptVisibleAfterGenreChange = true }

        _ = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        let rows = allProspects(ctx)
        #expect(rows.count == 1, "one card, not a deferral")
        let survivor = try #require(rows.first)
        #expect(survivor.groupNameOverriddenByDan && survivor.groupName == "Dan's own name for them",
                "the rename came from the row that held it")
        #expect(survivor.keptVisibleAfterGenreChange,
                "and the keep-visible decision came from the other one")
    }

    // The other direction, so the carry cannot quietly overwrite a decision it was meant to protect: a
    // survivor that already carries Dan's own rename keeps ITS name, not a loser's.
    @Test func aSurvivorsOwnRenameIsNotOverwrittenByALosers() throws {
        let ctx = try context()
        let group = "GATA Jazz Trio", date = "2026-07-18"
        let folded = foldedKey(group, date, "The Cutting Room")

        insert(ctx, key: "legacy-address-key", group: "the older name he gave it", date: date,
               venue: "The Cutting Room, 44 East 32nd Street, New York, NY",
               ingestedAt: Date(timeIntervalSince1970: 1_000)) { p in
            p.groupNameOverriddenByDan = true
            p.scoutGroupName = group
        }
        insert(ctx, key: folded, group: "the name on the surviving row", date: date,
               venue: "The Cutting Room",
               ingestedAt: Date(timeIntervalSince1970: 2_000)) { p in
            p.groupNameOverriddenByDan = true
            p.scoutGroupName = group
        }

        _ = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        let survivor = try #require(allProspects(ctx).first)
        #expect(survivor.groupName == "the name on the surviving row",
                "ranking Dan's decisions against each other is not this pass's to do: only an UNDECIDED survivor is filled in")
    }

    @Test func runningTwiceIsIdempotent() throws {
        let ctx = try context()
        let group = "STEVEN MAGLIO & HIS BIG BAND ORCHESTRA", date = "2026-07-19"
        let folded = foldedKey(group, date, "The Cutting Room")
        insert(ctx, key: folded, group: group, date: date, venue: "The Cutting Room")
        insert(ctx, key: "legacy-address-key", group: group, date: date,
               venue: "The Cutting Room, 44 East 32nd Street, New York, NY")

        _ = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()
        let afterFirst = allProspects(ctx).count

        let second = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        #expect(second == NaturalKeyVenueMigration.Summary())   // all zeros
        #expect(allProspects(ctx).count == afterFirst)          // nothing removed on the second pass
    }

    // A lone row that carries an embedded address (no duplicate twin) is simply re-keyed to its folded
    // form, so a future scout of the bare spelling dedupes against it. Nothing is deleted.
    // #1498: the shape this migration could not see until the key stopped carrying the trailing location.
    // LIVE-STORE-CLAIM verified=2026-07-25 measure="pairs of rows split by a venue spelling variant, every one untriaged with no outreach"
    // Measured on the live store 2026-07-25: 29 pairs exactly like this one, every row untriaged with no
    // recipients and nothing sent, so Dan was triaging the same night twice. The two Jalopy spellings are
    // the live case verbatim.
    @Test func aVenueWithAndWithoutItsTrailingLocationCollapsesToOneShow() throws {
        let ctx = try context()
        let group = "Bruce Molsky & Darol Anger", date = "2026-07-25"
        let folded = foldedKey(group, date, "Jalopy Theatre")

        insert(ctx, key: "old-bare", group: group, date: date, venue: "Jalopy Theatre",
               ingestedAt: Date(timeIntervalSince1970: 100))
        let freshest = insert(ctx, key: "old-with-location", group: group, date: date,
                              venue: "Jalopy Theatre, Red Hook, Brooklyn, NY",
                              ingestedAt: Date(timeIntervalSince1970: 200))

        let summary = NaturalKeyVenueMigration.run(in: ctx)

        let remaining = allProspects(ctx)
        #expect(remaining.count == 1, "one show must be one row")
        // #1686 changed this deliberately: it used to be the earliest-ingested row. `ingestedAt` is
        // rewritten on every re-scout, so the earliest is the row that STOPPED being found by key, and
        // it carries whatever the matching and scoring rules said on the day it went stale. Keeping it
        // deletes the row that holds the current verdict.
        #expect(remaining.first === freshest, "the most recently seen row survives when both are pristine")
        #expect(remaining.first?.naturalKey == folded)
        #expect(summary.duplicatesDeleted == 1)
    }

    // The parent-building spelling from the same audit (eight Carnegie shows). Worth its own case because
    // NEITHER stored key equals the new folded key, so without this pass a fresh scout would have added a
    // THIRD row rather than converging on one of the two.
    @Test func aParentBuildingSpellingCollapsesTooAndLeavesNoStaleKey() throws {
        let ctx = try context()
        let group = "A Gospel of Gratitude", date = "2026-11-28"
        let venue = "Stern Auditorium/Perelman Stage"
        let folded = foldedKey(group, date, venue)

        insert(ctx, key: "old-long", group: group, date: date,
               venue: "\(venue), Carnegie Hall, New York, NY",
               ingestedAt: Date(timeIntervalSince1970: 100))
        insert(ctx, key: "old-short", group: group, date: date, venue: "\(venue), Carnegie Hall",
               ingestedAt: Date(timeIntervalSince1970: 200))

        NaturalKeyVenueMigration.run(in: ctx)

        let remaining = allProspects(ctx)
        #expect(remaining.count == 1)
        #expect(remaining.first?.naturalKey == folded,
                "the survivor must carry the folded key, or the next scout adds a third row")
    }

    @Test func aLoneAddressRowIsRekeyedNotDeleted() throws {
        let ctx = try context()
        let group = "Solo Recital", date = "2026-10-10"
        insert(ctx, key: "legacy-address-key", group: group, date: date,
               venue: "The Players Theatre, 115 MacDougal Street, New York, NY")

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        #expect(summary.rekeyed == 1)
        #expect(summary.duplicatesDeleted == 0)
        let all = allProspects(ctx)
        #expect(all.count == 1)
        #expect(all[0].naturalKey == foldedKey(group, date, "The Players Theatre"))
    }

    // #1590: the title fold has to reach the rows ALREADY stored, not only the next scout. This pass
    // recomputes every row's key at launch, so folding the title half means it now reconciles a
    // title-variant pair too, with no new migration and no second copy of the merge rules. These are the
    // live pairs, quoted from the 2026-07-27 measurement.
    @Test func aStoredTitleVariantPairCollapsesToOneRow() throws {
        let ctx = try context()
        let date = "2026-07-29", venue = "Jalopy Theatre"
        insert(ctx, key: "legacy-bang-key", group: "Jalopy Open Mic Every Wednesday!", date: date,
               venue: venue, ingestedAt: Date(timeIntervalSince1970: 1_000))
        insert(ctx, key: "legacy-bracket-key", group: "Jalopy Open Mic (Every Wednesday)", date: date,
               venue: "Jalopy Theatre, Red Hook, Brooklyn, NY",
               ingestedAt: Date(timeIntervalSince1970: 2_000))

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 1)
        let remaining = allProspects(ctx)
        #expect(remaining.count == 1, "one open mic, one card")
        #expect(remaining.first?.naturalKey ==
                foldedKey("Jalopy Open Mic Every Wednesday!", date, venue))
    }

    // The failure path, and the one that must never regress: when BOTH title variants carry real outreach
    // history, merging them would move a sent email onto the wrong show. The pass has to leave every row
    // exactly as it found it, delete nothing, and record the conflict rather than resolving it blind.
    @Test func twoTitleVariantsThatBothCarryHistoryAreLeftAloneAndCounted() throws {
        let ctx = try context()
        let date = "2026-07-31", venue = "54 Below"
        insert(ctx, key: "legacy-dots-key", group: "Christine Andreas: S'Wonderful...", date: date,
               venue: venue) { $0.draftBody = "a draft Dan has already seen" }
        insert(ctx, key: "legacy-ellipsis-key", group: "Christine Andreas: S'Wonderful\u{2026}",
               date: date, venue: venue) { $0.sentAt = Date(timeIntervalSince1970: 5_000) }

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        #expect(summary.conflictsDeferred == 1)
        #expect(summary.duplicatesDeleted == 0, "nothing carrying outreach history is ever dropped")
        let remaining = allProspects(ctx)
        #expect(remaining.count == 2)
        #expect(Set(remaining.map(\.naturalKey)) == ["legacy-dots-key", "legacy-ellipsis-key"],
                "both keep their old keys, so neither row moves under Dan while he is mid-conversation")
    }

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="the status and outreach history of every row in the two colliding title pairs the merge has been deferring"
    // #1780: two rows Dan merely REFUSED used to deadlock the merge forever. `hasOutreachHistory` answers
    // "has anything at all happened to this row", which is right for its other three callers and too broad
    // here: a bare dismissal counted, so any two dismissed duplicates went to the deferred branch, were
    // reported only to NSLog (invisible from a running Overture), and stayed duplicated permanently.
    //
    // Measured on the live store: "Bone Wars" on 2026-07-26 sits twice, BOTH dismissed "too soon", with
    // nothing sent, drafted or addressed on either. There is nothing to reconcile and nobody was ever told
    // there was. A dismissal is a decision, not an outreach record, so it no longer blocks the merge.
    @Test func twoDuplicatesDismissedForTheSameReasonMergeInsteadOfDeadlocking() throws {
        let ctx = try context()
        let group = "Bone Wars: A New Musical", date = "2026-07-26"
        let folded = foldedKey(group, date, "The Players Theatre")

        insert(ctx, key: "legacy-colon-key", group: group, date: date, venue: "The Players Theatre",
               ingestedAt: Date(timeIntervalSince1970: 1_000)) {
            $0.status = .dismissed; $0.showOutcomeRaw = "too_soon"
        }
        insert(ctx, key: "legacy-bracket-key", group: "Bone Wars (A New Musical)", date: date,
               venue: "The Players Theatre", ingestedAt: Date(timeIntervalSince1970: 2_000)) {
            $0.status = .dismissed; $0.showOutcomeRaw = "too_soon"
        }

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        #expect(summary.conflictsDeferred == 0)
        #expect(summary.duplicatesDeleted == 1)
        let rows = allProspects(ctx)
        #expect(rows.count == 1)
        #expect(rows.first?.naturalKey == folded)
        // Dan's refusal survives the merge. Losing it would put a show he has already refused back in
        // front of him, which is the opposite of the defect being fixed.
        #expect(rows.first?.status == .dismissed)
        #expect(rows.first?.showOutcomeRaw == "too_soon")
    }

    // And where the two refusals DISAGREE the merge still defers, because picking one silently rewrites
    // why Dan said no, which the outcome reporting reads. Measured live: "macMcCarty + KiddTwist" on
    // 2026-07-23 is dismissed once as "too soon" and once as "went by".
    @Test func twoDuplicatesDismissedForDifferentReasonsStillDefer() throws {
        let ctx = try context()
        let group = "macMcCarty +KiddTwist", date = "2026-07-23"

        insert(ctx, key: "legacy-tight-key", group: group, date: date, venue: "Jalopy Theatre",
               ingestedAt: Date(timeIntervalSince1970: 1_000)) {
            $0.status = .dismissed; $0.showOutcomeRaw = "too_soon"
        }
        insert(ctx, key: "legacy-spaced-key", group: "macMcCarty + KiddTwist", date: date,
               venue: "Jalopy Theatre", ingestedAt: Date(timeIntervalSince1970: 2_000)) {
            $0.status = .dismissed; $0.showOutcomeRaw = "went_by"
        }

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        #expect(summary.conflictsDeferred == 1)
        #expect(summary.duplicatesDeleted == 0)
        #expect(allProspects(ctx).count == 2)
    }

    // The guard that must not move, and the reason the relaxation above is narrow: once ANY row in the
    // collision was actually contacted, the old refusal stands whole and both rows stay. A dismissal on
    // the twin of a contacted show may be recording how that outreach ended, which is not a migration's
    // to throw away.
    @Test func aCollisionInvolvingAContactedRowStillDefers() throws {
        let ctx = try context()
        let group = "Contacted Show", date = "2026-08-02"

        insert(ctx, key: "legacy-a", group: group, date: date, venue: "The Cutting Room",
               ingestedAt: Date(timeIntervalSince1970: 1_000)) {
            $0.status = .dismissed; $0.showOutcomeRaw = "too_soon"
        }
        insert(ctx, key: "legacy-b", group: group, date: date,
               venue: "The Cutting Room, 44 East 32nd Street, New York, NY",
               ingestedAt: Date(timeIntervalSince1970: 2_000)) {
            $0.status = .contacted; $0.sentAt = Date(timeIntervalSince1970: 3_000)
        }

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        #expect(summary.conflictsDeferred == 1)
        #expect(summary.duplicatesDeleted == 0)
        let rows = allProspects(ctx)
        #expect(rows.count == 2)
        #expect(rows.contains { $0.sentAt != nil })
    }

    // #2001 REVERSES what #1780 pinned here, on Dan's call (2026-08-03): a show he refused, re-scouted
    // later under a variant spelling, DOES come back. His reason is that the refusal may have been made on
    // insufficient information, and a second copy arriving is his chance to reconsider, so the untouched
    // re-scout survives and the show returns to the queue. He chose a genuinely clean look, so the refusal
    // goes with the row it was on rather than being carried across.
    @Test func arefusedShowReturnsWhenAPristineRescoutMergesIntoIt() throws {
        let ctx = try context()
        let group = "Refused Show", date = "2026-08-09"

        insert(ctx, key: "legacy-refused", group: group, date: date, venue: "The Cutting Room",
               ingestedAt: Date(timeIntervalSince1970: 1_000)) {
            $0.status = .dismissed; $0.showOutcomeRaw = "too_soon"
        }
        // The later re-scout, untouched, under a spelling that folds to the same key.
        insert(ctx, key: "legacy-rescout", group: group, date: date,
               venue: "The Cutting Room, 44 East 32nd Street, New York, NY",
               ingestedAt: Date(timeIntervalSince1970: 2_000))

        NaturalKeyVenueMigration.run(in: ctx)
        let rows = allProspects(ctx)
        #expect(rows.count == 1)
        #expect(rows.first?.status == .new, "the show must come back for another look")
        #expect(rows.first?.showOutcomeRaw == nil)
    }
}
