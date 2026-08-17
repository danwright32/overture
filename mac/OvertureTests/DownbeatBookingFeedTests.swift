import Testing
import Foundation

// #2478: Downbeat refreshed its export on 2026-08-10 carrying 30 clients, 4 venues, and not one booking.
// Dan had fifteen shoots on the books. Overture read that file as a true picture of the world, because
// every signal it checked said healthy: current timestamp, supported version, populated client list. Three
// features then did nothing at all and said nothing about it (booking detection had nothing to match, the
// blocked calendar got no dates, and the planned booking prompt could never fire).
//
// What this suite pins is the SIGNATURE, not the emptiness (L68). "No bookings today" is a fact that will
// one day be legitimately true, and a check asserting it would then cry wolf forever; "every shoot this
// feed was carrying went at once, and none of them had happened yet" is a fact that can only be produced
// by the feed breaking, and it goes quiet on its own as those dates pass.
@Suite("A Downbeat export that lost its shoots (#2478)")
struct DownbeatBookingFeedTests {
    private let today = "2026-08-10"
    private var nowOnToday: Date { EasternDate.date(from: "2026-08-10")!.addingTimeInterval(12 * 3600) }

    private func booking(_ id: String, endDate: String) -> OvertureBooking {
        OvertureBooking(id: id, clientId: "c", clientDisplayName: "DCINY", shootName: "S",
                        startDate: endDate, endDate: endDate, venueId: nil, venueName: "Carnegie Hall")
    }

    private func verdict(clients: Int = 30, upcoming: Int = 0, count: Int, endDate: String,
                         at: Double = 0, on day: String? = nil,
                         now: Date? = nil) -> DownbeatBookingFeed.Vanished? {
        DownbeatBookingFeed.vanished(clientCount: clients, upcomingBookingCount: upcoming,
                                     lastCarriedCount: count, lastCarriedEndDate: endDate,
                                     lastCarriedAt: at, today: day ?? today, now: now ?? nowOnToday)
    }

