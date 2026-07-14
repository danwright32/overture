import Testing
import Foundation
import SwiftData
@testable import Overture

@Suite("Group name matching")
struct GroupNameMatchTests {
    @Test func normalizeStripsPresenterPunctuationAndCase() {
        #expect(GroupNameMatch.normalize("Presented by The Tallis Scholars!") == "the tallis scholars")
        #expect(GroupNameMatch.normalize("Brooklyn Youth Chorus\nProgram of Bach") == "brooklyn youth chorus")
    }

    // #138 parity: the presenter line is found wherever it sits, matching the TS engine.
    @Test func findsPresenterLineWhenNotFirst() {
        #expect(GroupNameMatch.normalize("Spring Gala Concert\nPresented by Every Voice Choirs") == "every voice choirs")
    }

    @Test func exactMatchIsConfident() {
        #expect(GroupNameMatch.isConfident("Brooklyn Youth Chorus", "brooklyn youth chorus"))
    }

    @Test func wholeTokenContainmentIsConfidentAboveFraction() {
        // "Tallis Scholars" sits as a contiguous run inside "The Tallis Scholars"
        // and is 2/3 of it, above the fraction guard.
        #expect(GroupNameMatch.isConfident("Tallis Scholars", "The Tallis Scholars") == true)
    }

    @Test func shortNameDoesNotConfidentlyMatchLargerUnrelated() {
        // The false positive we must avoid: "New York" inside "New York Theatre Ballet".
        #expect(GroupNameMatch.isConfident("New York", "New York Theatre Ballet") == false)
    }

    // #105: booking-sheet names are "Presenter - Program"; the venue lists just the presenter.
    @Test func stripsProgramSubtitleAfterSeparator() {
        #expect(GroupNameMatch.normalize("Every Voice Choirs - Earth Day Jazz") == "every voice choirs")
        #expect(GroupNameMatch.normalize("Every Voice Choirs — Earth Day Jazz") == "every voice choirs")
        #expect(GroupNameMatch.normalize("Every Voice Choirs: Spring Concert") == "every voice choirs")
    }

    @Test func doesNotStripSingleWordGenericPrefix() {
        #expect(GroupNameMatch.normalize("Jazz - Spring Gala") == "jazz spring gala")
    }

    @Test func bookingProgramMatchesShorterCalendarPresenter() {
        #expect(GroupNameMatch.isConfident("Every Voice Choirs - Earth Day Jazz", "Every Voice Choirs") == true)
        #expect(GroupNameMatch.isConfident("Every Voice Choirs: Earth Day Jazz", "Every Voice Choirs") == true)
    }

    @Test func twoProgramsSharingOneWordPrefixDoNotConfidentlyMatch() {
        #expect(GroupNameMatch.isConfident("Jazz - Spring Gala", "Jazz - Winter Gala") == false)
    }

    @Test func sharedTokensMakeAPossibleMatch() {
        #expect(GroupNameMatch.isPossible("Manhattan Chamber Players", "Manhattan Chamber Orchestra") == true)
        #expect(GroupNameMatch.isPossible("Brooklyn Youth Chorus", "Vienna Boys Choir") == false)
    }
}

@Suite("Repeat-client match verdict")
struct HistoryMatchTests {
    private let clients = [
        DownbeatClient(id: "c1", displayName: "DCINY", shortName: nil, email: "a@b.org",
                       contractEmail: "a@b.org", phoneNumber: nil, isTaxExempt: nil,
                       hasLeftReview: false, specialBehaviors: [], notes: nil, hostingSite: "pixieset"),
        DownbeatClient(id: "c2", displayName: "Alaria Chamber Ensemble", shortName: "Alaria", email: "x@y.org",
                       contractEmail: "x@y.org", phoneNumber: nil, isTaxExempt: nil,
                       hasLeftReview: false, specialBehaviors: [], notes: nil, hostingSite: "pixieset"),
    ]

    @Test func confidentClientMatchIsBooked() {
        let v = HistoryMatch.matchRelationship(name: "DCINY", clients: clients, history: [])
        #expect(v.relationship == .booked)
        #expect(v.downbeatClientId == "c1")
        #expect(v.matchedClientName == "DCINY")
    }

    @Test func dncInHistorySuppresses() {
        let history = [HistoryRecord(groupName: "Loud Neighbors Choir", status: "dnc")]
        let v = HistoryMatch.matchRelationship(name: "Loud Neighbors Choir", clients: [], history: history)
        #expect(v.suppressed == true)
        #expect(v.relationship == .none)
    }

