import Testing
import Foundation

// #2495: the mirror of #2478. An export that is current, well formed and correctly versioned, whose CLIENT
// list has emptied. It passes every other check: the file reads, it is fresh, and #2478's own verdict
// requires a populated client list, so an empty roster switched that guard off too. Clients feed
// past-client recognition and booking matching, so a vanished roster lets Overture pitch organisations
// Dan already works with.
//
// What is pinned is the DISAPPEARANCE from a remembered roster, never the emptiness alone (L68), and a
// verdict of its own rather than a share of the booking check's (L53).
@Suite("A Downbeat export whose client list emptied (#2495)")
struct DownbeatRosterEmptiedTests {
    private let today = "2026-09-18"
    private var now: Date { EasternDate.date(from: today)!.addingTimeInterval(12 * 3600) }
    private let rememberedAt: Double = 1_789_000_000

    private func verdict(readable: Bool = true, clients: Int = 0,
                         remembered: Int = 31) -> DownbeatBookingFeed.RosterEmptied? {
        DownbeatBookingFeed.rosterEmptied(exportReadable: readable, clientCount: clients,
                                          lastRosterCount: remembered, lastRosterAt: rememberedAt)
    }

    @Test func aReadableExportWithNoClientsAfterARealRosterIsABrokenFeed() {
        #expect(verdict() == DownbeatBookingFeed.RosterEmptied(clientCount: 31, lastSeenAt: rememberedAt))
    }

    // A roster of one going to none is exactly what deleting one client looks like, so the floor is the
    // booking check's own: the smallest list whose total loss is a signature rather than a removal.
    @Test func aRosterBelowTheFloorGoingToNoneSaysNothing() {
        #expect(verdict(remembered: DownbeatBookingFeed.vanishedFloor - 1) == nil)
        #expect(verdict(remembered: DownbeatBookingFeed.vanishedFloor) != nil)
    }

    // Nothing remembered means nothing to compare against: a first ever export with no clients is not a
    // disappearance.
    @Test func noRememberedRosterSaysNothing() {
        #expect(verdict(remembered: 0) == nil)
    }

    // A file that is missing or unreadable also reaches here with no clients. That has its own line
    // (`downbeatAvailabilityUnknown`), and saying it again in other words would be one fault twice.
    @Test func anExportThatCouldNotBeReadIsLeftToItsOwnLine() {
        #expect(verdict(readable: false) == nil)
    }

    @Test func anExportCarryingClientsSaysNothing() {
        #expect(verdict(clients: 29) == nil)
    }

    // DECIDED, not left to be discovered: a client list has no dates to age out on, so this does NOT retire
    // itself with time, and the verdict takes no clock at all, which is what makes that structural rather
    // than a promise. It stands until an export lists clients again (the store test below clears it).

    // MARK: - The store, through the one recorder the reconcile tick and the notice's re-read share

    private func scratch() -> UserDefaults { ScratchDefaults.make("roster-feed") }

    @Test func theStoreCarriesTheBreakFromOneObservationToTheNextAndClearsOnARealRoster() {
        let defaults = scratch()
        DownbeatBookingFeedStore.record(clientCount: 31, health: .ok, bookings: [],
                                        today: today, now: now, into: defaults)
        #expect(DownbeatBookingFeedStore.rosterEmptied(defaults: defaults) == nil)

        DownbeatBookingFeedStore.record(clientCount: 0, health: .ok, bookings: [],
                                        today: today, now: now, into: defaults)
        #expect(DownbeatBookingFeedStore.rosterEmptied(defaults: defaults)
                == DownbeatBookingFeed.RosterEmptied(clientCount: 31, lastSeenAt: now.timeIntervalSince1970))

        DownbeatBookingFeedStore.record(clientCount: 30, health: .ok, bookings: [],
                                        today: today, now: now, into: defaults)
        #expect(DownbeatBookingFeedStore.rosterEmptied(defaults: defaults) == nil)
    }

    // The failure path of the read: a missing file records no clients and an unreadable export, says
    // nothing here, and does not destroy the remembered roster on the way past (L5), so the next good but
    // empty export is still convicted by it.
    @Test func aReadThatFoundNoExportKeepsTheRememberedRoster() {
        let defaults = scratch()
        DownbeatBookingFeedStore.record(clientCount: 31, health: .ok, bookings: [],
                                        today: today, now: now, into: defaults)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-such-downbeat-export-\(UUID().uuidString).json")
        DownbeatBookingFeedStore.observe(from: missing, now: now, into: defaults)
        #expect(defaults.bool(forKey: DownbeatBookingFeedStore.exportReadableKey) == false)
        #expect(defaults.integer(forKey: DownbeatBookingFeedStore.lastRosterCountKey) == 31)
        #expect(DownbeatBookingFeedStore.rosterEmptied(defaults: defaults) == nil)

        DownbeatBookingFeedStore.record(clientCount: 0, health: .ok, bookings: [],
                                        today: today, now: now, into: defaults)
        #expect(DownbeatBookingFeedStore.rosterEmptied(defaults: defaults)?.clientCount == 31)
    }

    // A stale export has still been READ: its roster is real, only old, so it counts as readable.
    @Test func aStaleExportIsStillReadable() {
        let defaults = scratch()
        DownbeatBookingFeedStore.record(clientCount: 31, health: .ok, bookings: [],
                                        today: today, now: now, into: defaults)
        DownbeatBookingFeedStore.record(clientCount: 0, health: .stale(ageDays: 40), bookings: [],
                                        today: today, now: now, into: defaults)
        #expect(DownbeatBookingFeedStore.rosterEmptied(defaults: defaults) != nil)
    }

    // End to end from a real file in the real wire format: a well formed export with an empty client list.
    @Test func aRealExportWithAnEmptyClientListIsConvicted() throws {
        let defaults = scratch()
        DownbeatBookingFeedStore.record(clientCount: 31, health: .ok, bookings: [],
                                        today: today, now: now, into: defaults)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downbeat-export-\(UUID().uuidString).json")
        try Data(#"{"version":2,"clients":[],"venues":[],"bookings":[],"blockedDates":[]}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        DownbeatBookingFeedStore.observe(from: url, now: now, into: defaults)
        #expect(defaults.bool(forKey: DownbeatBookingFeedStore.exportReadableKey))
        #expect(DownbeatBookingFeedStore.rosterEmptied(defaults: defaults)?.clientCount == 31)
    }

    // MARK: - The line Dan reads

    @Test func theMastheadSaysItAndOffersTheReRead() {
        let emptied = DownbeatBookingFeed.RosterEmptied(clientCount: 31, lastSeenAt: now.timeIntervalSince1970)
        let notices = AppNotices.current(clientsEmptied: emptied, status: StatusLine())
        let line = notices.first { $0.text.contains("no clients") }
        #expect(line != nil, "the emptied roster must reach the masthead: \(notices.map(\.text))")
        #expect(line?.text.contains("31") == true)
        #expect(line?.tone == .warning)
        #expect(line?.action == .recheckDownbeatExport)
        #expect(AppNotices.current(clientsEmptied: nil, status: StatusLine())
                    .allSatisfy { !$0.text.contains("no clients") })
    }
}