    // (a) The case that happened. Clients present, shoots gone, and the shoots Overture last saw are still
    // in the future, so nothing about the passage of time explains their absence.
    @Test func anExportListingClientsAndNoShootsAtAllReadsAsABrokenFeed() {
        #expect(verdict(count: 15, endDate: "2027-06-13")
                == DownbeatBookingFeed.Vanished(bookingCount: 15,
                                                evidence: .theExportCarriedThemUntil("2027-06-13")))
    }

    // (b) The genuinely quiet diary, and the reason this check cannot expire. "Quiet" here is not "no
    // shoots today": it is that every shoot this feed ever carried has already HAPPENED. A wind-down looks
    // like this because shoots leave the export one at a time, as their dates pass, so by the time the last
    // one has gone there is nothing left whose absence needs explaining, and Overture says nothing from
    // then on however long the lull lasts.
    @Test func adiaryThatHasGenuinelyRunOutIsNotFlagged() {
        #expect(verdict(count: 15, endDate: "2026-08-09") == nil)
    }

    // The boundary: a shoot ENDING today has not passed yet, matching the "today or later" notion the
    // blocked calendar and the freshness clock both use.
    @Test func ashootEndingTodayStillCountsAsUnexplainedAbsence() {
        #expect(verdict(count: 15, endDate: today) != nil)
    }

    // (c) The healthy export: it carries shoots, so there is nothing to report.
    @Test func ahealthyExportCarryingShootsIsNotFlagged() {
        #expect(verdict(upcoming: 15, count: 15, endDate: "2027-06-13") == nil)
    }

    // A missing or unreadable file reaches here as an export with no clients either, and that already has
    // its own message from DownbeatBridge.health. Two independent checks must not share one verdict (L53),
    // so this one declines rather than reporting the same fault in different words.
    @Test func anExportThatCouldNotBeReadIsLeftToItsOwnCheck() {
        #expect(verdict(clients: 0, count: 15, endDate: "2027-06-13") == nil)
    }

    // A single shoot going is exactly what one cancellation looks like, and Overture cannot tell those two
    // apart from the outside, so it does not claim (L11). The signature is a LIST going at once.
    @Test func oneShootGoingIsNotClaimedAsABreak() {
        #expect(verdict(count: 1, endDate: "2027-06-13") == nil)
    }

    // Never having seen this feed carry shoots is not evidence of anything: there is nothing that went
    // missing. The check stays silent until it has watched a healthy export at least once.
    @Test func afeedNeverSeenCarryingShootsIsNotABreak() {
        #expect(verdict(count: 0, endDate: "") == nil)
    }

    // MARK: - The evidence

    // A broken export is worth nothing as evidence, so it must not be able to overwrite the record that
    // convicts it (L5): nil here means KEEP what is on file.
    @Test func abrokenExportCannotEraseTheEvidenceAgainstIt() {
        #expect(DownbeatBookingFeed.carried(bookings: [], today: today) == nil)
    }

    // A healthy export replaces it with what it carries: the count, and the furthest night any of them run
    // to. The furthest one is what dates the evidence, so the check can retire itself once that has passed.
    @Test func ahealthyExportRecordsWhatItCarried() throws {
        let carried = try #require(DownbeatBookingFeed.carried(
            bookings: [booking("a", endDate: "2026-08-14"), booking("b", endDate: "2027-06-13"),
                       booking("c", endDate: "2026-11-16")],
            today: today))
        #expect(carried.count == 3)
        #expect(carried.endDate == "2027-06-13")
    }

    // Only shoots that have not happened yet are evidence. A file left carrying nothing but last year's
    // work would otherwise keep the check armed forever on dates that cannot come back.
    @Test func onlyShootsStillToComeCountAsEvidence() {
        #expect(DownbeatBookingFeed.carried(bookings: [booking("old", endDate: "2026-07-01")],
                                            today: today) == nil)
    }

    // MARK: - The store

    private func scratch() -> UserDefaults { UserDefaults(suiteName: "booking-feed-\(UUID().uuidString)")! }

    // The whole sequence Dan lived through, through the persisted values the masthead actually reads: a
    // healthy export, then the same feed refreshed with its clients intact and its shoots gone.
    @Test func thestoreCarriesTheBreakFromOneObservationToTheNext() {
        let defaults = scratch()
        DownbeatBookingFeedStore.record(clientCount: 30,
                                        bookings: [booking("a", endDate: "2026-08-14"),
                                                   booking("b", endDate: "2027-06-13")],
                                        today: today, now: nowOnToday, into: defaults)
        #expect(DownbeatBookingFeedStore.vanished(today: today, now: nowOnToday, defaults: defaults) == nil)

        DownbeatBookingFeedStore.record(clientCount: 30, bookings: [], today: today, now: nowOnToday,
                                        into: defaults)
        #expect(DownbeatBookingFeedStore.vanished(today: today, now: nowOnToday, defaults: defaults)
                == DownbeatBookingFeed.Vanished(bookingCount: 2,
                                                evidence: .theExportCarriedThemUntil("2027-06-13")))
    }

    // And it retires itself: the same stored evidence, read on a day after the last of those shoots ran,
    // reports nothing. Nothing has to remember to clear it.
    @Test func thestoredBreakRetiresItselfOnceThoseNightsHavePassed() {
        let defaults = scratch()
        DownbeatBookingFeedStore.record(clientCount: 30,
                                        bookings: [booking("a", endDate: "2026-08-14"),
                                                   booking("b", endDate: "2026-08-15")],
                                        today: today, now: nowOnToday, into: defaults)
        DownbeatBookingFeedStore.record(clientCount: 30, bookings: [], today: today, now: nowOnToday,
                                        into: defaults)
        #expect(DownbeatBookingFeedStore.vanished(today: "2026-08-14", now: nowOnToday,
                                                  defaults: defaults) != nil)
        #expect(DownbeatBookingFeedStore.vanished(today: "2026-08-16", now: nowOnToday,
                                                  defaults: defaults) == nil)
    }

    // The failure path of the read itself: an export that is not there records a feed with no clients,
    // which this check leaves alone, and it does not destroy the evidence on the way past.
    @Test func areadThatFoundNoExportRecordsNoClientsAndKeepsTheEvidence() {
        let defaults = scratch()
        DownbeatBookingFeedStore.record(clientCount: 30,
                                        bookings: [booking("a", endDate: "2026-08-14"),
                                                   booking("b", endDate: "2027-06-13")],
                                        today: today, now: nowOnToday, into: defaults)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-such-downbeat-export-\(UUID().uuidString).json")
        DownbeatBookingFeedStore.observe(from: missing, now: nowOnToday, into: defaults)

        #expect(defaults.integer(forKey: DownbeatBookingFeedStore.clientCountKey) == 0)
        #expect(defaults.integer(forKey: DownbeatBookingFeedStore.lastCarriedCountKey) == 2)
        #expect(DownbeatBookingFeedStore.vanished(today: today, now: nowOnToday, defaults: defaults) == nil)
    }

    // The healthy read, end to end from a real file on disk in the real wire format, so the count the
    // message will state is measured through the same decode the app uses rather than assumed.
    @Test func areadOfARealExportRecordsWhatItCarries() throws {
        let defaults = scratch()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downbeat-export-\(UUID().uuidString).json")
        let json = """
        {"version":2,"clients":[{"id":"c1","displayName":"DCINY","email":"a@b.c",\
        "contractEmail":"a@b.c","hasLeftReview":false,"specialBehaviors":[],"hostingSite":"smugmug"}],\
        "venues":[],"bookings":[{"id":"b1","clientId":"c1","clientDisplayName":"DCINY",\
        "shootName":"Total Vocal","startDate":"2026-11-24","endDate":"2026-11-24",\
        "venueName":"Carnegie Hall"}],"blockedDates":["2026-11-24"]}
        """
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        DownbeatBookingFeedStore.observe(from: url, now: nowOnToday, into: defaults)
        #expect(defaults.integer(forKey: DownbeatBookingFeedStore.clientCountKey) == 1)
        #expect(defaults.integer(forKey: DownbeatBookingFeedStore.upcomingBookingCountKey) == 1)
        #expect(defaults.string(forKey: DownbeatBookingFeedStore.lastCarriedEndDateKey) == "2026-11-24")
    }
}

