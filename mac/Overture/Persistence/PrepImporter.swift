import Foundation
import SwiftData

// Ingests a Prep results file into the local store: matches each result to an existing
// prospect by natural key and fills in the found contact and the drafted email. A
// prospect that gains a draft moves to `.drafted` (ready for Dan to review/approve).
// Results with no matching prospect are skipped.

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
        // #499: set when a context.save() failed, so this run's matches/drafts may not persist.
        var saveFailed = false
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
            // #611: only touch the flag when fresh evidence actually differs from what's already
            // recorded, so a re-run reporting the SAME note never silently un-dismisses something
            // Dan already judged a false positive, and an absent note (a transient research miss)
            // never erases a real finding.
            if let note = r.alreadyCoveredNote, !note.isEmpty, note != p.alreadyCoveredNote {
                p.alreadyCoveredNote = note
                p.alreadyCoveredDismissed = false
            }
        }
        do {
            try context.save()
        } catch {
            outcome.saveFailed = true
        }
        return outcome
    }

    // Upsert each found contact into the prospect's recipients (#392). Match by id (canonical email
    // or form URL) first; failing that, match an existing still-pending recipient of the SAME
    // non-manual provenance, so a re-run that CORRECTS an act/presenter email updates that recipient
    // in place rather than duplicating it. A genuinely new provenance is appended as pending. An
    // already-sent recipient is never rewritten (its address is locked): a "corrected" contact for it
    // is dropped rather than appended as a duplicate (#408, audit SUP-017).
    @MainActor
    private static func ingestContacts(_ contacts: [PrepContact], into p: Prospect) {
        // A batch that (unexpectedly) carries more than one contact of the same provenance cannot be
        // matched to an existing recipient by provenance alone: the pending/sent fallbacks below would
        // let a later contact in the batch grab and overwrite an earlier one's row (#408). When a
        // provenance is ambiguous within this batch, every contact of it is always appended fresh.
        let provenanceCounts = Dictionary(grouping: contacts) { $0.provenance ?? "" }.mapValues(\.count)

        for c in contacts {
            guard let id = Recipient.makeId(email: c.email, formURL: c.formUrl) else { continue }
            let provenance = RecipientProvenance(rawValue: c.provenance ?? "") ?? .act
            let email = (c.email?.isEmpty == false) ? c.email : nil
            let provenanceIsUnambiguous = (provenanceCounts[c.provenance ?? ""] ?? 0) <= 1

            if let existing = p.recipients.first(where: { $0.id == id }) {
                apply(c, email: email, provenance: provenance, venue: p.venue, to: existing)
            } else if provenanceIsUnambiguous,
                      let existing = matchPending(in: p, provenance: provenance, formURL: c.formUrl) {
                // A corrected email for an existing pending act/presenter (or a form-only recipient
                // that just gained an email, matched by its form URL #408) updates the row in place.
                existing.id = id
                apply(c, email: email, provenance: provenance, venue: p.venue, to: existing)
            } else if provenanceIsUnambiguous,
                      alreadySent(in: p, provenance: provenance) {
                continue
            } else {
                let recipient = Recipient(id: id, email: email, name: c.name, role: c.role,
                                          provenance: provenance, contactMethodRaw: c.method,
                                          contactConfidenceRaw: c.confidence, contactFormURL: c.formUrl)
                // overrideBody is only ever meaningful for a .performer recipient (#640); see apply()'s
                // matching guard for why a non-performer contact never carries one.
                recipient.overrideBody = provenance == .performer ? c.overrideBody : nil
                // #388: never second-guess a manually-added contact; Dan typed it in himself.
                if provenance != .manual {
                    recipient.looksLikeVenue = VenueContactGuard.looksLikeVenue(email: email, venue: p.venue)
                }
                p.addRecipient(recipient)
            }
        }
    }

    // Find a still-pending, non-manual recipient of the same provenance to update in place. When the
    // incoming contact carries a form URL, match the recipient with that SAME form URL (so a
    // form-only recipient gaining an email keeps its row, #408) and never grab an unrelated pending
    // recipient; otherwise (a plain email correction) match the first pending one of that provenance.
    private static func matchPending(in p: Prospect, provenance: RecipientProvenance,
                                     formURL: String?) -> Recipient? {
        let pending = p.recipients.filter {
            $0.provenance == provenance && $0.provenance != .manual && $0.sendState == .pending
        }
        if let formURL {
            return pending.first { $0.contactFormURL == formURL }
        }
        return pending.first
    }

    // True when a non-manual recipient of this provenance has already sent (#408, audit SUP-017): its
    // address is locked, so a "corrected" contact of the same provenance found by a later run must be
    // dropped rather than appended as a second recipient.
    private static func alreadySent(in p: Prospect, provenance: RecipientProvenance) -> Bool {
        p.recipients.contains {
            $0.provenance == provenance && $0.provenance != .manual && $0.sendState == .sent
        }
    }

    // Refresh a recipient row's contact fields from a found contact, preserving its send/engagement
    // state. nil fields in the new contact don't erase existing values.
    private static func apply(_ c: PrepContact, email: String?, provenance: RecipientProvenance,
                              venue: String?, to r: Recipient) {
        let priorEmail = r.email
        if let email { r.email = email }
        r.name = c.name ?? r.name
        r.role = c.role ?? r.role
        r.provenance = provenance
        r.contactMethodRaw = c.method ?? r.contactMethodRaw
        r.contactConfidenceRaw = c.confidence ?? r.contactConfidenceRaw
        r.contactFormURL = c.formUrl ?? r.contactFormURL
        // overrideBody is only ever meaningful for a .performer recipient (#640): unlike the fields
        // above, a reclassification AWAY from .performer must CLEAR it rather than preserve it, or a
        // recipient now treated as a generic act/presenter contact would keep stale second-person
        // text addressed to them personally.
        r.overrideBody = provenance == .performer ? (c.overrideBody ?? r.overrideBody) : nil
        // #388: re-derive the venue-match guess fresh on EVERY ingest (never a one-way latch), but
        // only reset Dan's dismissal of it when the address itself actually changed; a re-run that
        // reports the SAME still-flagged address must not silently un-dismiss a guess he already
        // judged wrong, mirroring the #611 alreadyCoveredDismissed reset-on-real-change convention.
        // Never second-guess a manually-added contact.
        if provenance != .manual {
            if r.email != priorEmail { r.looksLikeVenueDismissed = false }
            r.looksLikeVenue = VenueContactGuard.looksLikeVenue(email: r.email, venue: venue)
        }
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