    @Test func priorColdContactIsContacted() {
        let history = [HistoryRecord(groupName: "Cold Outreach Quartet", status: "contacted")]
        let v = HistoryMatch.matchRelationship(name: "Cold Outreach Quartet", clients: [], history: history)
        #expect(v.relationship == .contacted)
    }

    @Test func fuzzyClientMatchBecomesPossibleNotScored() {
        // Shares "alaria" + "chamber" with "Alaria Chamber Ensemble" (half the tokens):
        // a possible match to confirm, not a confident booked one.
        let v = HistoryMatch.matchRelationship(name: "Alaria Chamber Players", clients: clients, history: [])
        #expect(v.relationship == .none)
        #expect(v.possible?.source == "downbeat_client")
        #expect(v.possible?.name == "Alaria Chamber Ensemble")
    }

    @Test func noMatchIsNone() {
        let v = HistoryMatch.matchRelationship(name: "Totally Unknown Group", clients: clients, history: [])
        #expect(v.relationship == .none)
        #expect(v.possible == nil)
    }

    @Test func warmHistoryIsWarm() {
        let v = HistoryMatch.matchRelationship(name: "Referral Choir", clients: [],
                                               history: [HistoryRecord(groupName: "Referral Choir", status: "warm")])
        #expect(v.relationship == .warm)
    }

    @Test func declinedHistoryIsDeclinedByYou() {
        let v = HistoryMatch.matchRelationship(name: "Date Clash Opera", clients: [],
                                               history: [HistoryRecord(groupName: "Date Clash Opera", status: "declined")])
        #expect(v.relationship == .declinedByYou)
    }

    @Test func lostSoftHistoryIsLostSoft() {
        let v = HistoryMatch.matchRelationship(name: "Keep In Mind Band", clients: [],
                                               history: [HistoryRecord(groupName: "Keep In Mind Band", status: "lost_soft")])
        #expect(v.relationship == .lostSoft)
    }

    @Test func lostHardHistoryIsLostHard() {
        let v = HistoryMatch.matchRelationship(name: "Never Again Quartet", clients: [],
                                               history: [HistoryRecord(groupName: "Never Again Quartet", status: "lost_hard")])
        #expect(v.relationship == .lostHard)
    }

    @Test func relationshipBeatsOutcomeWhenBothPresent() {
        // A warm relationship plus a lost record on the same org reads warm: relationship wins.
        let history = [HistoryRecord(groupName: "Mixed Signals Ensemble", status: "warm"),
                       HistoryRecord(groupName: "Mixed Signals Ensemble", status: "lost_soft")]
        let v = HistoryMatch.matchRelationship(name: "Mixed Signals Ensemble", clients: [], history: history)
        #expect(v.relationship == .warm)
    }
}

@Suite("Ingest persistence")
@MainActor
struct IngestPersistenceTests {
    @Test func ingestPersistsDownbeatClientId() throws {
        let context = try ModelContext(ModelContainer(for: Prospect.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let client = DownbeatClient(id: "CID-1", displayName: "Every Voice Choirs",
            shortName: nil, email: "a@x.org", contractEmail: "a@x.org",
            phoneNumber: nil, isTaxExempt: nil, hasLeftReview: false,
            specialBehaviors: [], notes: nil, hostingSite: "x.org")
        let event = ExtractedEvent(title: "Every Voice Choirs", presenter: nil,
            venue: "Merkin Hall", performanceDate: "2026-03-11", sourceUrl: "https://x")
        _ = ScoutService.apply(events: [event], clients: [client], history: [],
                               blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: context)
        let saved = try context.fetch(FetchDescriptor<Prospect>())
        #expect(saved.first?.downbeatClientId == "CID-1")
    }
}

@Suite("Downbeat export decoding")
struct DownbeatExportTests {
    @Test func decodesAndVersionGates() throws {
        let json = """
        {"version":1,"clients":[{"id":"c1","displayName":"DCINY","email":"a@b.org","contractEmail":"a@b.org","hasLeftReview":false,"specialBehaviors":[],"hostingSite":"pixieset"}],"venues":[]}
        """
        let export = try DownbeatBridge.decode(Data(json.utf8))
        #expect(export.clients.count == 1)
        #expect(export.clients[0].displayName == "DCINY")

        let bad = Data(#"{"version":9,"clients":[],"venues":[]}"#.utf8)
        #expect(throws: DownbeatExportError.unsupportedVersion(9)) {
            try DownbeatBridge.decode(bad)
        }
    }
}
