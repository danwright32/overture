import Testing
import Foundation
import SwiftData
@testable import Overture

private let sampleJSON = """
{
  "version": 1,
  "generatedAt": "2026-06-22T19:18:09.848Z",
  "prospects": [
    {
      "groupName": "Indianapolis Children's Choir",
      "discipline": "choral",
      "venue": "Stern Auditorium / Perelman Stage",
      "performanceDate": "2026-06-24",
      "sourceListingUrl": "https://example.com/a",
      "websiteUrl": null,
      "priorRelationship": "none",
      "production": "self",
      "profile": "strong",
      "coverage": "likely_uncovered",
      "fitScore": 7,
      "tier": "high",
      "fitReason": "Self-produced children's choir.",
      "matchedClientName": null,
      "possibleMatchSource": null,
      "possibleMatchName": null
    },
    {
      "groupName": "New York Rising Stars Concert",
      "discipline": "music",
      "venue": "Weill Recital Hall",
      "performanceDate": "2026-06-23",
      "sourceListingUrl": null,
      "websiteUrl": null,
      "priorRelationship": "none",
      "production": "agency",
      "profile": "weak",
      "coverage": "likely_uncovered",
      "fitScore": -2,
      "tier": "longshot",
      "fitReason": "Rising-stars showcase rental.",
      "matchedClientName": null,
      "possibleMatchSource": null,
      "possibleMatchName": null
    }
  ]
}
"""

