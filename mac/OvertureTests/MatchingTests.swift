import Testing
import Foundation
@testable import Overture

@Suite("Group name matching")
struct GroupNameMatchTests {
    @Test func normalizeStripsPresenterPunctuationAndCase() {
        #expect(GroupNameMatch.normalize("Presented by The Tallis Scholars!") == "the tallis scholars")
        #expect(GroupNameMatch.normalize("Brooklyn Youth Chorus\nProgram of Bach") == "brooklyn youth chorus")
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