// Arming the check from what the app ALREADY remembers.
//
// The first cut of this shipped silent about the very breakage that prompted it. Its evidence keys were
// new, so they read empty until a good export had been consumed once, and on Dan's Mac the export has
// already stopped carrying bookings: the check would have stayed quiet until the fault fixed itself,
// which is exactly when nobody needs it. Dan's call: use the seen-ids set Overture has been keeping since
// #1456 (17 booking ids on his live release domain, plus the timestamp of the last new one).
//
// That evidence is WEAKER, and the point of these tests is that it is never allowed to make the stronger
// claim. The ids carry no dates, so nothing about them can say which of those shoots have already
// happened, and the dated rule's self-retiring guard cannot be evaluated against them. What they do
// support is bounded in TIME instead: a new upcoming shoot arrived at a recorded instant, so as of that
// instant this feed was carrying at least one shoot that had not happened yet. That is worth leaning on
// for the same four weeks the stalled-feed nudge already uses, and then it stops.
@Suite("Arming the check from what Overture already remembers (#2478)")
struct DownbeatBookingFeedBootstrapTests {
    private let today = "2026-08-10"
    private var nowOnToday: Date { EasternDate.date(from: "2026-08-10")!.addingTimeInterval(12 * 3600) }
    private func scratch() -> UserDefaults { UserDefaults(suiteName: "feed-bootstrap-\(UUID().uuidString)")! }

    private func booking(_ id: String, endDate: String) -> OvertureBooking {
        OvertureBooking(id: id, clientId: "c", clientDisplayName: "DCINY", shootName: "S",
                        startDate: endDate, endDate: endDate, venueId: nil, venueName: "Carnegie Hall")
    }

    // Seeded through the REAL writer of those keys, so this cannot pass against a shape #1456 does not
    // actually store (L52).
    private func seedLegacy(_ ids: [String], lastNewAt: Date, into defaults: UserDefaults) {
        DownbeatFeedFreshnessStore.save(
            DownbeatFeedFreshness.State(seenBookingIds: ids,
                                        lastNewUpcomingBookingAt: lastNewAt.timeIntervalSince1970),
            into: defaults)
    }

    private func ids(_ n: Int) -> [String] { (0..<n).map { "booking-\($0)" } }

