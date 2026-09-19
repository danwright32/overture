import Testing
import Foundation
import SwiftData

// #1424: the real clients in Dan's Shoots calendar that Overture does not treat as returning clients.
// Dan's call, 2026-09-18: "Yes, use the client tags", read from the imported shoot history and flagged
// beside the Downbeat coverage check.
//
// Every client, venue and org below is INVENTED. The real tags are Dan's clients and are private.
@Suite("Clients from the Shoots calendar that Overture does not know (#1424)")
struct CalendarClientCoverageTests {
    private func client(_ name: String, short: String? = nil) -> DownbeatClient {
        DownbeatClient(id: "id-\(name)", displayName: name, shortName: short, email: "", contractEmail: "",
                       phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false, specialBehaviors: [],
                       notes: nil, hostingSite: "")
    }

    private func source(_ org: String, tag: Bool? = nil) -> WatchedSource {
        let s = WatchedSource(sourceId: org, orgName: org, listingsURL: "https://example.com/\(org.count)",
                              kind: .html)
        s.clientTagOverride = tag
        return s
    }

    private func shoot(_ title: String, _ date: String) -> ShootRecord {
        ShootRecord(venue: "The Tin Room", date: date, title: title)
    }

    private func flagged(_ shoots: [ShootRecord], clients: [DownbeatClient] = [],
                         sources: [WatchedSource] = [], setAside: Set<String> = []) -> [CalendarClient] {
        CalendarClientCoverage.result(shoots: shoots, clients: clients, sources: sources,
                                      setAsideIds: setAside).flagged
    }

    // MARK: reading the tag

    @Test("the client is the bracket at the start of the title")
    func theTagIsTheLeadingBracket() {
        #expect(shoot("[Lantern Opera] Spring Gala", "2025-04-01").clientTag == "Lantern Opera")
        #expect(shoot("  [ Lantern Opera ]Spring Gala", "2025-04-01").clientTag == "Lantern Opera")
    }

    @Test("a title with no leading bracket, or an empty one, has no client")
    func noLeadingBracketNoClient() {
        #expect(shoot("Spring Gala", "2025-04-01").clientTag == nil)
        #expect(shoot("Spring Gala [rehearsal]", "2025-04-01").clientTag == nil)
        #expect(shoot("[] Spring Gala", "2025-04-01").clientTag == nil)
        #expect(shoot("[Lantern Opera Spring Gala", "2025-04-01").clientTag == nil)
    }

    // MARK: who is flagged

    @Test("a calendar client Downbeat does not know is flagged, with its count and last shoot")
    func anUnknownClientIsFlagged() {
        let found = flagged([shoot("[Lantern Opera] Gala", "2024-03-01"),
                             shoot("[Lantern Opera] Tosca", "2025-10-12"),
                             shoot("Untagged recital", "2025-11-01")])
        #expect(found == [CalendarClient(name: "Lantern Opera", key: "lantern opera", shootCount: 2,
                                         lastShoot: "2025-10-12", untaggedSourceName: nil)])
    }

    // Stating it twice would put one fact in two lists on the same screen (L605): a Downbeat client with no
    // source is `ClientCoverage.unarmed`'s to report.
    @Test("a calendar client Downbeat already knows is left to the Downbeat check")
    func aDownbeatClientIsNotFlaggedHere() {
        #expect(flagged([shoot("[Lantern Opera] Gala", "2024-03-01")],
                        clients: [client("Lantern Opera")]).isEmpty)
    }

    @Test("a calendar client a watched source already treats as a returning client is not flagged")
    func aTaggedSourceCoversIt() {
        #expect(flagged([shoot("[Lantern Opera] Gala", "2024-03-01")],
                        sources: [source("Lantern Opera", tag: true)]).isEmpty)
    }

    @Test("an untagged watched source that is probably them is named, so Dan can tag it")
    func anUntaggedSourceIsOffered() {
        let found = flagged([shoot("[Lantern Opera] Gala", "2024-03-01")],
                            sources: [source("Lantern Opera")])
        #expect(found.map(\.untaggedSourceName) == ["Lantern Opera"])
    }

    @Test("a source Dan tagged never a returning client is not offered back")
    func aNeverSourceIsNotOffered() {
        let found = flagged([shoot("[Lantern Opera] Gala", "2024-03-01")],
                            sources: [source("Lantern Opera", tag: false)])
        #expect(found.map(\.untaggedSourceName) == [nil])
    }

    @Test("two spellings of one tag are one client, shown in the spelling used most")
    func spellingsFold() {
        let found = flagged([shoot("[Lantern Opera] A", "2024-03-01"),
                             shoot("[LANTERN OPERA] B", "2024-04-01"),
                             shoot("[Lantern Opera] C", "2024-05-01")])
        #expect(found.map(\.name) == ["Lantern Opera"])
        #expect(found.map(\.shootCount) == [3])
    }

    @Test("the most shot client comes first, then the most recently shot")
    func ordering() {
        let found = flagged([shoot("[Quill Ensemble] A", "2025-01-01"),
                             shoot("[Harbor Choir] A", "2023-01-01"),
                             shoot("[Harbor Choir] B", "2023-02-01"),
                             shoot("[Moss Dance] A", "2025-06-01")])
        #expect(found.map(\.name) == ["Harbor Choir", "Moss Dance", "Quill Ensemble"])
    }

    @Test("a set aside client leaves the list and is listed as set aside, so it can be put back")
    func setAsideMovesIt() {
        let shoots = [shoot("[Lantern Opera] Gala", "2024-03-01")]
        let result = CalendarClientCoverage.result(shoots: shoots, clients: [], sources: [],
                                                   setAsideIds: ["calendar:lantern opera"])
        #expect(result.flagged.isEmpty)
        #expect(result.setAside.map(\.name) == ["Lantern Opera"])
    }

    @Test("the row names how many shoots and when the last one was, with its year")
    func theRowLine() {
        #expect(CoverageCopy.calendarShoots(count: 3, lastShoot: "2025-10-12") == "3 shoots, most recently Oct 12, 2025")
        #expect(CoverageCopy.calendarShoots(count: 1, lastShoot: "2019-01-21") == "1 shoot, most recently Jan 21, 2019")
    }

    // L3: built is not wired. The view is not invokable from here, so the wiring is pinned by source: the
    // section is placed in the sheet, and it is fed from the imported history and the shared set asides.
    @Test("the Sources sheet renders the section from the imported shoot history")
    func theSheetRendersIt() {
        let view = SourceGuardHelper.source("Overture/UI/SourcesView.swift")
        #expect(view.contains("coverageSection\n"))
        #expect(view.contains("calendarClientsSection\n"))
        #expect(view.contains("ShootHistory.loadWithHealth(now: Date()).shoots"))
        #expect(view.contains("CalendarClientCoverage.result(shoots: calendarShoots"))
    }

    // A Downbeat client id is a UUID, so the prefixed key can never collide with one, and the Downbeat
    // list's own set asides cannot reach into this one.
    @Test("a Downbeat set aside never sets a calendar client aside")
    func theTwoSetAsideVocabulariesAreApart() {
        let shoots = [shoot("[Lantern Opera] Gala", "2024-03-01")]
        #expect(flagged(shoots, setAside: ["lantern opera", "id-Lantern Opera"]).map(\.name) == ["Lantern Opera"])
    }
}
