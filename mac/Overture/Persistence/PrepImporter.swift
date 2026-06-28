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
        var skippedRecipientEdits = 0
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

            if let contacts = r.contacts, !contacts.isEmpty {
                if p.recipientsEditedByDan {
                    // Dan curated the recipient list; a re-run never clobbers it (a freeze separate
                    // from the draft freeze below, so the body redraft still flows).
                    outcome.skippedRecipientEdits += 1
                } else {
                    ingestContacts(contacts, into: p)
                }
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

    // Upsert each found contact into the prospect's recipients (#392). Match by id (canonical email
    // or form URL) first; failing that, match an existing still-pending recipient of the SAME
    // non-manual provenance, so a re-run that CORRECTS an act/presenter email updates that recipient
    // in place rather than duplicating it. A genuinely new provenance is appended as pending. An
    // already-sent recipient is never rewritten (its address is locked). The primary act contact is
    // mirrored into the legacy singular fields for the current UI, removed in the Phase 8 cleanup.
    @MainActor
    private static func ingestContacts(_ contacts: [PrepContact], into p: Prospect) {
        var current = p.recipients
        for c in contacts {
            guard let id = Recipient.makeId(email: c.email, formURL: c.formUrl) else { continue }
            let provenance = RecipientProvenance(rawValue: c.provenance ?? "") ?? .act
            let email = (c.email?.isEmpty == false) ? c.email : nil

            if let i = current.firstIndex(where: { $0.id == id }) {
                apply(c, email: email, provenance: provenance, to: &current[i])
            } else if let i = current.firstIndex(where: {
                $0.provenance == provenance && $0.provenance != .manual && $0.sendState == .pending
            }) {
                current[i].id = id
                apply(c, email: email, provenance: provenance, to: &current[i])
            } else {
                current.append(Recipient(id: id, email: email, name: c.name, role: c.role,
                                         provenance: provenance, contactMethodRaw: c.method,
                                         contactConfidenceRaw: c.confidence, contactFormURL: c.formUrl))
            }
        }
        p.setRecipients(current)

        // Transitional legacy mirror: track the act contact (or the first recipient) so the current
        // single-contact UI keeps working until Phase 7 reads recipients directly.
        if let primary = current.first(where: { $0.provenance == .act }) ?? current.first {
            p.contactName = primary.name
            p.contactRole = primary.role
            p.contactEmail = primary.email
            p.contactMethodRaw = primary.contactMethodRaw
            p.contactConfidenceRaw = primary.contactConfidenceRaw
            p.contactFormURL = primary.contactFormURL
        }
    }

    // Refresh a recipient's contact fields from a found contact, preserving its send/engagement
    // state. nil fields in the new contact don't erase existing values.
    private static func apply(_ c: PrepContact, email: String?, provenance: RecipientProvenance,
                              to r: inout Recipient) {
        if let email { r.email = email }
        r.name = c.name ?? r.name
        r.role = c.role ?? r.role
        r.provenance = provenance
        r.contactMethodRaw = c.method ?? r.contactMethodRaw
        r.contactConfidenceRaw = c.confidence ?? r.contactConfidenceRaw
        r.contactFormURL = c.formUrl ?? r.contactFormURL
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
