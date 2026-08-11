import Testing
import Foundation
import SwiftData

// #802: the Sources sheet becomes the one place the watchlist is managed.
//
// Before this, a calendar could only join the watchlist by pasting a lead, and if Dan unticked "keep
// watching" he could never change his mind: re-pasting the same link is refused as already handed over,
// and the sheet was read-only. A dead end with no way out.
@MainActor
@Suite("Editing the watchlist (#802)")
struct WatchlistEditingTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func sources(_ ctx: ModelContext) throws -> [WatchedSource] {
        try ctx.fetch(FetchDescriptor<WatchedSource>())
    }

    // MARK: - Adding

    @Test func aCalendarCanBeAddedByHand() throws {
        let ctx = try context()

        let added = WatchlistEditing.add(orgName: "Bargemusic",
                                         listingsURL: "https://bargemusic.org/events", into: ctx)

        #expect(added == .added)
        let s = try #require(try sources(ctx).first)
        #expect(s.orgName == "Bargemusic")
        #expect(s.kind == .html)
        #expect(s.isActive)
        #expect(s.health == .neverChecked)   // no scout has reached it yet, and it says so
    }

    @Test func nonsenseIsRefusedRatherThanAddedAsABrokenRow() throws {
        let ctx = try context()

        #expect(WatchlistEditing.add(orgName: "X", listingsURL: "not a url", into: ctx) == .invalidURL)
        #expect(WatchlistEditing.add(orgName: "", listingsURL: "https://x.example/e", into: ctx) == .needsName)
        #expect(try sources(ctx).isEmpty)
    }

    // Matched on host, so an org that publishes /events and /calendar cannot end up watched twice,
    // fetching, hashing and reading the same calendar twice every run.
    @Test func theSameOrganizationCannotBeWatchedTwice() throws {
        let ctx = try context()
        _ = WatchlistEditing.add(orgName: "Bargemusic", listingsURL: "https://bargemusic.org/events",
                                 into: ctx)

        let again = WatchlistEditing.add(orgName: "Bargemusic Again",
                                         listingsURL: "https://www.bargemusic.org/calendar", into: ctx)

        #expect(again == .alreadyWatching(orgName: "Bargemusic"))
        #expect(try sources(ctx).count == 1)
    }

    // THE one that matters. An org that asked Dan to stop cannot be typed back onto the list by hand
    // any more than it can be pasted back in as a lead. The guarantee lives here, not in a sheet.
    @Test func anOrgThatRefusedCannotBeAddedByHandEither() throws {
        let ctx = try context()
        let refused = WatchedSource(sourceId: "bargemusic", orgName: "Bargemusic",
                                    listingsURL: "https://bargemusic.org/calendar", kind: .html)
        refused.isActive = false
        refused.inactiveReason = .orgRefusal
        ctx.insert(refused)

        let result = WatchlistEditing.add(orgName: "Bargemusic",
                                          listingsURL: "https://bargemusic.org/events", into: ctx)

        #expect(result == .refused(orgName: "Bargemusic"))
        #expect(try sources(ctx).count == 1)
        #expect(try sources(ctx).first?.isActive == false)   // still left alone
    }

    // A source Dan removed as dead is not a refusal, and he may decide it is worth another try. Adding
    // it again REVIVES the existing row rather than creating a second one, so its history is kept.
    //
    // #1673 narrowed what this test may claim, and the change is deliberate rather than a weakening. It
    // used to type a DIFFERENT address (/events onto a row watching /calendar) while asserting the feed
    // history survived. That combination is the silent-cancellation hole #887/#897 closed: a baseline
    // measured on one page, standing over a different one, lets a same-sized replacement strike Dan's live
    // shows. The revive is now judged at the SAME address here, which is what "keeps the history it earned"
    // was actually about, and the different-address case has its own test below, where the history goes.
    @Test func aSourceDanRemovedCanBeGivenAnotherTry() throws {
        let ctx = try context()
        let dead = WatchedSource(sourceId: "bargemusic", orgName: "Bargemusic",
                                 listingsURL: "https://bargemusic.org/events", kind: .html)
        dead.isActive = false
        dead.inactiveReason = .removedByDan
        dead.baselineFeedCount = 12
        ctx.insert(dead)

        let result = WatchlistEditing.add(orgName: "Bargemusic",
                                          listingsURL: "https://bargemusic.org/events", into: ctx)

        #expect(result == .resumed)
        #expect(try sources(ctx).count == 1)       // revived, not duplicated
        #expect(dead.isActive)
        #expect(dead.inactiveReason == nil)
        #expect(dead.baselineFeedCount == 12)      // and it keeps the feed history it earned
    }

    // MARK: - Stopping

    // Dan stopping a dead source is NOT the org refusing him, and the two must never be conflated: one
    // is a decision he can revisit, the other is a line he must not cross.
    @Test func stoppingASourceRecordsThatItWasDansChoiceNotARefusal() throws {
        let ctx = try context()
        _ = WatchlistEditing.add(orgName: "Bargemusic", listingsURL: "https://bargemusic.org/events",
                                 into: ctx)
        let s = try #require(try sources(ctx).first)

        WatchlistEditing.stopWatching(s, in: ctx)

        #expect(s.isActive == false)
        #expect(s.inactiveReason == .removedByDan)
        #expect(s.inactiveReason != .orgRefusal)
    }

    // The row is kept, never deleted. Deleting it would take its feed history with it, and a source id
    // is stamped on every prospect it ever surfaced.
    @Test func stoppingASourceKeepsTheRowRatherThanDeletingIt() throws {
        let ctx = try context()
        _ = WatchlistEditing.add(orgName: "Bargemusic", listingsURL: "https://bargemusic.org/events",
                                 into: ctx)
        let s = try #require(try sources(ctx).first)

        WatchlistEditing.stopWatching(s, in: ctx)

        #expect(try sources(ctx).count == 1)
    }

    // MARK: - Resuming (#845)

    // #845. Stopping a source is fully reversible and the UI never said so, so a single click with no
    // confirmation and no undo read as permanent. That matters more than it sounds: #802 rests on a
    // failing source NEVER auto-deactivating, precisely so that removing one stays Dan's deliberate
    // choice, and a button that feels destructive makes him hesitate over the one action the design
    // expects him to take.
    //
    // Reversing it by hand was possible but graceless: retype the org name and the URL into the add form,
    // which happens to match the row by host and revive it. `resumeWatching` is that same revival, by
    // identity, so an Undo and a "Watch again" button can both offer it in place.
    @Test func aSourceDanStoppedCanBeResumedInPlace() throws {
        let ctx = try context()
        _ = WatchlistEditing.add(orgName: "Bargemusic", listingsURL: "https://bargemusic.org/events",
                                 into: ctx)
        let s = try #require(try sources(ctx).first)
        s.baselineFeedCount = 12
        WatchlistEditing.stopWatching(s, in: ctx)

        let result = WatchlistEditing.resumeWatching(s, in: ctx)

        #expect(result == .resumed)
        #expect(s.isActive)
        #expect(s.inactiveReason == nil)
        #expect(s.baselineFeedCount == 12)      // the same row, with the history it earned
        #expect(try sources(ctx).count == 1)
    }

    // THE LINE THAT MUST NOT BE CROSSED, and the reason this rule lives here rather than in the view that
    // draws the button.
    //
    // An org that asked Dan to stop must not be able to get back onto the watchlist BY ANY ROUTE. #845
    // adds two new routes (an Undo in the banner, a "Watch again" button on the row), and the Sources
    // sheet only offers them on a source Dan removed himself. But a guarantee that lives in a view is a
    // guarantee that lasts until the next view, and this is the one mistake in the whole feature that
    // cannot be taken back: it ends with someone being emailed who asked not to be.
    @Test func anOrgThatAskedDanToStopCanNeverBeResumed() throws {
        let ctx = try context()
        let refused = WatchedSource(sourceId: "quiet", orgName: "Quiet Ensemble",
                                    listingsURL: "https://quiet.example/events", kind: .html)
        refused.isActive = false
        refused.inactiveReason = .orgRefusal
        ctx.insert(refused)

        let result = WatchlistEditing.resumeWatching(refused, in: ctx)

        #expect(result == .refused(orgName: "Quiet Ensemble"))
        #expect(refused.isActive == false)                    // still off, and still off for THEIR reason
        #expect(refused.inactiveReason == .orgRefusal)
    }

    // Resuming a source that is already being watched is a no-op, not a second helping. Belt and braces:
    // the button is only drawn on a stopped row, but the rule is not the view's to keep.
    @Test func resumingASourceAlreadyBeingWatchedChangesNothing() throws {
        let ctx = try context()
        _ = WatchlistEditing.add(orgName: "Bargemusic", listingsURL: "https://bargemusic.org/events",
                                 into: ctx)
        let s = try #require(try sources(ctx).first)

        #expect(WatchlistEditing.resumeWatching(s, in: ctx) == .alreadyWatching(orgName: "Bargemusic"))
        #expect(s.isActive)
    }

    // MARK: - What a resumed source may still claim (#1673)

    // #1673. Resuming set `isActive` and cleared `inactiveReason`, and nothing else, so the row kept the
    // verdict it was carrying when Dan stopped it. Nothing fetched that page for the whole time it sat
    // stopped, so a source revived after a season landed straight back in the Failing section quoting a
    // months old conclusion, and the row's instruction ("New listings, not read yet. Run a scout to read
    // them.") was a claim about listings nobody had looked at since.
    //
    // Measured on the live store: the only stopped row, New York Neo-Futurists, carried health `failing`,
    // `verdict_unreadable` and `hasUnreadChanges = 1`. One press of Watch again presented all three as
    // this source's current state.
    //
    // Three present tense claims, so all three go. #1549 makes this worse rather than less real: it HIDES
    // the unread line while a source is stopped, so a stale flag is invisible for as long as the source
    // sits removed and then reappears as a live instruction the moment it is restored.
    @Test func aResumedSourceCarriesNoVerdictFromBeforeTheStop() throws {
        let ctx = try context()
        _ = WatchlistEditing.add(orgName: "New York Neo-Futurists",
                                 listingsURL: "https://nynf.example/events", into: ctx)
        let s = try #require(try sources(ctx).first)
        s.health = .failing
        s.lastFailure = .verdict(.unreadable)
        s.hasUnreadChanges = true
        WatchlistEditing.stopWatching(s, in: ctx)

        #expect(WatchlistEditing.resumeWatching(s, in: ctx) == .resumed)

        #expect(s.health == .neverChecked)
        #expect(s.lastFailure == nil)
        #expect(!s.hasUnreadChanges)
        #expect(SourceGrade(s) == .neverChecked)          // "Not checked yet", until a scout reaches it
        #expect(!SourceAttention.needsALook(s))           // and not work Dan owes anyone before then
    }

    // The OTHER route to watching a source again, and the reason this is not a fix to one function. Dan can
    // retype the org name and the URL into the add form, which matches the row by calendar identity and
    // revives it (that route predates the button, and is still what the add form does today). It reached
    // the same stale row by a different door, so it needed the same reset.
    @Test func watchingAStoppedOrgAgainFromTheAddFormClearsTheSameVerdict() throws {
        let ctx = try context()
        _ = WatchlistEditing.add(orgName: "New York Neo-Futurists",
                                 listingsURL: "https://nynf.example/events", into: ctx)
        let s = try #require(try sources(ctx).first)
        s.health = .failing
        s.lastFailure = .verdict(.unreadable)
        s.hasUnreadChanges = true
        WatchlistEditing.stopWatching(s, in: ctx)

        let result = WatchlistEditing.add(orgName: "New York Neo-Futurists",
                                          listingsURL: "https://nynf.example/events", into: ctx)

        #expect(result == .resumed)
        #expect(try sources(ctx).count == 1)
        #expect(s.isActive)
        #expect(s.health == .neverChecked)
        #expect(s.lastFailure == nil)
        #expect(!s.hasUnreadChanges)
    }

    // The add form also lets Dan type a DIFFERENT address on the same calendar, and that path has always
    // written the new URL onto the row. That makes it a correction as well as a resume, so it owes
    // everything `editURL` owes: a corrected URL is a brand new source for reconcile (#1027), and keeping
    // the old page's baseline under a new address is the silent cancellation hole #887/#897 closed.
    @Test func retypingADifferentAddressForAStoppedOrgResetsWhatTheOldPageTaught() throws {
        let ctx = try context()
        _ = WatchlistEditing.add(orgName: "New York Neo-Futurists",
                                 listingsURL: "https://nynf.example/events", into: ctx)
        let s = try #require(try sources(ctx).first)
        s.baselineFeedCount = 30
        s.successfulCheckCount = 9
        s.lastSucceededAt = Date(timeIntervalSince1970: 1_785_000_000)
        s.notes = "A paragraph about the HTML at /events."
        WatchlistEditing.stopWatching(s, in: ctx)

        let result = WatchlistEditing.add(orgName: "New York Neo-Futurists",
                                          listingsURL: "https://nynf.example/calendar", into: ctx)

        #expect(result == .resumed)
        #expect(try sources(ctx).count == 1)
        #expect(s.listingsURL == "https://nynf.example/calendar")
        #expect(s.baselineFeedCount == 0)
        #expect(s.successfulCheckCount == 0)
        #expect(s.lastSucceededAt == nil)
        #expect(s.notes == nil)
    }

    // The decision #1673 asks for, pinned so it cannot be quietly reversed into `editURL`'s behaviour.
    //
    // A pause is NOT a repointing. The address is unchanged, so the baseline is still a measurement of this
    // very calendar, and wiping it would make the source LESS able to notice a listing has gone, not more:
    // `successfulCheckCount` back at zero puts the source in warmup, where `absenceIsEvidence` is false for
    // `warmupRuns` successful reads, and a source that sat out a season is exactly the one whose stored
    // shows are most likely to have really gone. Clearing `lastSucceededAt` alongside it would also make
    // `SourceAttention.hasNeverRead` true on an established row, which is a fresh false alarm of the same
    // kind this issue removes.
    //
    // The stale size risk is already handled without a wipe: a grown feed re-baselines at once, and a feed
    // that came back smaller is not a credible baseline, so it cannot be evidence of absence at all until
    // the smaller size holds for `selfHealThreshold` reads.
    @Test func aResumedSourceKeepsTheFeedHistoryItEarned() throws {
        let ctx = try context()
        _ = WatchlistEditing.add(orgName: "Bargemusic", listingsURL: "https://bargemusic.org/events",
                                 into: ctx)
        let s = try #require(try sources(ctx).first)
        let lastRead = Date(timeIntervalSince1970: 1_785_000_000)
        s.baselineFeedCount = 30
        s.successfulCheckCount = 9
        s.degradedStreak = 2
        s.lastDegradedCount = 18
        s.lastSucceededAt = lastRead
        s.emptyStreak = 4
        WatchlistEditing.stopWatching(s, in: ctx)

        #expect(WatchlistEditing.resumeWatching(s, in: ctx) == .resumed)

        #expect(s.baselineFeedCount == 30)
        #expect(s.successfulCheckCount == 9)
        #expect(s.degradedStreak == 2)
        #expect(s.lastDegradedCount == 18)
        #expect(s.lastSucceededAt == lastRead)
        #expect(s.emptyStreak == 4)
        #expect(!SourceAttention.hasNeverRead(s, now: Date()))
    }
}