    // THE case: a Mac carrying nothing but the legacy seen-ids set, whose export now carries no shoots.
    // This is Dan's machine on 2026-08-10, and the first cut of this check said nothing here.
    @Test func thelegacySeenIdsAreTheOnlyEvidenceAndTheWarningStillFires() throws {
        let defaults = scratch()
        seedLegacy(ids(17), lastNewAt: nowOnToday.addingTimeInterval(-3600), into: defaults)

        DownbeatBookingFeedStore.record(clientCount: 30, bookings: [], today: today, now: nowOnToday,
                                        into: defaults)

        let verdict = try #require(DownbeatBookingFeedStore.vanished(today: today, now: nowOnToday,
                                                                     defaults: defaults))
        #expect(verdict.bookingCount == 17)
        #expect(verdict.evidence == .seenBeforeTheirDatesWereKept(
            lastNewAt: nowOnToday.addingTimeInterval(-3600).timeIntervalSince1970))
    }

    // It is a MIGRATION, not a second source of truth (L83). The moment the export itself carries shoots,
    // that dated record replaces the migrated one wholesale, and the count Dan reads is the real one.
    @Test func adatedExportSupersedesTheMigratedEvidence() throws {
        let defaults = scratch()
        seedLegacy(ids(17), lastNewAt: nowOnToday.addingTimeInterval(-3600), into: defaults)
        DownbeatBookingFeedStore.record(clientCount: 30, bookings: [], today: today, now: nowOnToday,
                                        into: defaults)

        DownbeatBookingFeedStore.record(clientCount: 30,
                                        bookings: [booking("a", endDate: "2026-08-14"),
                                                   booking("b", endDate: "2027-06-13")],
                                        today: today, now: nowOnToday, into: defaults)
        DownbeatBookingFeedStore.record(clientCount: 30, bookings: [], today: today, now: nowOnToday,
                                        into: defaults)

        let verdict = try #require(DownbeatBookingFeedStore.vanished(today: today, now: nowOnToday,
                                                                     defaults: defaults))
        #expect(verdict == DownbeatBookingFeed.Vanished(
            bookingCount: 2, evidence: .theExportCarriedThemUntil("2027-06-13")))
    }

    // And it never runs the other way round. Real history on file means the migration has nothing to do,
    // so a long-lived seen-ids set can never overwrite what an export actually said.
    @Test func themigrationNeverOverwritesHistoryTheExportWrote() {
        let defaults = scratch()
        DownbeatBookingFeedStore.record(clientCount: 30,
                                        bookings: [booking("a", endDate: "2026-08-14"),
                                                   booking("b", endDate: "2027-06-13")],
                                        today: today, now: nowOnToday, into: defaults)
        seedLegacy(ids(17), lastNewAt: nowOnToday, into: defaults)

        DownbeatBookingFeedStore.bootstrapFromSeenIds(into: defaults)
        #expect(defaults.integer(forKey: DownbeatBookingFeedStore.lastCarriedCountKey) == 2)
        #expect(defaults.string(forKey: DownbeatBookingFeedStore.lastCarriedEndDateKey) == "2027-06-13")
    }

    // The self-retiring property, kept in the only currency this evidence has. Dateless ids cannot say
    // which shoots have passed, so instead of nagging forever the migrated record is leaned on for four
    // weeks after the last new shoot arrived (the window the stalled-feed nudge already uses) and then
    // stops on its own. After that, only an export can arm this check again.
    @Test func theundatedEvidenceRetiresItselfFourWeeksAfterTheLastNewShoot() {
        let defaults = scratch()
        let lastNew = nowOnToday
        seedLegacy(ids(17), lastNewAt: lastNew, into: defaults)
        DownbeatBookingFeedStore.record(clientCount: 30, bookings: [], today: today, now: nowOnToday,
                                        into: defaults)

        let justInside = lastNew.addingTimeInterval(27 * 86_400)
        let pastIt = lastNew.addingTimeInterval(29 * 86_400)
        #expect(DownbeatBookingFeedStore.vanished(today: "2026-09-06", now: justInside,
                                                  defaults: defaults) != nil)
        #expect(DownbeatBookingFeedStore.vanished(today: "2026-09-08", now: pastIt,
                                                  defaults: defaults) == nil)
    }

    // Ids with no timestamp date nothing at all, so there is no window to bound the claim with and the
    // migration declines. A guard that cannot expire is exactly what this must not become.
    @Test func legacyIdsWithNoTimestampAreNotEnough() {
        let defaults = scratch()
        DownbeatFeedFreshnessStore.save(
            DownbeatFeedFreshness.State(seenBookingIds: ids(17), lastNewUpcomingBookingAt: 0),
            into: defaults)
        DownbeatBookingFeedStore.record(clientCount: 30, bookings: [], today: today, now: nowOnToday,
                                        into: defaults)
        #expect(defaults.integer(forKey: DownbeatBookingFeedStore.lastCarriedCountKey) == 0)
        #expect(DownbeatBookingFeedStore.vanished(today: today, now: nowOnToday, defaults: defaults) == nil)
    }

    // One id is below the floor for the same reason one shoot is: it cannot be told apart from a single
    // cancellation. Nothing is migrated, rather than migrating something the verdict would then refuse.
    @Test func asingleLegacyIdIsBelowTheFloorAndIsNotMigrated() {
        let defaults = scratch()
        seedLegacy(ids(1), lastNewAt: nowOnToday, into: defaults)
        DownbeatBookingFeedStore.record(clientCount: 30, bookings: [], today: today, now: nowOnToday,
                                        into: defaults)
        #expect(defaults.integer(forKey: DownbeatBookingFeedStore.lastCarriedCountKey) == 0)
        #expect(DownbeatBookingFeedStore.vanished(today: today, now: nowOnToday, defaults: defaults) == nil)
    }

    // Whatever is at that key is somebody else's data if it is not a list of ids. Read defensively and
    // treat it as absent rather than crashing or inventing a count.
    @Test func alegacyValueThatIsNotAListOfIdsIsIgnored() {
        let defaults = scratch()
        defaults.set("not-an-array", forKey: DownbeatFeedFreshnessStore.seenIdsKey)
        defaults.set(nowOnToday.timeIntervalSince1970, forKey: DownbeatFeedFreshnessStore.lastNewAtKey)
        DownbeatBookingFeedStore.record(clientCount: 30, bookings: [], today: today, now: nowOnToday,
                                        into: defaults)
        #expect(defaults.integer(forKey: DownbeatBookingFeedStore.lastCarriedCountKey) == 0)
        #expect(DownbeatBookingFeedStore.vanished(today: today, now: nowOnToday, defaults: defaults) == nil)
    }

    // A Mac with no history of any kind says nothing, which is the one honest answer available: nothing
    // has been observed to go missing.
    @Test func nolegacyEvidenceAtAllLeavesTheCheckSilent() {
        let defaults = scratch()
        DownbeatBookingFeedStore.record(clientCount: 30, bookings: [], today: today, now: nowOnToday,
                                        into: defaults)
        #expect(DownbeatBookingFeedStore.vanished(today: today, now: nowOnToday, defaults: defaults) == nil)
    }

    // The migration has to sit on the path every observation takes, or the Mac it exists for never runs
    // it. Guarded at the source because the alternative (a launch hook) is exactly the thing that can be
    // absent without anything noticing (L3).
    @Test func everyObservationRunsTheMigrationBeforeItJudges() {
        let source = SourceGuardHelper.source("Overture/Domain/DownbeatBookingFeed.swift")
        // Scoped between the two declarations rather than by a brace marker: `bootstrapFromSeenIds` and
        // `record` share the same trailing parameter line, so a brace marker matched the migration's own
        // body and the guard would have been asserting that the migration calls itself (L70).
        guard let body = SourceGuardHelper.between("static func record(clientCount:",
                                                   and: "static func observe(", in: source) else {
            Issue.record("record(...) not found"); return
        }
        #expect(body.contains("bootstrapFromSeenIds(into: defaults)"),
                "record must migrate the legacy evidence before anything reads a verdict from these keys")
    }
}

