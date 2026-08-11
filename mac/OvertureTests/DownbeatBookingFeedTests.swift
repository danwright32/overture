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

    private func booking(_ id: String, endDate: String) -> OvertureBooking {
        OvertureBooking(id: id, clientId: "c", clientDisplayName: "DCINY", shootName: "S",
                        startDate: endDate, endDate: endDate, venueId: nil, venueName: "Carnegie Hall")
    }

    // (a) The case that happened. Clients present, shoots gone, and the shoots Overture last saw are still
    // in the future, so nothing about the passage of time explains their absence.
    @Test func anExportListingClientsAndNoShootsAtAllReadsAsABrokenFeed() {
        let verdict = DownbeatBookingFeed.vanished(clientCount: 30, upcomingBookingCount: 0,
                                                   lastCarriedCount: 15, lastCarriedEndDate: "2027-06-13",
                                                   today: today)
        #expect(verdict == DownbeatBookingFeed.Vanished(bookingCount: 15, lastEndDate: "2027-06-13"))
    }

    // (b) The genuinely quiet diary, and the reason this check cannot expire. "Quiet" here is not "no
    // shoots today": it is that every shoot this feed ever carried has already HAPPENED. A wind-down looks
    // like this because shoots leave the export one at a time, as their dates pass, so by the time the last
    // one has gone there is nothing left whose absence needs explaining, and Overture says nothing from
    // then on however long the lull lasts.
    @Test func adiaryThatHasGenuinelyRunOutIsNotFlagged() {
        #expect(DownbeatBookingFeed.vanished(clientCount: 30, upcomingBookingCount: 0,
                                             lastCarriedCount: 15, lastCarriedEndDate: "2026-08-09",
                                             today: today) == nil)
    }

    // The boundary: a shoot ENDING today has not passed yet, matching the "today or later" notion the
    // blocked calendar and the freshness clock both use.
    @Test func ashootEndingTodayStillCountsAsUnexplainedAbsence() {
        #expect(DownbeatBookingFeed.vanished(clientCount: 30, upcomingBookingCount: 0,
                                             lastCarriedCount: 15, lastCarriedEndDate: today,
                                             today: today) != nil)
    }

    // (c) The healthy export: it carries shoots, so there is nothing to report.
    @Test func ahealthyExportCarryingShootsIsNotFlagged() {
        #expect(DownbeatBookingFeed.vanished(clientCount: 30, upcomingBookingCount: 15,
                                             lastCarriedCount: 15, lastCarriedEndDate: "2027-06-13",
                                             today: today) == nil)
    }

    // A missing or unreadable file reaches here as an export with no clients either, and that already has
    // its own message from DownbeatBridge.health. Two independent checks must not share one verdict (L53),
    // so this one declines rather than reporting the same fault in different words.
    @Test func anExportThatCouldNotBeReadIsLeftToItsOwnCheck() {
        #expect(DownbeatBookingFeed.vanished(clientCount: 0, upcomingBookingCount: 0,
                                             lastCarriedCount: 15, lastCarriedEndDate: "2027-06-13",
                                             today: today) == nil)
    }

    // A single shoot going is exactly what one cancellation looks like, and Overture cannot tell those two
    // apart from the outside, so it does not claim (L11). The signature is a LIST going at once.
    @Test func oneShootGoingIsNotClaimedAsABreak() {
        #expect(DownbeatBookingFeed.vanished(clientCount: 30, upcomingBookingCount: 0,
                                             lastCarriedCount: 1, lastCarriedEndDate: "2027-06-13",
                                             today: today) == nil)
    }

    // Never having seen this feed carry shoots is not evidence of anything: there is nothing that went
    // missing. The check stays silent until it has watched a healthy export at least once.
    @Test func afeedNeverSeenCarryingShootsIsNotABreak() {
        #expect(DownbeatBookingFeed.vanished(clientCount: 30, upcomingBookingCount: 0,
                                             lastCarriedCount: 0, lastCarriedEndDate: "",
                                             today: today) == nil)
    }

    // MARK: - The evidence

    // The evidence is only ever written from an export that HAD shoots. A broken export must not be able
    // to erase the record that convicts it (L5), which is what would happen if every observation
    // overwrote it.
    @Test func abrokenExportCannotEraseTheEvidenceAgainstIt() {
        let kept = DownbeatBookingFeed.carried(lastCarriedCount: 15, lastCarriedEndDate: "2027-06-13",
                                               bookings: [], today: today)
        #expect(kept.count == 15)
        #expect(kept.endDate == "2027-06-13")
    }

    // A healthy export replaces it with what it carries: the count, and the furthest night any of them run
    // to. The furthest one is what dates the evidence, so the check can retire itself once that has passed.
    @Test func ahealthyExportRecordsWhatItCarried() {
        let carried = DownbeatBookingFeed.carried(
            lastCarriedCount: 0, lastCarriedEndDate: "",
            bookings: [booking("a", endDate: "2026-08-14"), booking("b", endDate: "2027-06-13"),
                       booking("c", endDate: "2026-11-16")],
            today: today)
        #expect(carried.count == 3)
        #expect(carried.endDate == "2027-06-13")
    }

    // Only shoots that have not happened yet are evidence. A file left carrying nothing but last year's
    // work would otherwise keep the check armed forever on dates that cannot come back.
    @Test func onlyShootsStillToComeCountAsEvidence() {
        let carried = DownbeatBookingFeed.carried(lastCarriedCount: 0, lastCarriedEndDate: "",
                                                  bookings: [booking("old", endDate: "2026-07-01")],
                                                  today: today)
        #expect(carried.count == 0)
        #expect(carried.endDate == "")
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
                                        today: today, into: defaults)
        #expect(DownbeatBookingFeedStore.vanished(today: today, defaults: defaults) == nil)

        DownbeatBookingFeedStore.record(clientCount: 30, bookings: [], today: today, into: defaults)
        let verdict = DownbeatBookingFeedStore.vanished(today: today, defaults: defaults)
        #expect(verdict == DownbeatBookingFeed.Vanished(bookingCount: 2, lastEndDate: "2027-06-13"))
    }

    // And it retires itself: the same stored evidence, read on a day after the last of those shoots ran,
    // reports nothing. Nothing has to remember to clear it.
    @Test func thestoredBreakRetiresItselfOnceThoseNightsHavePassed() {
        let defaults = scratch()
        DownbeatBookingFeedStore.record(clientCount: 30,
                                        bookings: [booking("a", endDate: "2026-08-14"),
                                                   booking("b", endDate: "2026-08-15")],
                                        today: today, into: defaults)
        DownbeatBookingFeedStore.record(clientCount: 30, bookings: [], today: today, into: defaults)
        #expect(DownbeatBookingFeedStore.vanished(today: "2026-08-14", defaults: defaults) != nil)
        #expect(DownbeatBookingFeedStore.vanished(today: "2026-08-16", defaults: defaults) == nil)
    }

    // The failure path of the read itself: an export that is not there records a feed with no clients,
    // which this check leaves alone, and it does not destroy the evidence on the way past.
    @Test func areadThatFoundNoExportRecordsNoClientsAndKeepsTheEvidence() {
        let defaults = scratch()
        DownbeatBookingFeedStore.record(clientCount: 30,
                                        bookings: [booking("a", endDate: "2026-08-14"),
                                                   booking("b", endDate: "2027-06-13")],
                                        today: today, into: defaults)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-such-downbeat-export-\(UUID().uuidString).json")
        DownbeatBookingFeedStore.observe(from: missing, now: Date(), into: defaults)

        #expect(defaults.integer(forKey: DownbeatBookingFeedStore.clientCountKey) == 0)
        #expect(defaults.integer(forKey: DownbeatBookingFeedStore.lastCarriedCountKey) == 2)
        #expect(DownbeatBookingFeedStore.vanished(today: today, defaults: defaults) == nil)
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

        DownbeatBookingFeedStore.observe(from: url, now: EasternDate.date(from: today)!, into: defaults)
        #expect(defaults.integer(forKey: DownbeatBookingFeedStore.clientCountKey) == 1)
        #expect(defaults.integer(forKey: DownbeatBookingFeedStore.upcomingBookingCountKey) == 1)
        #expect(defaults.string(forKey: DownbeatBookingFeedStore.lastCarriedEndDateKey) == "2026-11-24")
    }
}

// What Dan is actually told, and where. The masthead's notice stack, because it is the surface he reads at
// his own window width (#2204) and the only one that can carry a control beside the sentence (#2250, L80).
@Suite("What Overture says about a Downbeat export that lost its shoots (#2478)")
struct DownbeatShootsVanishedNoticeTests {
    private let vanished = DownbeatBookingFeed.Vanished(bookingCount: 15, lastEndDate: "2027-06-13")

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

    // A message that names a fault carries the control for it (L80): here, reading the export again, so a
    // fixed export clears the line without Dan having to guess whether Overture has noticed.
    @Test func thenoticeCarriesTheRecheck() {
        #expect(AppNotices.downbeatShootsVanished(vanished).action == .recheckDownbeatExport)
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
        guard let body = SourceGuardHelper.propertyBody("into defaults: UserDefaults = .standard) {",
                                                        in: sched) else {
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
