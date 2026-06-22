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
        let schema = Schema([Prospect.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test func decodesFileAndRejectsWrongVersion() throws {
        let file = try ResultsFileDecoder.decode(Data(sampleJSON.utf8))
        #expect(file.version == 1)
        #expect(file.prospects.count == 2)

        let badVersion = Data(#"{"version":2,"generatedAt":"x","prospects":[]}"#.utf8)
        #expect(throws: ResultsFileError.unsupportedVersion(2)) {
            try ResultsFileDecoder.decode(badVersion)
        }
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
