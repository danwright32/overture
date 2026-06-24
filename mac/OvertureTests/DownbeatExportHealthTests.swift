import Testing
import Foundation
@testable import Overture

// #22/#23: the scout must not silently treat everyone as a cold lead when the Downbeat
// client export is missing, unreadable, or stale (which would throw away the warm-client
// signal behind the ~79% conversions). Health is decided here and surfaced as a warning.
@Suite("Downbeat export health")
struct DownbeatExportHealthTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)
    private let staleAfter: TimeInterval = 30 * 86_400

    @Test func missingWhenTheFileIsNotThere() {
        #expect(DownbeatBridge.health(fileExists: false, decodeFailed: false,
                                      modifiedAt: nil, now: now, staleAfter: staleAfter) == .missing)
    }

    @Test func unreadableWhenPresentButUndecodable() {
        #expect(DownbeatBridge.health(fileExists: true, decodeFailed: true,
                                      modifiedAt: now, now: now, staleAfter: staleAfter) == .unreadable)
    }

    @Test func staleWhenOlderThanTheWindow() {
        let old = now.addingTimeInterval(-40 * 86_400)
        #expect(DownbeatBridge.health(fileExists: true, decodeFailed: false,
                                      modifiedAt: old, now: now, staleAfter: staleAfter) == .stale(ageDays: 40))
    }

    @Test func okWhenFreshAndReadable() {
        let recent = now.addingTimeInterval(-2 * 86_400)
        #expect(DownbeatBridge.health(fileExists: true, decodeFailed: false,
                                      modifiedAt: recent, now: now, staleAfter: staleAfter) == .ok)
        // Unknown mod date but readable: can't prove stale, so don't cry wolf.
        #expect(DownbeatBridge.health(fileExists: true, decodeFailed: false,
                                      modifiedAt: nil, now: now, staleAfter: staleAfter) == .ok)
    }

    @Test func warningTextOnlyForUnhealthyStates() {
        #expect(DownbeatBridge.warningText(for: .ok) == nil)
        #expect(DownbeatBridge.warningText(for: .missing)?.isEmpty == false)
        #expect(DownbeatBridge.warningText(for: .unreadable)?.isEmpty == false)
        #expect(DownbeatBridge.warningText(for: .stale(ageDays: 40))?.contains("40") == true)
    }

    // The Downbeat side ships export version 2 (adds bookings/blockedDates). The reader
    // must accept it and read clients/venues, ignoring keys it doesn't consume yet (#109);
    // throwing would make the live export look unreadable and treat every prospect as cold.
    @Test func acceptsVersion2AndIgnoresNewKeys() throws {
        let json = #"{"version":2,"clients":[{"id":"c1","displayName":"A Choir","email":"a@x.org","contractEmail":"a@x.org","hasLeftReview":false,"specialBehaviors":[],"hostingSite":"x.org"}],"venues":[],"bookings":[{"id":"B1","clientId":"c1","clientDisplayName":"A Choir","shootName":"Gala","startDate":"2026-03-10","endDate":"2026-03-10","venueName":"Pop-up Loft"}],"blockedDates":["2026-03-10"]}"#
        let export = try DownbeatBridge.decode(Data(json.utf8))
        #expect(export.clients.count == 1)
    }

    // A version-2 file on disk reads as healthy with its clients, not unreadable.
    @Test func loadWithHealthAcceptsVersion2() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("downbeat-export.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = #"{"version":2,"clients":[{"id":"c1","displayName":"A Choir","email":"a@x.org","contractEmail":"a@x.org","hasLeftReview":false,"specialBehaviors":[],"hostingSite":"x.org"}],"venues":[],"bookings":[],"blockedDates":[]}"#
        try Data(json.utf8).write(to: url)
        let loaded = DownbeatBridge.loadWithHealth(from: url, now: Date(), staleAfter: staleAfter)
        #expect(loaded.clients.count == 1)
        #expect(loaded.health == .ok)
    }

    // The IO wrapper: returns the clients it could read plus the health verdict.
    @Test func loadWithHealthReadsClientsAndFlagsState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("downbeat-export.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Missing file.
        #expect(DownbeatBridge.loadWithHealth(from: url, now: now, staleAfter: staleAfter).health == .missing)

        // Valid, fresh.
        let json = #"{"version":1,"clients":[{"id":"c1","displayName":"A Choir","email":"a@x.org","contractEmail":"a@x.org","hasLeftReview":false,"specialBehaviors":[],"hostingSite":"x.org"}],"venues":[]}"#
        try Data(json.utf8).write(to: url)
        let fresh = DownbeatBridge.loadWithHealth(from: url, now: Date(), staleAfter: staleAfter)
        #expect(fresh.clients.count == 1)
        #expect(fresh.health == .ok)

        // Same file read far in the future is stale.
        let later = Date().addingTimeInterval(40 * 86_400)
        if case .stale = DownbeatBridge.loadWithHealth(from: url, now: later, staleAfter: staleAfter).health {} else {
            Issue.record("expected stale")
        }

        // Garbage file.
        try Data("not json".utf8).write(to: url)
        let bad = DownbeatBridge.loadWithHealth(from: url, now: Date(), staleAfter: staleAfter)
        #expect(bad.clients.isEmpty)
        #expect(bad.health == .unreadable)
    }
}
