import Foundation
import SwiftData
import CryptoKit

// Ingests a Prep results file into the local store: matches each result to an existing
// prospect by natural key and fills in the found contact and the drafted email. A
// prospect that gains a draft moves to `.drafted` (ready for Dan to review/approve).
// Results with no matching prospect are skipped.

enum PrepImporter {
    // unmatchedKeys: results that matched no kept prospect (surfaced, never swallowed,
    // since the Prep run is a separate fallible process). skippedEdited: drafts left
    // untouched because Dan had hand-edited them.
    struct Outcome: Equatable, Sendable {
        // #1721: what the run spent on the web, carried through so the summary can say when a run went
        // deeper than expected. Optional: an older results file carries no count and claims nothing.
        var webCalls: PrepResults.WebCalls? = nil
        var matched = 0
        var drafted = 0
        var skippedEdited = 0
        // #2007: drafts left untouched because Dan WROTE them himself (no Prep run was ever involved).
        // Its own counter rather than a second meaning for skippedEdited above, for the same reason the
        // marker behind it is its own field: "kept your edits" would report a run preserving an edit he
        // never made to a draft no model ever wrote.
        var skippedHandWritten = 0
        var skippedRecipientEdits = 0
        // #367: the Prep run is prompt-driven, not code, so its result can carry a draft/contacts
        // update outside what the prospect's own reprep flags actually asked for (e.g. a draft
        // returned for a contacts-only request). Counts every such update the app refused to apply,
        // distinct from skippedEdited/skippedRecipientEdits (which mean Dan's own edit wins).
        var skippedOutOfScope = 0
        var unmatchedKeys: [String] = []
        // #876: the shows the app QUEUED that the run never answered. The exact mirror image of
        // unmatchedKeys (a result matching no prospect); this is a prospect matching no result.
        //
        // They keep their un-drafted state and the next run picks them up again, so nothing is lost, but
        // in silence a show the model chokes on every time is retried forever and the only symptom is a
        // Prep pill whose count never quite goes down. Self-healing is not the same as visible.
        var missingKeys: [String] = []
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
    // #1308 Layer 2: `isProbe` is passed by the CALLER, which knows whether the completed run was a
    // reachability probe from the app's own run-type state (the probe marker), rather than from a field in
    // the results file. This keeps the cross-language results contract unchanged while still giving ingest
    // the code-enforced probe safety below.
    static func ingest(_ results: PrepResults, into context: ModelContext, now: Date = Date(),
                       clients: [DownbeatClient] = [], history: [HistoryRecord] = [],
                       isProbe: Bool = false) -> Outcome {
        var outcome = Outcome()
        for r in results.results {
            let key = r.naturalKey
            let descriptor = FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })
            guard let p = (try? context.fetch(descriptor))?.first else {
                outcome.unmatchedKeys.append(key)
                continue
            }
            outcome.matched += 1