// What Dan is actually told, and where. The masthead's notice stack, because it is the surface he reads at
// his own window width (#2204) and the only one that can carry a control beside the sentence (#2250, L80).
@Suite("What Overture says about a Downbeat export that lost its shoots (#2478)")
struct DownbeatShootsVanishedNoticeTests {
    private let vanished = DownbeatBookingFeed.Vanished(
        bookingCount: 15, evidence: .theExportCarriedThemUntil("2027-06-13"))
    private let remembered = DownbeatBookingFeed.Vanished(
        bookingCount: 17,
        evidence: .seenBeforeTheirDatesWereKept(
            lastNewAt: EasternDate.date(from: "2026-08-10")!.timeIntervalSince1970))

    // It states the evidence it measured (how many went), not just that something is wrong, so Dan can
    // tell in one read whether this is his diary or his export.
    @Test func thenoticeNamesHowManyShootsWent() {
        let notice = AppNotices.downbeatShootsVanished(vanished)
        #expect(notice.text.contains("15"))
        #expect(notice.tone == .warning)
    }

    // The tooltip carries the part that EXPLAINS: why all of them going at once is read as a broken
    // export, dated by the furthest night, and what Dan does about it.
    @Test func thetooltipDatesTheEvidenceAndNamesTheRemedy() throws {
        let help = try #require(AppNotices.downbeatShootsVanished(vanished).help)
        #expect(help.contains("Jun 13, 2027"))
        #expect(help.contains("Downbeat"))
    }

