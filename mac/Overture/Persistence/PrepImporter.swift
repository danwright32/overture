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
        // #367: the Prep run is prompt-driven, not code, so its result can carry a draft/contacts
        // update outside what the prospect's own reprep flags actually asked for (e.g. a draft
        // returned for a contacts-only request). Counts every such update the app refused to apply,
        // distinct from skippedEdited/skippedRecipientEdits (which mean Dan's own edit wins).
        var skippedOutOfScope = 0
        var unmatchedKeys: [String] = []
        // #499: set when a context.save() failed, so this run's matches/drafts may not persist.
        var saveFailed = false
        // #754: the performer matcher's reference data (the Downbeat client export, the booking
        // history) was missing, stale or corrupt, so a performer who IS a past client may have read
        // as a cold lead. Surfaced rather than swallowed: an empty match result otherwise looks
        // exactly like a healthy run that genuinely found nothing.
        var matchDataWarning: String? = nil
    }

    // Fail loud, not silent (#754). The performer matcher is only as good as the two files it reads,
    // and both are written by other processes. Says what the breakage COSTS Dan (a warm lead reading
    // as cold), not merely that a file is unreadable, because the cost is the part he can act on.
    // Pure, so the wording and the combinations are testable without touching the filesystem.
    static func matchDataWarning(clientHealth: DownbeatBridge.Health, historyUnreadable: Bool) -> String? {
        var problems: [String] = []
        switch clientHealth {
        case .ok: break
        case .missing: problems.append("no Downbeat client export was found")
        case .unreadable: problems.append("the Downbeat client export couldn't be read")
        case .stale(let days): problems.append("the Downbeat client export is \(days) days old")
        }
        if historyUnreadable { problems.append("the booking history couldn't be read") }
        guard !problems.isEmpty else { return nil }
        return problems.joined(separator: " and ")
            + ", so a performer who is a past client may have read as cold"
    }

    @MainActor
    @discardableResult
    // clients/history feed the performer-name warm-lead matcher (#751). They default to empty, which
    // simply means no performer matching runs; the real entry point (ingestFile) always supplies them.
    static func ingest(_ results: PrepResults, into context: ModelContext, now: Date = Date(),
                       clients: [DownbeatClient] = [], history: [HistoryRecord] = []) -> Outcome {
        var outcome = Outcome()
        for r in results.results {
            let key = r.naturalKey
            let descriptor = FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })
            guard let p = (try? context.fetch(descriptor))?.first else {
                outcome.unmatchedKeys.append(key)
                continue
            }
            outcome.matched += 1

            // #367: what Dan actually asked for this cycle, so a result that carries the other
            // half anyway (the run misreading reprepMode, or a stale/mismatched item) gets ignored
            // rather than applied. Both false (a normal, never-flagged prospect) means neither
            // restriction applies, exactly as before this feature existed.
            let contactsOnlyRequest = p.reprepContactsRequested && !p.reprepDraftRequested
            let draftOnlyRequest = p.reprepDraftRequested && !p.reprepContactsRequested
            // Defensive backstop independent of ReprepRequest's own gate (red-team finding 3): never
            // apply a draft change once anything has gone out for this prospect, even if such an
            // item somehow reached ingest.
            let draftBlockedBySend = p.sentAt != nil

            if let contacts = r.contacts, !contacts.isEmpty {
                if p.recipientsEditedByDan {
                    // Dan curated the recipient list; a re-run never clobbers it (a freeze separate
                    // from the draft freeze below, so the body redraft still flows).
                    outcome.skippedRecipientEdits += 1
                } else if draftOnlyRequest {
                    outcome.skippedOutOfScope += 1
                } else {
                    ingestContacts(contacts, into: p, context: context)
                }
                // The warm-lead correction is derived from the RESEARCH, not from the recipient list,
                // so it still runs when Dan's curated recipients are frozen: learning that this
                // performer is a past client has nothing to do with who he chose to email. A
                // draft-only request carries no fresh contact research to trust, so it stays out.
                if !draftOnlyRequest {
                    applyPerformerMatch(contacts, to: p, clients: clients, history: history)
                }
            }
            if let d = r.draft {
                // Never overwrite a draft Dan hand-edited; his version wins until he
                // explicitly skips/dismisses it.
                if p.draftEditedByDan {
                    outcome.skippedEdited += 1
                } else if contactsOnlyRequest || draftBlockedBySend {
                    outcome.skippedOutOfScope += 1
                } else {
                    p.draftSubject = d.subject
                    p.draftBody = d.body
                    p.draftVariant = d.variant
                    // A fresh draft returns the prospect to "needs review", but never silently
                    // un-approves one Dan already approved... except #367's whole point is that a
                    // real redraft DOES require re-review even from .approved, so Dan can't send
                    // stale-reviewed text under a changed body.
                    if p.status == .queued || p.status == .new || p.status == .drafted || p.status == .approved {
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
            // #367: the request is "served" once the run has produced any result for this key,
            // whether applied or skipped above; an item the run never reaches keeps its flags and
            // correctly rides along again in the next queue.
            p.reprepDraftRequested = false
            p.reprepContactsRequested = false
            // #733: stamps every matched result, not just re-preps, so re-prepping a prospect a
            // normal first-time Prep run JUST drafted is subject to the same cooldown.
            p.reprepLastServedAt = now
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
    private static func ingestContacts(_ contacts: [PrepContact], into p: Prospect, context: ModelContext) {
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
                apply(c, email: email, provenance: provenance, venue: p.venue,
                     performanceDate: p.performanceDate, excludingProspectKey: p.naturalKey, context: context, to: existing)
            } else if provenanceIsUnambiguous,
                      let existing = matchPending(in: p, provenance: provenance, formURL: c.formUrl) {
                // A corrected email for an existing pending act/presenter (or a form-only recipient
                // that just gained an email, matched by its form URL #408) updates the row in place.
                existing.id = id
                apply(c, email: email, provenance: provenance, venue: p.venue,
                     performanceDate: p.performanceDate, excludingProspectKey: p.naturalKey, context: context, to: existing)
            } else if provenanceIsUnambiguous,
                      alreadySent(in: p, provenance: provenance) {
                continue
            } else {
                let recipient = Recipient(id: id, email: email, name: c.name, role: c.role,
                                          provenance: provenance, contactMethodRaw: c.method,
                                          contactConfidenceRaw: c.confidence, contactFormURL: c.formUrl,
                                          contactSourceURL: c.sourceUrl)
                // overrideBody is only ever meaningful for a .performer recipient (#640); see apply()'s
                // matching guard for why a non-performer contact never carries one.
                recipient.overrideBody = provenance == .performer ? c.overrideBody : nil
                // #388: never second-guess a manually-added contact; Dan typed it in himself.
                if provenance != .manual {
                    recipient.looksLikeVenue = VenueContactGuard.looksLikeVenue(email: email, venue: p.venue)
                    recipient.looksLikePressContact = PressContactGuard.looksLikePressContact(email: email, role: c.role)
                    recipient.looksLikeDuplicateContact = DuplicateContactGuard.looksLikeDuplicate(
                        email: email, venue: p.venue, performanceDate: p.performanceDate,
                        excludingProspectKey: p.naturalKey, in: context)
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
                              venue: String?, performanceDate: String?, excludingProspectKey: String,
                              context: ModelContext, to r: Recipient) {
        let priorEmail = r.email
        let priorRole = r.role
        if let email { r.email = email }
        r.name = c.name ?? r.name
        r.role = c.role ?? r.role
        r.provenance = provenance
        r.contactMethodRaw = c.method ?? r.contactMethodRaw
        r.contactConfidenceRaw = c.confidence ?? r.contactConfidenceRaw
        r.contactFormURL = c.formUrl ?? r.contactFormURL
        r.contactSourceURL = c.sourceUrl ?? r.contactSourceURL
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
            if r.email != priorEmail {
                r.looksLikeVenueDismissed = false
                r.looksLikeDuplicateContactDismissed = false
            }
            r.looksLikeVenue = VenueContactGuard.looksLikeVenue(email: r.email, venue: venue)
            // #722: same reset-on-real-change convention, but role is ALSO a matching signal here,
            // so either the address or the role text changing should prompt fresh scrutiny.
            if r.email != priorEmail || r.role != priorRole { r.looksLikePressContactDismissed = false }
            r.looksLikePressContact = PressContactGuard.looksLikePressContact(email: r.email, role: r.role)
            r.looksLikeDuplicateContact = DuplicateContactGuard.looksLikeDuplicate(
                email: r.email, venue: venue, performanceDate: performanceDate,
                excludingProspectKey: excludingProspectKey, in: context)
        }
    }

    // Warm-lead detection by performer name (#751, plan #748, issue #585). Repeat-client detection has
    // only ever matched the ORG name, so a performance fronted by a performer Dan has already shot
    // scored cold whenever the group name was new. Prep is where we finally know who the performer IS.
    //
    // The production gate and the do-not-contact exclusion both live inside HistoryMatch.matchPerformer,
    // so they cannot be forgotten here.
    @MainActor
    private static func applyPerformerMatch(_ contacts: [PrepContact], to p: Prospect,
                                            clients: [DownbeatClient], history: [HistoryRecord]) {
        let production = Production(rawValue: p.production) ?? .unknown
        let current = PriorRelationship(rawValue: p.priorRelationship) ?? .none

        for c in contacts where c.provenance == "performer" {
            guard let name = c.name, !name.isEmpty else { continue }
            let verdict = HistoryMatch.matchPerformer(
                performerName: name,
                performerEmail: c.email ?? "",
                production: production,
                clients: clients,
                history: history
            )
            guard verdict.isMatch, let matchedName = verdict.matchedPerformerName else { continue }

            // "Assume it runs twice." Re-ingesting the same prep-results file must not re-fire: a second
            // pass would snapshot the ALREADY-CORRECTED values as the "previous" ones, destroying the
            // only record of what the scout originally had, and would silently un-review a finding Dan
            // already judged. Only genuinely NEW evidence, a different performer, acts. Mirrors
            // alreadyCoveredNote's "only touch when the evidence actually differs" rule (#611).
            //
            // Keyed on the recorded performer NAME, not on relationshipCorrectedByPerformerMatch:
            // dismissing a match clears that lock (#752) while keeping the name, so checking the lock
            // would let the very next ingest of the same file resurrect a match Dan had just rejected.
            if p.matchedPerformerName == matchedName { continue }

            // The upgrade-only floor, and the REAL backstop against a downgrade: the do-not-contact
            // exclusion in the matcher does not provide this, because the ordinary history path still
            // resolves declined/lost statuses perfectly well. Without this comparison, a merely-warm
            // performer match on an already-booked prospect would CUT its score.
            //
            // Compared on Ranker.priorPoints, the app's single definition of a better lead (Dan's call,
            // 2026-07-11). That ranks declined_by_you (18) above warm (10), so a performer Dan turned
            // down does count as an upgrade over an untested warm name: they know him and they wanted
            // him. Deliberate, and locked by a test.
            guard Ranker.priorPoints(verdict.relationship) > Ranker.priorPoints(current) else { continue }

            // Snapshot BEFORE mutating, so a dismissal restores exactly what the scout had rather than
            // guessing at an inverse.
            p.performerMatchPreviousRelationship = p.priorRelationship
            p.performerMatchPreviousFitScore = p.fitScore
            p.performerMatchPreviousTier = p.tier
            p.performerMatchPreviousMatchedClientName = p.matchedClientName
            p.performerMatchPreviousDownbeatClientId = p.downbeatClientId

            p.priorRelationship = verdict.relationship.rawValue
            // Only overwrite the identity fields the verdict actually carries: a history-only match
            // names no Downbeat client, and blanking the existing values would lose information.
            if let clientName = verdict.matchedClientName { p.matchedClientName = clientName }
            if let clientId = verdict.downbeatClientId { p.downbeatClientId = clientId }

            p.relationshipCorrectedByPerformerMatch = true
            p.matchedPerformerName = matchedName
            p.performerMatchNote = verdict.note
            p.performerMatchDismissed = false
            p.performerMatchReviewed = false   // a new finding Dan has not seen yet

            // rescored() reads priorRelationship straight off the prospect (it takes no relationship
            // argument), so priorRelationship MUST already be assigned above before this call.
            let refit = ClassificationOverride.rescored(p, discipline: nil, production: nil)
            p.fitScore = refit.score
            p.tier = refit.tier.rawValue
            return   // one correction per prospect; the first confident performer wins
        }
    }

    @MainActor
    static func ingestFile(at url: URL, into context: ModelContext,
                           downbeatURL: URL = DownbeatBridge.defaultURL,
                           historyURL: URL = LocalHistory.importedURL) throws -> Outcome {
        let data = try Data(contentsOf: url)
        let existing = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let loaded = DownbeatBridge.loadWithHealth(from: downbeatURL, now: Date())
        let history = LocalHistory.forMatchingWithHealth(existing: existing, importedFrom: historyURL)

        var outcome = ingest(try PrepResultsDecoder.decode(data), into: context,
                             clients: loaded.clients, history: history.records)
        // #754: the health verdict used to be computed here and then thrown away, so a missing or
        // corrupt client export meant every performer match silently found nothing and a real past
        // client read as a cold lead, with no symptom Dan could ever have noticed.
        outcome.matchDataWarning = matchDataWarning(clientHealth: loaded.health,
                                                    historyUnreadable: history.unreadable)
        return outcome
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-prep-results.json")
    }
}