@MainActor
@Suite("Results import")
struct ResultsImportTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // #394: the queue item exposes whether the performance can still send, so the Send button persists
    // for the next recipient until every one is sent (the lead sentAt rollup flips on the FIRST send,
    // so the button must NOT gate on that alone under fan-out).
    @Test func queueItemTracksWhetherARecipientCanStillSend() throws {
        let ctx = ModelContext(try makeContainer())
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        p.draftSubject = "S"; p.draftBody = "Hi"
        ctx.insert(p)
        let act = Recipient(id: "a@x.example", email: "a@x.example", name: "A", provenance: .act)
        let presenter = Recipient(id: "b@x.example", email: "b@x.example", name: "B", provenance: .presenter)
        p.setRecipients([act, presenter])

        #expect(QueueItem(p).hasPendingRecipient == true)            // both pending

        act.sendState = .sent; act.sentAt = Date()
        #expect(QueueItem(p).hasPendingRecipient == true)            // one sent, one still pending

        presenter.sendState = .sent; presenter.sentAt = Date()
        #expect(QueueItem(p).hasPendingRecipient == false)          // every recipient sent

        // A form-only contact (no email) is pending but not auto-sendable, so it does NOT keep the row sendable.
        let formOnly = Recipient(id: "form:https://x", email: nil, name: "C", provenance: .act,
                                 contactFormURL: "https://x")
        p.setRecipients([formOnly])
        #expect(QueueItem(p).hasPendingRecipient == false)
    }

    // #418 B1 — QueueItem carries per-contact snapshots in send order (act before presenter) for the
    // conversation surface, with each contact's reply text and a derived status.
    @Test func queueItemBuildsContactSnapshotsInSendOrder() throws {
        let ctx = ModelContext(try makeContainer())
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.draftSubject = "S"; p.draftBody = "Hi"; p.sentAt = Date()
        ctx.insert(p)
        let presenter = Recipient(id: "b@present.example", email: "b@present.example", name: "Bo", provenance: .presenter)
        presenter.sendState = .sent
        let act = Recipient(id: "a@act.example", email: "a@act.example", name: "Ann Lee", provenance: .act)
        act.sendState = .sent; act.replied = true; act.lastReplyText = "Yes, let's talk."
        p.setRecipients([presenter, act])   // inserted out of send order on purpose

        let item = QueueItem(p)
        #expect(item.contacts.map(\.id) == ["a@act.example", "b@present.example"])  // act first
        let ann = item.contacts.first!
        #expect(ann.displayName == "Ann Lee")
        #expect(ann.statusLabel == "In conversation")
        #expect(ann.isAutoReplied == true)
        #expect(ann.lastReplyText == "Yes, let's talk.")
    }

    // #418 B1 — the derived per-contact status line: terminal resolution wins, then bounce, then reply,
    // then send state; and isAutoReplied is true only for an auto (not hand-marked) reply.
    @Test func recipientSnapshotStatusLabelsAndAutoReplied() {
        func s(_ sendState: SendState = .sent, replied: Bool = false, resolution: RecipientResolution? = nil,
               bounced: Bool = false, email: String? = "a@act.example", source: OutcomeSource? = nil) -> RecipientSnapshot {
            RecipientSnapshot(id: "x", name: "N", email: email, role: nil, provenance: .act,
                              sendState: sendState, replied: replied, lastReplyText: nil,
                              resolution: resolution, bounced: bounced, outcomeSource: source)
        }
        #expect(s(resolution: .booked).statusLabel == "Booked")
        #expect(s(resolution: .declinedSoft).statusLabel == "Closed (not now)")
        #expect(s(resolution: .declinedHard).statusLabel == "Closed (not interested)")
        #expect(s(bounced: true).statusLabel == "Bounced")
        #expect(s(replied: true).statusLabel == "In conversation")
        #expect(s().statusLabel == "Awaiting reply")
        #expect(s(.pending).statusLabel == "Not sent yet")
        #expect(s(.pending, email: nil).statusLabel == "No email yet")
        #expect(s(.suppressed).statusLabel == "Paused (booked elsewhere)")
        #expect(s(replied: true).isAutoReplied == true)
        #expect(s(replied: true, source: .manual).isAutoReplied == false)   // Dan's mark, not an auto reply
        let noName = RecipientSnapshot(id: "x", name: nil, email: "e@e.example", role: nil, provenance: .act,
                                       sendState: .pending, replied: false, lastReplyText: nil,
                                       resolution: nil, bounced: false, outcomeSource: nil)
        #expect(noName.displayName == "e@e.example")
    }

    @Test func decodesFileAndRejectsWrongVersion() throws {
        let file = try ResultsFileDecoder.decode(Data(sampleJSON.utf8))
        #expect(file.version == 1)
        #expect(file.prospects.count == 2)

        let outOfRange = Data(#"{"version":99,"generatedAt":"x","prospects":[]}"#.utf8)
        #expect(throws: ResultsFileError.unsupportedVersion(99)) {
            try ResultsFileDecoder.decode(outOfRange)
        }
    }

    @Test func decodesVersionTwoFile() throws {
        let v2JSON = Data(#"{"version":2,"generatedAt":"2026-06-25T00:00:00Z","prospects":[]}"#.utf8)
        let file = try ResultsFileDecoder.decode(v2JSON)
        #expect(file.version == 2)
        #expect(file.prospects.isEmpty)
    }

    @Test func ingestInsertsAllAsNew() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let file = try ResultsFileDecoder.decode(Data(sampleJSON.utf8))

        let outcome = try ResultsImporter.ingest(file, into: context)
        #expect(outcome.inserted == 2)
        #expect(outcome.updated == 0)

        let stored = try context.fetch(FetchDescriptor<Prospect>())
        #expect(stored.count == 2)
        #expect(stored.allSatisfy { $0.status == .new })
    }

    @Test func reingestPreservesDansDecisionAndRefreshesRanking() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let file = try ResultsFileDecoder.decode(Data(sampleJSON.utf8))
        _ = try ResultsImporter.ingest(file, into: context)

        // Dan dismisses one prospect.
        let key = Prospect.makeNaturalKey(
            groupName: "New York Rising Stars Concert",
            performanceDate: "2026-06-23",
            venue: "Weill Recital Hall"
        )
        let target = try context.fetch(
            FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })
        ).first
        target?.status = .dismissed
        try context.save()

        // A fresh scout run re-ingests the same performances (different fit score).
        var rescored = file
        rescored.prospects[1].fitScore = 4
        let outcome = try ResultsImporter.ingest(rescored, into: context)

        #expect(outcome.inserted == 0)
        #expect(outcome.updated == 2)

        let refreshed = try context.fetch(
            FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })
        ).first
        #expect(refreshed?.status == .dismissed)  // decision preserved
        #expect(refreshed?.fitScore == 4)          // ranking refreshed
    }
}