    // A message may claim only what its check measured (L11). The remembered ids were seen one at a time
    // over months, so this wording must never say they were being carried together, and must never date
    // them, because nothing in that evidence knows when they were.
    @Test func theremembereedWarningDoesNotClaimTheyWereCarriedTogether() {
        let notice = AppNotices.downbeatShootsVanished(remembered)
        #expect(notice.text.contains("17"))
        #expect(notice.tone == .warning)
        #expect(!notice.text.contains("at once"))
        #expect(!notice.text.contains("Every one"))
    }

    // Its tooltip says plainly what is not known, and dates the one thing that is: when a new shoot last
    // came through this feed.
    @Test func theremembereedTooltipAdmitsTheDatesAreNotKnown() throws {
        let help = try #require(AppNotices.downbeatShootsVanished(remembered).help)
        #expect(help.contains("Aug 10, 2026"))
        #expect(help.lowercased().contains("dates"))
        #expect(help.contains("Downbeat"))
    }

    // Both wordings end on the same stake, from one string, so the two can never drift into saying
    // different things about what Dan loses while this is true (#843).
    @Test func bothWordingsShareOneStatementOfWhatIsAtStake() {
        #expect(AppNotices.downbeatShootsVanished(vanished).text
            .hasSuffix(AppNotices.downbeatShootsVanishedStake))
        #expect(AppNotices.downbeatShootsVanished(remembered).text
            .hasSuffix(AppNotices.downbeatShootsVanishedStake))
    }

    // A message that names a fault carries the control for it (L80): here, reading the export again, so a
    // fixed export clears the line without Dan having to guess whether Overture has noticed.
    @Test func thenoticeCarriesTheRecheck() {
        #expect(AppNotices.downbeatShootsVanished(vanished).action == .recheckDownbeatExport)
        #expect(AppNotices.downbeatShootsVanished(remembered).action == .recheckDownbeatExport)
        // Not "Check again": that is already the paid per-card reachability control, and two controls
        // reading the same while doing different things is the #843 defect in its worst form.
        #expect(AppNoticeAction.recheckDownbeatExport.title == "Re-read the export")
        #expect(AppNoticeAction.recheckDownbeatExport.title != ReachabilityCopy.checkAgain)
    }

    // It reaches the stack Dan reads, ahead of the other standing fault: everything else on the screen is
    // derived from the picture of the world this line says is wrong.
    @Test func itisTheFirstThingTheMastheadSays() {
        let notices = AppNotices.current(omniFocusFailing: true, bookingsVanished: vanished,
                                         status: StatusLine())
        #expect(notices.first?.text.contains("15") == true)
        #expect(notices.first?.action == .recheckDownbeatExport)
        #expect(notices.count == 2)
    }

    // And a healthy feed adds no line at all.
    @Test func ahealthyFeedSaysNothing() {
        #expect(AppNotices.current(omniFocusFailing: false, bookingsVanished: nil,
                                   status: StatusLine()).isEmpty)
    }
}

// The wiring the pure logic cannot see (L3): unless the tick records the feed and the masthead reads the
// verdict, all of the above is a decision nobody makes. Guarded at the source, like #1456's own wiring
// test, because both sites need a live SwiftData context and Dan's real export to run.
@Suite("The reconcile tick and the masthead are wired to the booking feed check (#2478)")
struct DownbeatBookingFeedWiringGuardTests {
    @Test func thereconcileTickRecordsWhatTheExportCarried() {
        let sched = SourceGuardHelper.source("Overture/App/ReconcileScheduler.swift")
        // Scoped to that function's own balanced-brace body, not the file, so a mention of the store
        // anywhere else in a 300-line scheduler cannot stand in for the tick actually doing it (L63).
        guard let body = SourceGuardHelper.bodyOfFunction(named: "observeFeedFreshness", in: sched) else {
            Issue.record("observeFeedFreshness not found"); return
        }
        #expect(body.contains("DownbeatBookingFeedStore.record("),
                "the tick must record what the export carried, or nothing ever notices it stop carrying")
    }

    @Test func themastheadReadsTheVerdictAndCanRunItsRecheck() {
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(root.contains("DownbeatBookingFeed.vanished("),
                "the masthead must derive the verdict from the recorded feed facts")
        #expect(root.contains("case .recheckDownbeatExport"),
                "RootView must perform the recheck the notice offers")
    }
}
