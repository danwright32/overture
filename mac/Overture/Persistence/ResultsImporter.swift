import Foundation
import SwiftData

// Ingests a results file into the local store. Upserts by natural key: a prospect
// already present has its ranking/classification refreshed but KEEPS Dan's
// keep/dismiss decision; a new one is inserted as `.new`. This is the fire-and-forget
// boundary, exactly like Downbeat ingesting nothing but writing its export atomically.

enum ResultsImporter {
    struct Outcome: Equatable { var inserted: Int; var updated: Int }

    @MainActor
    @discardableResult
    static func ingest(_ file: ResultsFile, into context: ModelContext) throws -> Outcome {
        var inserted = 0
        var updated = 0

        for p in file.prospects {
            let key = Prospect.makeNaturalKey(
                groupName: p.groupName,
                performanceDate: p.performanceDate,
                venue: p.venue
            )
            let descriptor = FetchDescriptor<Prospect>(
                predicate: #Predicate { $0.naturalKey == key }
            )
            if let existing = try context.fetch(descriptor).first {
                apply(p, to: existing) // preserves statusRaw / dismissReasonRaw
                updated += 1
            } else {
                context.insert(make(p, key: key))
                inserted += 1
            }
        }

        try context.save()
        return Outcome(inserted: inserted, updated: updated)
    }

    @MainActor
    static func ingestFile(at url: URL, into context: ModelContext) throws -> Outcome {
        let data = try Data(contentsOf: url)
        let file = try ResultsFileDecoder.decode(data)
        return try ingest(file, into: context)
    }

    // The default handoff location, sibling to Downbeat's downbeat-export.json.
    static var defaultResultsURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overture", isDirectory: true)
            .appendingPathComponent("overture-results.json")
    }

    private static func make(_ p: ResultProspect, key: String) -> Prospect {
        Prospect(
            naturalKey: key,
            groupName: p.groupName,
            discipline: p.discipline,
            venue: p.venue,
            performanceDate: p.performanceDate,
            sourceListingURL: p.sourceListingUrl,
            websiteURL: p.websiteUrl,
            priorRelationship: p.priorRelationship,
            production: p.production,
            profile: p.profile,
            coverage: p.coverage,
            fitScore: p.fitScore,
            tier: p.tier,
            fitReason: p.fitReason,
            matchedClientName: p.matchedClientName,
            possibleMatchSource: p.possibleMatchSource,
            possibleMatchName: p.possibleMatchName
        )
    }

    // Refresh the scout-owned fields; never touch status/dismissReason (Dan owns those).
    private static func apply(_ p: ResultProspect, to existing: Prospect) {
        existing.groupName = p.groupName
        existing.discipline = p.discipline
        existing.venue = p.venue
        existing.performanceDate = p.performanceDate
        existing.sourceListingURL = p.sourceListingUrl
        existing.websiteURL = p.websiteUrl
        existing.priorRelationship = p.priorRelationship
        existing.production = p.production
        existing.profile = p.profile
        existing.coverage = p.coverage
        existing.fitScore = p.fitScore
        existing.tier = p.tier
        existing.fitReason = p.fitReason
        existing.matchedClientName = p.matchedClientName
        existing.possibleMatchSource = p.possibleMatchSource
        existing.possibleMatchName = p.possibleMatchName
        existing.ingestedAt = Date()
    }
}

extension QueueItem {
    init(_ p: Prospect) {
        self.init(
            id: p.naturalKey,
            groupName: p.groupName,
            discipline: p.discipline,
            venue: p.venue,
            performanceDate: p.performanceDate,
            sourceListingURL: p.sourceListingURL,
            websiteURL: p.websiteURL,
            priorRelationship: p.priorRelationship,
            production: p.production,
            profile: p.profile,
            coverage: p.coverage,
            fitScore: p.fitScore,
            tier: p.tier,
            fitReason: p.fitReason,
            matchedClientName: p.matchedClientName,
            possibleMatchSource: p.possibleMatchSource,
            possibleMatchName: p.possibleMatchName,
            status: p.status,
            contactName: p.contactName,
            contactRole: p.contactRole,
            contactEmail: p.contactEmail,
            contactConfidence: p.contactConfidence,
            contactMethod: p.contactMethod,
            contactFormURL: p.contactFormURL,
            draftSubject: p.draftSubject,
            draftBody: p.draftBody,
            draftEditedByDan: p.draftEditedByDan,
            outcome: p.outcome
        )
    }
}
