import Foundation
import SwiftData

// Ingests a Prep results file into the local store: matches each result to an existing
// prospect by natural key and fills in the found contact and the drafted email. A
// prospect that gains a draft moves to `.drafted` (ready for Dan to review/approve).
// Results with no matching prospect are skipped. Mirrors ResultsImporter.

enum PrepImporter {
    // unmatchedKeys: results that matched no kept prospect (surfaced, never swallowed,
    // since the Prep run is a separate fallible process). skippedEdited: drafts left
    // untouched because Dan had hand-edited them.
    struct Outcome: Equatable, Sendable {
        var matched = 0
        var drafted = 0
        var skippedEdited = 0
        var unmatchedKeys: [String] = []
    }

    @MainActor
    @discardableResult
    static func ingest(_ results: PrepResults, into context: ModelContext) -> Outcome {
        var outcome = Outcome()
        for r in results.results {
            let key = r.naturalKey
            let descriptor = FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })
            guard let p = (try? context.fetch(descriptor))?.first else {
                outcome.unmatchedKeys.append(key)
                continue
            }
            outcome.matched += 1

            if let c = r.contact {
                p.contactName = c.name
                p.contactRole = c.role
                p.contactEmail = c.email
                p.contactMethodRaw = c.method
                p.contactConfidenceRaw = c.confidence
                p.contactFormURL = c.formUrl
            }
            if let d = r.draft {
                // Never overwrite a draft Dan hand-edited; his version wins until he
                // explicitly skips/dismisses it.
                if p.draftEditedByDan {
                    outcome.skippedEdited += 1
                } else {
                    p.draftSubject = d.subject
                    p.draftBody = d.body
                    p.draftVariant = d.variant
                    // A fresh draft returns the prospect to "needs review", but never
                    // silently un-approves one Dan already approved.
                    if p.status == .queued || p.status == .new || p.status == .drafted {
                        p.status = .drafted
                    }
                    outcome.drafted += 1
                }
            }
        }
        try? context.save()
        return outcome
    }

    @MainActor
    static func ingestFile(at url: URL, into context: ModelContext) throws -> Outcome {
        let data = try Data(contentsOf: url)
        return ingest(try PrepResultsDecoder.decode(data), into: context)
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-prep-results.json")
    }
}