            // #1308 Layer 2: a reachability PROBE result. The safety here is a CODE gate, not a trust in
            // the model: whatever the run emitted, a probe NEVER applies a draft and NEVER changes status,
            // so a Review-stage show Dan hasn't kept can't be silently flipped to .drafted. It DOES store
            // a found contact (so a later prep can skip the hunt, #1308 Phase 4) and it ALWAYS stamps
            // reachabilityProbedAt, found or not, so the badge resolves to "email found"/"no email found"
            // instead of sticking on the free heuristic. Handled here and short-circuited so none of the
            // draft/status/reprep logic below can touch a probe row.
            if isProbe {
                p.reachabilityProbedAt = now
                if p.recipientsEditedByDan {
                    // #1596 Phase 3: Dan curated this row's recipients by hand, so the ingest below must
                    // never run and clobber them. That skip used to mean the result was never upgraded
                    // either, leaving the row reading "no email found" while carrying a contact he typed
                    // in himself, which is the strongest possible evidence there IS somebody to email.
                    // Classify from what is already on the row instead, and leave his contacts alone.
                    p.reachabilityResult = p.reachabilityResultFromRecipients
                    // #1722: a contact Dan typed in himself is the strongest possible evidence there IS
                    // somebody to email, so a refusal sentence from an earlier check must not survive it.
                    p.reachabilityEmptyReason = nil
                } else if let contacts = r.contacts, !contacts.isEmpty {
                    ingestContacts(contacts, into: p, context: context)
                    applyPerformerMatch(contacts, to: p, clients: clients, history: history, now: now)
                    // Only now have the venue and press guards run, so this is the first point at which
                    // found can be told from weak. This is the authoritative writer for a probe that
                    // landed contacts; markProbed's floor stands for one that did not.
                    p.reachabilityResult = p.reachabilityResultFromRecipients
                    // #1722: this check found something, so any earlier "only the venue's address" is now
                    // false. Cleared here rather than left to age out, because a stale refusal printed
                    // over a real address is worse than no sentence at all (L14).
                    //
                    // #2265: unless everything it found was a social profile, in which case the check
                    // reached a doorway and stopped, and saying nothing would put a bare "No email found"
                    // on a show whose address was a single fetch away. Decided from the routes the run
                    // EMITTED, never from what it said it did, because its own account of what it read
                    // cannot be trusted (#2269).
                    // #2259: asked AFTER the ingest, because the question is not what the run emitted
                    // but what survived it. A contact carrying neither an address nor a form URL is
                    // discarded here, so a run could emit two people, land nobody, and leave the card
                    // saying "No email found" about a run that had found two people. Counting the
                    // recipients this check actually left behind is what closes that door.
                    p.reachabilityEmptyReason = Reachability.emptyReason(
                        afterIngesting: contacts,
                        usableRecipients: p.recipients.filter(\.isSendablePending).count)
                } else {
                    // #1722: the run answered this show and had nothing to give. THIS is the branch the
                    // whole issue is about: before, it wrote nothing at all, markProbed's `no_email_found`
                    // floor stood, and the card said "No email found" whether the check had found the
                    // room's own inbox and refused it or found nothing anywhere.
                    //
                    // An unrecognised value is dropped rather than stored, so a newer run's vocabulary can
                    // never put a sentence on the card this build cannot explain.
                    p.reachabilityEmptyReason = r.emptyReason.flatMap(Reachability.EmptyReason.init(rawValue:))
                }
                continue
            }

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
                    // #1961: a contact that lands here changes the answer to "can this show be reached",
                    // and until now only the probe path above ever said so. A show probed on Jul 29 and
                    // given two performers by an ordinary Prep run days later kept the probe's
                    // "no email found" standing over them, while the card worked out for itself that one
                    // of them publishes a form and linked it. Three lines, three answers.
                    //
                    // Through the SAME shared definition the probe path uses, so the two can never
                    // disagree about what a set of recipients means. The empty reason goes with it for
                    // #1722's reason: a refusal sentence from an earlier check is false the moment a
                    // contact lands, and printing it over a live form is worse than saying nothing.
                    //
                    // Guarded on a verdict already standing, deliberately: every badge sentence begins
                    // "A reachability check...", so a Prep run may CORRECT what a check concluded but
                    // must never mint a verdict on a show no check has looked at (L11). Nor does it
                    // stamp reachabilityProbedAt; a Prep run is not a reachability check, and the
                    // freshness clock belongs to the check that ran.
                    if p.reachabilityResult != nil {
                        p.reachabilityResult = p.reachabilityResultFromRecipients
                        p.reachabilityEmptyReason = nil
                    }
                }
                // The warm-lead correction is derived from the RESEARCH, not from the recipient list,
                // so it still runs when Dan's curated recipients are frozen: learning that this
                // performer is a past client has nothing to do with who he chose to email. A
                // draft-only request carries no fresh contact research to trust, so it stays out.
                if !draftOnlyRequest {
                    applyPerformerMatch(contacts, to: p, clients: clients, history: history, now: now)
                }
            }
            if let d = r.draft {
                // Never overwrite a draft Dan hand-edited; his version wins until he
                // explicitly skips/dismisses it.
                // #2007: a draft Dan WROTE, checked ahead of the edit guard below. Both refuse the same
                // overwrite, but they are different facts about the text and the summary says so; a
                // hand-written draft carries no model to have edited.
                if p.draftWrittenByDan {
                    outcome.skippedHandWritten += 1
                } else if p.draftEditedByDan {
                    outcome.skippedEdited += 1
                } else if contactsOnlyRequest || draftBlockedBySend {
                    outcome.skippedOutOfScope += 1
                } else {
                    p.draftSubject = d.subject
                    p.draftBody = d.body
                    p.draftVariant = d.variant
                    // #804: stamped on the SAME branch as the text itself, so the trace can never end up
                    // describing words it did not write. A draft Dan hand-edited never reaches here (his
                    // version wins, above), so it keeps the trace of whatever wrote the text he edited.
                    p.draftModel = results.model
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
            // #1824: what the run understood this show to be, and the two are mutually exclusive on screen,
            // so whichever one arrives clears the other. A run that sends NEITHER leaves what is already
            // recorded alone: the runbook is a prompt (L27) and a silent gap is not evidence the page went
            // unreadable, so a missing field must never wipe a summary a previous run really did read.
            let summary = r.showSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let summary, !summary.isEmpty {
                p.showSummary = summary
                p.showSummaryAbsentReasonRaw = nil
            } else if let reason = r.showSummaryAbsentReason,
                      ShowSummaryAbsence(rawValue: reason) != nil {
                p.showSummary = nil
                p.showSummaryAbsentReasonRaw = reason
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

        // #2392: the addresses Dan struck before this run. Read ONCE per show rather than per contact,
        // and only when there is something to check.
        let refusals = ContactRefusal.ledger(in: context)
        let orgKey = p.presenter.flatMap { OrgKey.stored(for: $0) }

        for c in contacts {
            guard let id = Recipient.makeId(email: c.email, formURL: c.formUrl) else { continue }
            // #2392: an address Dan struck is REFUSED here, not merely dropped from the card. Removing a
            // still pending recipient hard-deletes it, and the branches below match an incoming contact
            // to a pending recipient or create one, so without this a deleted row is indistinguishable
            // from one never found and this very run would put the address straight back. That is the
            // whole thing striking it before the run exists to prevent.
            if refusals.isRefused(email: c.email, showKey: p.naturalKey, orgKey: orgKey) { continue }
            // #2421: a contact with no address whose only handle is a social profile is not a contact,
            // so it is never created rather than created for every surface downstream to explain. Dan's
            // call, 2026-08-10, on a card listing seven people he could reach one of. The app had already
            // decided these were dead ends (#1626 refuses to offer the link); this applies the same rule
            // one step earlier. A real form on the act's own site is kept: 15 shows have no other route.
            //
            // Placed AFTER the refusal check so a struck address is still refused rather than merely
            // dropped, and BEFORE every branch below so this can never update an existing row into a
            // dead end either.
            if DeadEndContact.hasNoUsableRoute(email: c.email, formURL: c.formUrl) { continue }
            let provenance = RecipientProvenance(rawValue: c.provenance ?? "") ?? .act
            let email = (c.email?.isEmpty == false) ? c.email : nil
            let provenanceIsUnambiguous = (provenanceCounts[c.provenance ?? ""] ?? 0) <= 1

            if let existing = p.recipients.first(where: { $0.id == id }) {
                apply(c, email: email, provenance: provenance, venue: p.venue,
                     performanceDate: p.performanceDate, excludingProspectKey: p.naturalKey, context: context, to: existing)
            } else if let existing = matchSamePerson(in: p, name: c.name, among: contacts) {
                // #2422: the same person, reached a second way. The id routes above cannot see this by
                // construction (an email and a `form:` URL are two different ids for one person), and the
                // provenance routes below are switched off on every multi performer show, so before this
                // the append branch was the only live branch and a re-run always duplicated rather than
                // corrected. Dan, 2026-08-10: "and I've got two of the same person."
                apply(c, email: email, provenance: provenance, venue: p.venue,
                      performanceDate: p.performanceDate, excludingProspectKey: p.naturalKey,
                      context: context, to: existing)
                // Re-keyed from what the row ENDS UP holding rather than from the incoming handle, which
                // is what makes an address beat a form: `apply` keeps the better of the two on each field,
                // so recomputing here lands on the email whenever either side had one.
                if let merged = Recipient.makeId(email: existing.email, formURL: existing.contactFormURL) {
                    existing.id = merged
                }
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
                                          // #1856: a find may claim to be verified only when it names the
                                          // page it was read off; the runbook always said so and nothing
                                          // enforced it (L27).
                                          contactConfidenceRaw: ContactConfidenceGuard.confidence(
                                              raw: c.confidence, sourceURL: c.sourceUrl),
                                          contactFormURL: c.formUrl,
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

    // #2422: an existing recipient that is the same PERSON as this incoming contact.
    //
    // Refuses on any ambiguity rather than guessing, because the failure mode of a wrong match is worse
    // than the duplicate it fixes: it would write one performer's address onto another's row.
    //
    //   - The name must fold to something (ContactIdentity.personKey), so two nameless contacts never
    //     match each other.
    //   - Exactly one existing recipient may carry that name. Two already means something has gone wrong
    //     upstream, and picking one of them would be arbitrary.
    //   - Exactly one contact in the INCOMING batch may carry it, or two payload entries would fight over
    //     one row, which is the #408 failure the provenance guard exists to prevent.
    //   - Never a manual recipient (#388: Dan typed it in, and it is not the importer's to rewrite), and
    //     never an already-sent one, whose address is locked.
    //
    // Provenance is deliberately NOT required to match. The live store held Ben Cameron as `act` on one
    // row and `performer` on the other, disagreeing about what he even is; they are still one person, and
    // `apply` settles the classification.
    private static func matchSamePerson(in p: Prospect, name: String?,
                                        among batch: [PrepContact]) -> Recipient? {
        guard let key = ContactIdentity.personKey(name) else { return nil }
        guard batch.filter({ ContactIdentity.personKey($0.name) == key }).count == 1 else { return nil }
        let candidates = p.recipients.filter {
            $0.provenance != .manual && $0.sendState == .pending
                && ContactIdentity.personKey($0.name) == key
        }
        return candidates.count == 1 ? candidates.first : nil
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
        // #2422: the BETTER of the two forms, never simply the latest. A row that already offers the act's
        // own booking page must not be downgraded to an Instagram by a later run that happened to find one,
        // which is exactly what the store held on two performers.
        r.contactFormURL = ContactIdentity.preferredFormURL(existing: r.contactFormURL, incoming: c.formUrl)
        r.contactSourceURL = c.sourceUrl ?? r.contactSourceURL
        // #1856: the same bar as a freshly appended contact, judged on the pair this ingest LEAVES
        // BEHIND. The two fields fall back independently above, so a re-run can raise a recipient to
        // high while carrying no page of its own, and only the result is the claim Dan reads.
        r.contactConfidenceRaw = ContactConfidenceGuard.confidence(raw: r.contactConfidenceRaw,
                                                                   sourceURL: r.contactSourceURL)
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
                                            clients: [DownbeatClient], history: [HistoryRecord],
                                            now: Date) {
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
            // Compared on Ranker.priorPoints, the app's single definition of a better lead. Since #1362
            // a past decline is neutral (0), not above warm (10), so a declined performer match no longer
            // overwrites a warm prospect: whether Dan declined a group before is irrelevant to a future
            // pitch. Reading the ranker's own weights keeps this honest if they are ever retuned again.
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
            let refit = ClassificationOverride.rescored(p, now: now)
            p.fitScore = refit.score
            p.tier = refit.tier.rawValue
            return   // one correction per prospect; the first confident performer wins
        }
    }

    @MainActor
    static func ingestFile(at url: URL, into context: ModelContext,
                           downbeatURL: URL = DownbeatBridge.defaultURL,
                           historyURL: URL = LocalHistory.importedURL,
                           queueURL: URL = PrepQueueBuilder.defaultURL,
                           isProbe: Bool = false, now: Date = Date()) throws -> Outcome {
        let data = try Data(contentsOf: url)
        let existing = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let loaded = DownbeatBridge.loadWithHealth(from: downbeatURL, now: now)
        let history = LocalHistory.forMatchingWithHealth(existing: existing, importedFrom: historyURL)

        var results = try PrepResultsDecoder.decode(data)
        // #1804: credit a grouped answer to the shows it was paid to cover, BEFORE the ingest, so those
        // shows go through the identical matching, guard and stamping path as an entry the run wrote itself.
        // Gated on `isProbe` because only a check ever carries a grouping, and because a normal Prep run
        // produces drafts, which must never fan out (PrepGroupCredit drops them anyway; this is the outer
        // half of that pair). A run that DID follow the runbook is unaffected: every key it answered itself
        // already wins over the credit.
        if isProbe {
            results.results = PrepGroupCredit.credited(
                results.results, groups: PrepGroupCredit.groups(queueURL: queueURL, resultsURL: url))
        }
        var outcome = ingest(results, into: context, now: now,
                             clients: loaded.clients, history: history.records, isProbe: isProbe)
        // #754: the health verdict used to be computed here and then thrown away, so a missing or
        // corrupt client export meant every performer match silently found nothing and a real past
        // client read as a cold lead, with no symptom Dan could ever have noticed.
        outcome.matchDataWarning = matchDataWarning(clientHealth: loaded.health,
                                                    historyUnreadable: history.unreadable)
        // #1721: carry the runner's own web-call count through to the summary. Set HERE rather than
        // inside ingest, beside the other run-level facts, because it describes the run and not any one
        // prospect. Without this the field would decode and then be dropped, and the note it feeds could
        // never fire in the app however green its own tests were (L3).
        outcome.webCalls = results.webCalls
        // #876: what did the app ASK for that never came back? Computed from the queue the app itself
        // wrote (never from anything the run reported about itself), through the shared handoff check
        // (#1020) so Prep and reply-classify cannot word the same rule two ways.
        outcome.missingKeys = HandoffShortfall.missingKeys(
            queueURL: queueURL, resultsURL: url, decodingQueue: PrepQueue.self,
            queuedKeys: { $0.items.map(\.naturalKey) },
            generatedAt: { $0.generatedAt },
            answeredKeys: results.results.map(\.naturalKey))
        return outcome
    }

    // #884: consume a results file exactly ONCE, and return nil for one the app has already read.
    //
    // `ingestPrep()` runs on every launch against whatever results file is still on disk, and that file is
    // never deleted. The importer is idempotent about the DATA it writes, which is why re-reading looked
    // free. It is not, in three ways, and the third is the serious one:
    //
    //   - The shortfall re-announces. "2 didn't come back, they'll be retried" reappears every launch about
    //     a run that may be days old, so the warning #876 added to make a silent failure VISIBLE becomes
    //     one Dan learns to scroll past. Same for "didn't match".
    //   - The good news re-announces. `drafted` does not settle to zero: nothing in `ingest` asks whether a
    //     prospect was already drafted, so it re-applies and re-counts every draft, every launch.
    //   - IT UN-APPROVES HIS WORK. `ingest` sends a prospect's status back to `.drafted` from `.approved`,
    //     on purpose, because a REAL redraft carries changed text that must be reviewed again (#367). But
    //     `draftBlockedBySend` only shields a prospect that has already been SENT, so an approved,
    //     not-yet-sent draft is quietly knocked back to "needs review" on the next launch. Dan approves a
    //     draft, quits, reopens, and the decision he made is gone with nothing said.
    //
    // Keyed on a fingerprint of the BYTES, not the file's modification time: an mtime we cannot read (or
    // one a copy or a restore moved) leaves us guessing, whereas the bytes are the thing we are deciding
    // about and we have to read them anyway. Two genuinely different runs cannot collide here, since each
    // writes its own `generatedAt` into the file.
    //
    // A run whose save FAILED is never marked consumed. Nothing Dan can see actually landed, so the retry
    // on the next launch is the only thing that rescues that run's work.
    // #1594: which shows a finished run actually ANSWERED, read straight off the results file. A key here
    // means the runner reached that show and reported back, whether or not it found anybody; a key absent
    // means the run never got to it (a cancel, a crash, an API failure partway through).
    //
    // Deliberately independent of consumeIfNew, which skips the ingest once a file has been consumed. The
    // reachability settle needs this answer even on a re-settle, when no ingest runs at all.
    //
    // An unreadable or unparsable file yields the empty set, which is the honest reading: nothing can be
    // shown to have been answered, so nothing is stamped and every show stays re-checkable.
    //
    // #1804: a show the app GROUPED under a lead that came back with contacts counts as answered, because
    // the lookup Dan paid for covers it. Read through the same `PrepGroupCredit.credited` the ingest uses,
    // so "answered" has ONE definition here, at the ingest, and in the shortfall Dan reads, rather than
    // three that can drift. The queue is the app's own record of the grouping; a caller that has no queue
    // to offer (a test, a path with no work-list on disk) credits nothing and gets the old behaviour.
    static func answeredKeys(at url: URL, queueURL: URL? = nil) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PrepResults.self, from: data) else { return [] }
        let groups = queueURL.map { PrepGroupCredit.groups(queueURL: $0, resultsURL: url) } ?? [:]
        return Set(PrepGroupCredit.credited(decoded.results, groups: groups).map(\.naturalKey))
    }

    // #1623: whether an ingest of this results file is still to come, asked WITHOUT consuming it.
    //
    // The reachability settle writes a pre-guard floor before the ingest and relies on the ingest to
    // upgrade it. On a re-settle no ingest runs, so the floor is the last word and a show that found an
    // address came back reading "No email found". The settle therefore has to know which of the two it is
    // in, and that is exactly the decision `consumeIfNew` makes one line later, so it is asked here rather
    // than guessed at from the row's own state (which cannot tell a stale positive from a fresh one).
    //
    // An unreadable file reads as nothing to come, which is the fail-safe direction: the settle then
    // preserves whatever the row already holds instead of overwriting it on the strength of a file it
    // could not read.
    static func hasUnconsumedResults(at url: URL = defaultURL, defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return Self.fingerprint(data) != defaults.string(forKey: consumedKey)
    }

    @MainActor
    @discardableResult
    static func consumeIfNew(at url: URL = defaultURL,
                             into context: ModelContext,
                             defaults: UserDefaults = .standard,
                             ingest: (URL, ModelContext) throws -> Outcome = {
                                 try ingestFile(at: $0, into: $1)
                             }) -> Outcome? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let fingerprint = Self.fingerprint(data)
        guard fingerprint != defaults.string(forKey: consumedKey) else { return nil }
        guard let outcome = try? ingest(url, context) else { return nil }
        if !outcome.saveFailed { defaults.set(fingerprint, forKey: consumedKey) }
        return outcome
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let consumedKey = "prep.consumedResultsFingerprint"

    static var defaultURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("overture-prep-results.json")
    }
}
