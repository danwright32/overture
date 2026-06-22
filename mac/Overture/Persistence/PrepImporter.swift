import Foundation
import SwiftData

// Ingests a Prep results file into the local store: matches each result to an existing
// prospect by natural key and fills in the found contact and the drafted email. A
// prospect that gains a draft moves to `.drafted` (ready for Dan to review/approve).
// Results with no matching prospect are skipped. Mirrors ResultsImporter.

enum PrepImporter {
    struct Outcome: Equatable, Sendable { var matched: Int; var drafted: Int }

    @MainActor
    @discardableResult
    static func ingest(_ results: PrepResults, into context: ModelContext) -> Outcome {
        var matched = 0
        var drafted = 0
        for r in results.results {
            let key = r.naturalKey
            let descriptor = FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })
            guard let p = (try? context.fetch(descriptor))?.first else { continue }
            matched += 1

            if let c = r.contact {
                p.contactName = c.name
                p.contactRole = c.role
                p.contactEmail = c.email
                p.contactMethodRaw = c.method
                p.contactConfidenceRaw = c.confidence
                p.contactFormURL = c.formUrl
            }
            if let d = r.draft {
                p.draftSubject = d.subject
                p.draftBody = d.body
                p.draftVariant = d.variant
                p.draftEditedByDan = false
                // A fresh draft returns the prospect to "needs review", but never
                // silently un-approves one Dan already approved.
                if p.status == .queued || p.status == .new || p.status == .drafted {
                    p.status = .drafted
                }
                drafted += 1
            }
        }
        try? context.save()
        return Outcome(matched: matched, drafted: drafted)
    }

    @MainActor
    static func ingestFile(at url: URL, into context: ModelContext) throws -> Outcome {
        let data = try Data(contentsOf: url)
        return ingest(try PrepResultsDecoder.decode(data), into: context)
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overture", isDirectory: true)
            .appendingPathComponent("overture-prep-results.json")
    }
}
