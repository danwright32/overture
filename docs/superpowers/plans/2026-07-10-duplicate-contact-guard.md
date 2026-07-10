# Duplicate Contact Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dismissible warning that fires when a contact is already being pitched on another still-open prospect for what looks like the same real-world performance (same contact, same venue, dates within 3 days), so a grouping gap that #369 didn't catch never results in two separate outreach emails to the same inbox (#726).

**Architecture:** A new pure-ish domain guard (`DuplicateContactGuard`, needs a `ModelContext` since it queries other prospects) mirrors the existing dismissible-flag pattern (`VenueContactGuard` #388, `PressContactGuard` #722) exactly: two new `Bool` fields on `Recipient`, computed fresh on every Prep ingest, gating sendability until Dan dismisses it. This design went through an independent red-team pass (`/plan-lite`) that empirically verified real SwiftData behavior and surfaced two real problems, both already fixed in this plan: emails must be compared case-insensitively (never done anywhere in this codebase today) rather than via an exact-match database predicate, and the check requires venue to also match (not just contact + date), so a legitimate touring act sharing one booking-agency contact across two different venues is never flagged.

**Tech Stack:** Swift 6, SwiftData, Swift Testing (`@Test`/`@Suite`).

## Global Constraints

- Follow test-driven development: write the failing test before the implementation in every task.
- No dashes as punctuation in any code comment or commit message (hyphens inside words like "case-insensitively" are fine; write connector phrases as separate words otherwise).
- The flag is dismissible, never a hard block: `looksLikeDuplicateContact` gates `Recipient.isSendablePending` the same way `looksLikeVenue`/`looksLikePressContact` already do, and Dan can always dismiss it.
- Fires ONLY when ALL of: same contact email (case-insensitive), same venue (case-insensitive, trimmed), performance dates within 3 days (`gapDays = 3`, mirroring `RunGrouping`), the OTHER prospect has a different `naturalKey`, and the other prospect is not closed (`Prospect.isClosed`).
- Do NOT use `#Predicate` to do the email comparison: SwiftData's `#Predicate` macro does not support calling `.lowercased()` inside the predicate closure (confirmed empirically during planning). Fetch with `FetchDescriptor<Recipient>()` (no predicate) and filter/compare in plain Swift.
- Do NOT introduce `PersistentIdentifier`/`persistentModelID` anywhere; this codebase always identifies a `Prospect` by its `naturalKey: String`.
- A manually-added recipient (`provenance == .manual`) is never second-guessed by this guard, matching how `looksLikeVenue`/`looksLikePressContact` already skip manual contacts.
- Two accepted, documented (not fixed) limitations, confirmed during planning: (1) same-batch ordering asymmetry: if two brand-new duplicate prospects arrive in the same Prep import batch, only whichever is processed later in the batch sees the earlier one and gets flagged; the one processed first correctly sees nothing yet. (2) staleness: unlike the venue/press guards (whose truth depends only on the recipient's own fields), this guard's truth depends on ANOTHER prospect's mutable state; if that other prospect later closes, this recipient's already-set flag is not automatically re-derived unless this prospect itself is independently re-ingested.

---

### Task 1: `DuplicateContactGuard` and the `Recipient` fields

**Files:**
- Create: `mac/Overture/Domain/DuplicateContactGuard.swift`
- Modify: `mac/Overture/Domain/Recipient.swift`
- Test: `mac/OvertureTests/DuplicateContactGuardTests.swift` (new)

**Interfaces:**
- Consumes: `Prospect.isClosed: Bool`, `Prospect.naturalKey: String`, `Prospect.venue: String?`, `Prospect.performanceDate: String?`, `Recipient.prospect: Prospect?`, `Recipient.email: String?` (all existing, unmodified), `EasternDate.daysUntil(from:to:) -> Int?` (existing, unmodified).
- Produces: `DuplicateContactGuard.looksLikeDuplicate(email: String?, venue: String?, performanceDate: String?, excludingProspectKey: String, in context: ModelContext) -> Bool`, consumed by Task 2. `Recipient.looksLikeDuplicateContact: Bool` and `Recipient.looksLikeDuplicateContactDismissed: Bool` (both default `false`), consumed by Task 2, Task 3, and Task 4.

- [ ] **Step 1: Write the failing tests**

Create `mac/OvertureTests/DuplicateContactGuardTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import Overture

@MainActor
@Suite("Duplicate contact guard")
struct DuplicateContactGuardTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func makeProspect(_ ctx: ModelContext, group: String, date: String?, venue: String?,
                              email: String?, closed: Bool = false) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: venue)
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: venue,
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        if closed { p.outcome = .lostHard }
        ctx.insert(p)
        if let email {
            let r = Recipient(id: email, email: email, provenance: .act)
            p.addRecipient(r)
        }
        try? ctx.save()
        return key
    }

    @Test func flagsWhenSameEmailSameVenueCloseDate() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-08", venue: "Weill Recital Hall", email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: "2026-07-09",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == true)
    }

    @Test func caseInsensitiveEmailStillMatches() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-08", venue: "Weill Recital Hall", email: "Info@Act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: "2026-07-09",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == true)
    }

    @Test func doesNotFlagWhenVenueDiffers() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-08", venue: "Weill Recital Hall", email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Carnegie Hall", performanceDate: "2026-07-09",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == false)
    }

    @Test func flagsAtExactlyTheThreeDayBoundary() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-05", venue: "Weill Recital Hall", email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: "2026-07-08",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == true)
    }

    @Test func doesNotFlagJustPastTheThreeDayBoundary() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-05", venue: "Weill Recital Hall", email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: "2026-07-09",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == false)
    }

    @Test func flagsRegardlessOfWhichDateComesFirst() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-09", venue: "Weill Recital Hall", email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: "2026-07-08",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == true)
    }

    @Test func doesNotFlagAClosedOtherProspect() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-08", venue: "Weill Recital Hall",
                    email: "info@act.example", closed: true)
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: "2026-07-09",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == false)
    }

    @Test func doesNotFlagTheSameProspectItself() throws {
        let ctx = ModelContext(try container())
        let key = makeProspect(ctx, group: "A", date: "2026-07-08", venue: "Weill Recital Hall",
                               email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: "2026-07-08",
            excludingProspectKey: key, in: ctx)
        #expect(result == false)
    }

    @Test func doesNotFlagWithNoPerformanceDate() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-08", venue: "Weill Recital Hall", email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: "info@act.example", venue: "Weill Recital Hall", performanceDate: nil,
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == false)
    }

    @Test func doesNotFlagWithNoEmail() throws {
        let ctx = ModelContext(try container())
        makeProspect(ctx, group: "A", date: "2026-07-08", venue: "Weill Recital Hall", email: "info@act.example")
        let result = DuplicateContactGuard.looksLikeDuplicate(
            email: nil, venue: "Weill Recital Hall", performanceDate: "2026-07-09",
            excludingProspectKey: "some-other-key", in: ctx)
        #expect(result == false)
    }
}
```

Also add this test to `mac/OvertureTests/RecipientTests.swift`, inside the `RecipientTests` struct, near `provenanceAndSendStateRoundTripThroughRawStrings`:

```swift
    @Test func looksLikeDuplicateContactDefaultsToFalse() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.looksLikeDuplicateContact == false)
        #expect(r.looksLikeDuplicateContactDismissed == false)
    }

    @Test func aRecipientFlaggedAsDuplicateIsNotSendableUntilDismissed() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.looksLikeDuplicateContact = true
        #expect(r.isSendablePending == false)
        r.looksLikeDuplicateContactDismissed = true
        #expect(r.isSendablePending == true)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/DuplicateContactGuardTests`
Expected: build failure, `DuplicateContactGuard` does not exist yet.

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/RecipientTests`
Expected: build failure, `looksLikeDuplicateContact`/`looksLikeDuplicateContactDismissed` do not exist on `Recipient` yet.

- [ ] **Step 3: Create `DuplicateContactGuard.swift`**

Create `mac/Overture/Domain/DuplicateContactGuard.swift`:

```swift
import Foundation
import SwiftData

// #726: a narrow safety net for #369's grouping, the SAME real-world performance somehow still
// producing two separate Prospect rows (grouping's title/venue/date matching didn't merge them).
// Fires only when contact, venue, AND date all agree, deliberately narrower than "this contact is
// pitched elsewhere soon": a shared contact at a genuinely DIFFERENT venue (e.g. a touring act's
// shared booking-agency inbox pitching two different upcoming shows) is legitimate and never
// flagged. Unlike VenueContactGuard/PressContactGuard (pure functions), this needs a ModelContext
// since it looks across OTHER prospects, not just this recipient's own fields.
enum DuplicateContactGuard {
    private static let gapDays = 3  // mirrors RunGrouping's own window (#369)

    // #Predicate cannot call .lowercased() inside its closure, so the email/venue comparison is
    // done in plain Swift after an unfiltered fetch, not via a predicate.
    static func looksLikeDuplicate(email: String?, venue: String?, performanceDate: String?,
                                   excludingProspectKey: String, in context: ModelContext) -> Bool {
        guard let email, !email.isEmpty, let venue, !venue.isEmpty, let performanceDate else { return false }
        let targetEmail = canon(email)
        let targetVenue = canon(venue)
        guard let allRecipients = try? context.fetch(FetchDescriptor<Recipient>()) else { return false }
        return allRecipients.contains { r in
            guard let rEmail = r.email, canon(rEmail) == targetEmail,
                  let p = r.prospect, p.naturalKey != excludingProspectKey, !p.isClosed,
                  let pVenue = p.venue, canon(pVenue) == targetVenue,
                  let otherDate = p.performanceDate,
                  let gap = EasternDate.daysUntil(from: otherDate, to: performanceDate)
            else { return false }
            return abs(gap) <= gapDays
        }
    }

    private static func canon(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespaces)
    }
}
```

- [ ] **Step 4: Add the two fields to `Recipient`**

In `mac/Overture/Domain/Recipient.swift`, add these two fields right after `looksLikePressContactDismissed`:

```swift
    // #722: same shape as looksLikeVenue above, for the runbook's separate press/media-disqualify
    // rule (#635); a heuristic guess (PressContactGuard), dismissible for the same reason.
    var looksLikePressContact: Bool = false
    var looksLikePressContactDismissed: Bool = false

    // #726: a heuristic guess (DuplicateContactGuard) that this contact is already being pitched
    // on another still-open prospect for what looks like the same real-world performance, a
    // safety net for #369's grouping. Dismissible for the same reason as the two flags above.
    var looksLikeDuplicateContact: Bool = false
    var looksLikeDuplicateContactDismissed: Bool = false
```

Update `isSendablePending`:

```swift
    var isSendablePending: Bool {
        sendState == .pending && (email?.isEmpty == false) && !pausedByReply
            && (prospect?.draftNeedsSalutationReview != true || prospect?.isSalutationReviewOverridden == true)
            && !(looksLikeVenue && !looksLikeVenueDismissed)
            && !(looksLikePressContact && !looksLikePressContactDismissed)
            && !(looksLikeDuplicateContact && !looksLikeDuplicateContactDismissed)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/DuplicateContactGuardTests`
Expected: `** TEST SUCCEEDED **`. Grep the output for all 10 test names to confirm they actually ran.

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/RecipientTests`
Expected: `** TEST SUCCEEDED **`. Grep for `looksLikeDuplicateContactDefaultsToFalse` and `aRecipientFlaggedAsDuplicateIsNotSendableUntilDismissed` to confirm they ran.

- [ ] **Step 6: Run the full Swift suite**

Run: `cd "mac" && ./scripts/run-tests-locked.sh`
Expected: all tests pass, no regressions.

- [ ] **Step 7: Commit**

```bash
git add mac/Overture/Domain/DuplicateContactGuard.swift mac/Overture/Domain/Recipient.swift mac/OvertureTests/DuplicateContactGuardTests.swift mac/OvertureTests/RecipientTests.swift
git commit -m "Add DuplicateContactGuard and its dismissible flag on Recipient (#726)"
```

---

### Task 2: Wire the guard into `PrepImporter`

**Files:**
- Modify: `mac/Overture/Persistence/PrepImporter.swift`
- Test: `mac/OvertureTests/PrepImporterTests.swift`

**Interfaces:**
- Consumes: `DuplicateContactGuard.looksLikeDuplicate(email:venue:performanceDate:excludingProspectKey:in:) -> Bool` (Task 1), `Recipient.looksLikeDuplicateContact`/`looksLikeDuplicateContactDismissed` (Task 1).
- Produces: no new public interface; `ingestContacts`/`apply` gain new parameters but stay `private`, called only from within this same file.

- [ ] **Step 1: Write the failing tests**

Add these to `mac/OvertureTests/PrepImporterTests.swift`, inside `PrepImporterTests`, near `reIngestUpsertsTheSameContactInPlace`:

```swift
    // #726: a contact already pitched on another still-open prospect for what looks like the
    // same real-world performance (same contact, same venue, close date) gets flagged on ingest.
    @Test func flagsAContactAlreadyPitchedForANearbyPerformanceAtTheSameVenue() throws {
        let ctx = ModelContext(try container())
        _ = keptProspect(ctx, group: "Golden Awards", date: "2026-07-08", venue: "Weill Recital Hall")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: Prospect.makeNaturalKey(groupName: "Golden Awards", performanceDate: "2026-07-08", venue: "Weill Recital Hall"),
                       contacts: [PrepContact(name: nil, role: nil, email: "info@ceremony.example",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act")])
        ]), into: ctx)

        let key2 = keptProspect(ctx, group: "Golden Awards Guest Artist Night", date: "2026-07-09", venue: "Weill Recital Hall")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "later", results: [
            PrepResult(naturalKey: key2,
                       contacts: [PrepContact(name: nil, role: nil, email: "info@ceremony.example",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act")])
        ]), into: ctx)

        let p2 = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key2 })).first
        #expect(p2?.recipients.first?.looksLikeDuplicateContact == true)
    }

    // #726: two different, un-related recipients within the SAME prospect sharing an email
    // (unusual, but not this guard's concern) must never flag each other; the exclusion is by
    // prospect naturalKey, not by recipient id.
    @Test func doesNotFlagTwoRecipientsOnTheSameProspectSharingAnEmail() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Aurora Strings", date: "2026-07-08", venue: "Carnegie Hall")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma", role: nil, email: "shared@act.example",
                            method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act"),
                PrepContact(name: "Lou", role: nil, email: "shared@act.example",
                            method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "presenter"),
            ])
        ]), into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.count == 2)
        #expect(p?.recipients.allSatisfy { $0.looksLikeDuplicateContact == false } == true)
    }

    // #726: a re-run that CORRECTS the email must reset a previously-set dismissal, mirroring the
    // existing looksLikeVenueDismissed reset-on-real-change convention.
    @Test func reIngestResetsDuplicateDismissalWhenEmailActuallyChanges() throws {
        let ctx = ModelContext(try container())
        _ = keptProspect(ctx, group: "Golden Awards", date: "2026-07-08", venue: "Weill Recital Hall")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: Prospect.makeNaturalKey(groupName: "Golden Awards", performanceDate: "2026-07-08", venue: "Weill Recital Hall"),
                       contacts: [PrepContact(name: nil, role: nil, email: "info@ceremony.example",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act")])
        ]), into: ctx)

        let key2 = keptProspect(ctx, group: "Golden Awards Guest Artist Night", date: "2026-07-09", venue: "Weill Recital Hall")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "later", results: [
            PrepResult(naturalKey: key2,
                       contacts: [PrepContact(name: nil, role: nil, email: "info@ceremony.example",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act")])
        ]), into: ctx)
        let p2 = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key2 })).first
        p2?.recipients.first?.looksLikeDuplicateContactDismissed = true
        try ctx.save()

        // A later run corrects the email to a genuinely different address.
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "even later", results: [
            PrepResult(naturalKey: key2,
                       contacts: [PrepContact(name: nil, role: nil, email: "new@ceremony.example",
                                              method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act")])
        ]), into: ctx)

        let after = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key2 })).first
        #expect(after?.recipients.first?.looksLikeDuplicateContactDismissed == false)
    }

    // #726: same-batch ordering asymmetry, an accepted, documented limitation. When two brand-new
    // duplicate prospects arrive together in ONE Prep results batch, only whichever is LATER in
    // the batch's results array sees the earlier one already inserted and gets flagged; the first
    // one processed correctly sees nothing yet, since it hasn't been inserted at that point.
    @Test func onlyTheLaterProspectInTheSameBatchGetsFlagged() throws {
        let ctx = ModelContext(try container())
        let key1 = keptProspect(ctx, group: "Golden Awards", date: "2026-07-08", venue: "Weill Recital Hall")
        let key2 = keptProspect(ctx, group: "Golden Awards Guest Artist Night", date: "2026-07-09", venue: "Weill Recital Hall")

        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key1, contacts: [PrepContact(name: nil, role: nil, email: "info@ceremony.example",
                                                                method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act")]),
            PrepResult(naturalKey: key2, contacts: [PrepContact(name: nil, role: nil, email: "info@ceremony.example",
                                                                method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act")]),
        ]), into: ctx)

        let p1 = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key1 })).first
        let p2 = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key2 })).first
        #expect(p1?.recipients.first?.looksLikeDuplicateContact == false)
        #expect(p2?.recipients.first?.looksLikeDuplicateContact == true)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/PrepImporterTests`
Expected: build failure or assertion failure. `looksLikeDuplicateContact` is never set to `true` by anything yet, since `PrepImporter` doesn't call `DuplicateContactGuard` yet.

- [ ] **Step 3: Wire the guard into `PrepImporter.swift`**

Change `ingestContacts`'s signature and its call site in `ingest`:

```swift
            if let contacts = r.contacts, !contacts.isEmpty {
                if p.recipientsEditedByDan {
                    // Dan curated the recipient list; a re-run never clobbers it (a freeze separate
                    // from the draft freeze below, so the body redraft still flows).
                    outcome.skippedRecipientEdits += 1
                } else {
                    ingestContacts(contacts, into: p, context: context)
                }
            }
```

```swift
    @MainActor
    private static func ingestContacts(_ contacts: [PrepContact], into p: Prospect, context: ModelContext) {
```

Change the new-recipient branch inside `ingestContacts`:

```swift
                // #388: never second-guess a manually-added contact; Dan typed it in himself.
                if provenance != .manual {
                    recipient.looksLikeVenue = VenueContactGuard.looksLikeVenue(email: email, venue: p.venue)
                    recipient.looksLikePressContact = PressContactGuard.looksLikePressContact(email: email, role: c.role)
                    recipient.looksLikeDuplicateContact = DuplicateContactGuard.looksLikeDuplicate(
                        email: email, venue: p.venue, performanceDate: p.performanceDate,
                        excludingProspectKey: p.naturalKey, in: context)
                }
```

Change both `apply(...)` call sites inside `ingestContacts` (the "existing" branch and the "matchPending" branch):

```swift
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
```

Change `apply`'s own signature and body:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/PrepImporterTests`
Expected: `** TEST SUCCEEDED **`. Grep the output for all 4 new test names, plus a handful of pre-existing ones (e.g. `fillsContactAndDraftAndMarksDrafted`, `reIngestUpsertsTheSameContactInPlace`) to confirm the whole suite, not just the new tests, actually ran and passed.

- [ ] **Step 5: Run the full Swift suite**

Run: `cd "mac" && ./scripts/run-tests-locked.sh`
Expected: all tests pass, no regressions. This is the step most likely to surface a compile error from a missed call site, since `ingestContacts` and `apply` both changed signature; if the build fails here, find every remaining call site with `grep -n "ingestContacts(\|apply(c," mac/Overture/Persistence/PrepImporter.swift` and update it to match the new signatures above.

- [ ] **Step 6: Commit**

```bash
git add mac/Overture/Persistence/PrepImporter.swift mac/OvertureTests/PrepImporterTests.swift
git commit -m "Wire DuplicateContactGuard into PrepImporter (#726)"
```

---

### Task 3: `RecipientSnapshot` mapping

**Files:**
- Modify: `mac/Overture/UI/QueueView+Model.swift`
- Test: `mac/OvertureTests/QueueItemSnapshotTests.swift`

**Interfaces:**
- Consumes: `Recipient.looksLikeDuplicateContact`/`looksLikeDuplicateContactDismissed` (Task 1).
- Produces: `RecipientSnapshot.looksLikeDuplicateContact`/`looksLikeDuplicateContactDismissed: Bool` (both default `false`), consumed by Task 4.

- [ ] **Step 1: Write the failing test**

Extend the existing `queueItemCarriesEachContactsOwnConfidenceMethodFormURLAndSourceURL` test in `mac/OvertureTests/QueueItemSnapshotTests.swift` (added during #363; do not write a new test function, extend this one, since it already builds a `Recipient` and reads it back through `QueueItem`):

Find:
```swift
        let act = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act,
                            contactMethodRaw: "named_decision_maker", contactConfidenceRaw: "high",
                            contactFormURL: "https://x.example/contact", contactSourceURL: "https://act.example/about/staff")
        p.setRecipients([act])

        let item = QueueItem(p)
        let a = item.contacts.first
        #expect(a?.contactMethod == .namedDecisionMaker)
        #expect(a?.contactConfidence == .high)
        #expect(a?.contactFormURL == "https://x.example/contact")
        #expect(a?.contactSourceURL == "https://act.example/about/staff")
    }
```

Replace with:
```swift
        let act = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act,
                            contactMethodRaw: "named_decision_maker", contactConfidenceRaw: "high",
                            contactFormURL: "https://x.example/contact", contactSourceURL: "https://act.example/about/staff")
        act.looksLikeDuplicateContact = true
        p.setRecipients([act])

        let item = QueueItem(p)
        let a = item.contacts.first
        #expect(a?.contactMethod == .namedDecisionMaker)
        #expect(a?.contactConfidence == .high)
        #expect(a?.contactFormURL == "https://x.example/contact")
        #expect(a?.contactSourceURL == "https://act.example/about/staff")
        #expect(a?.looksLikeDuplicateContact == true)
        #expect(a?.looksLikeDuplicateContactDismissed == false)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/QueueItemSnapshotTests`
Expected: build failure, `RecipientSnapshot` has no member `looksLikeDuplicateContact` yet, and `Recipient` has no such settable member either until Task 1's changes are in place (they already are, from Task 1; the failure here is purely that `RecipientSnapshot` doesn't expose it yet).

- [ ] **Step 3: Add the fields to `RecipientSnapshot` and its mapping**

In `mac/Overture/UI/QueueView+Model.swift`, add the two fields right after `looksLikePressContactDismissed`:

```swift
    // #722: same shape, for a suspected press/media contact.
    var looksLikePressContact: Bool = false
    var looksLikePressContactDismissed: Bool = false
    // #726: same shape, for a contact already pitched on another still-open prospect for what
    // looks like the same real-world performance.
    var looksLikeDuplicateContact: Bool = false
    var looksLikeDuplicateContactDismissed: Bool = false
```

Replace the whole `init(_ r: Recipient)` function (currently at `mac/Overture/UI/QueueView+Model.swift:558-580`) with:

```swift
    init(_ r: Recipient) {
        self.init(id: r.id, name: r.name, email: r.email, role: r.role,
                  provenance: r.provenance, sendState: r.sendState, replied: r.replied,
                  lastReplyText: r.lastReplyText, resolution: r.resolution,
                  bounced: r.bounced, outcomeSource: r.outcomeSource,
                  suppressionReason: r.suppressionReason,
                  replyDraftSubject: r.replyDraftSubject, replyDraftBody: r.replyDraftBody,
                  replyDraftRequestedAt: r.replyDraftRequestedAt, intentHint: r.intentHint,
                  replyDraftEditedByDan: r.replyDraftEditedByDan,
                  overrideBody: r.overrideBody,
                  conversationState: r.conversationState,
                  conversationStateSource: r.conversationStateSource,
                  conversationRemindedAt: r.conversationRemindedAt,
                  contactConfidence: r.contactConfidence,
                  contactMethod: r.contactMethod,
                  contactFormURL: r.contactFormURL,
                  contactSourceURL: r.contactSourceURL,
                  delayNoticeAt: r.delayNoticeAt,
                  looksLikeVenue: r.looksLikeVenue,
                  looksLikeVenueDismissed: r.looksLikeVenueDismissed,
                  looksLikePressContact: r.looksLikePressContact,
                  looksLikePressContactDismissed: r.looksLikePressContactDismissed,
                  looksLikeDuplicateContact: r.looksLikeDuplicateContact,
                  looksLikeDuplicateContactDismissed: r.looksLikeDuplicateContactDismissed)
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/QueueItemSnapshotTests`
Expected: `** TEST SUCCEEDED **`. Grep for `queueItemCarriesEachContactsOwnConfidenceMethodFormURLAndSourceURL` to confirm it ran.

- [ ] **Step 5: Run the full Swift suite**

Run: `cd "mac" && ./scripts/run-tests-locked.sh`
Expected: all tests pass, no regressions.

- [ ] **Step 6: Commit**

```bash
git add mac/Overture/UI/QueueView+Model.swift mac/OvertureTests/QueueItemSnapshotTests.swift
git commit -m "Map looksLikeDuplicateContact onto RecipientSnapshot (#726)"
```

---

### Task 4: UI wiring

**Files:**
- Modify: `mac/Overture/UI/DraftReviewView.swift`
- Modify: `mac/Overture/UI/ProspectMutations.swift`
- Modify: `mac/Overture/UI/ProspectRowView.swift`
- Modify: `mac/Overture/UI/ProspectRowFactory.swift`

**Interfaces:**
- Consumes: `RecipientSnapshot.looksLikeDuplicateContact`/`looksLikeDuplicateContactDismissed` (Task 3).
- Produces: no new interface consumed elsewhere; this is the leaf UI wiring.

This task has no new tests, matching this codebase's established convention (confirmed during #363's equivalent UI-wiring task): the decision logic it displays is already fully tested in Tasks 1 through 3, and this task is pure wiring of an already-tested `Bool` through existing, already-tested plumbing (`ProspectMutations.updateRecipient`, the existing `recipientWarning` SwiftUI helper).

- [ ] **Step 1: Add the warning row and dismiss closure to `DraftReviewView.swift`**

Add a new closure parameter near `onDismissPressContactMatch`:

```swift
    var onDismissVenueMatch: (_ recipientId: String) -> Void = { _ in }
    var onDismissPressContactMatch: (_ recipientId: String) -> Void = { _ in }
    var onDismissDuplicateContactMatch: (_ recipientId: String) -> Void = { _ in }
```

Add `duplicateContactWarnings` to the view's body, right after `pressContactWarnings`:

```swift
            venueMatchWarnings
            pressContactWarnings
            duplicateContactWarnings
```

Add the computed view right after `pressContactWarnings`:

```swift
    // #726: same shape as venueMatchWarnings/pressContactWarnings above, for a contact already
    // pitched on another still-open prospect for what looks like the same real-world performance.
    @ViewBuilder private var duplicateContactWarnings: some View {
        recipientWarning(item.contacts.filter { $0.looksLikeDuplicateContact && !$0.looksLikeDuplicateContactDismissed },
                        message: { "\($0.displayName) may already be pitched for a nearby show; blocked from sending." },
                        dismissLabel: "Not a duplicate", onDismiss: onDismissDuplicateContactMatch)
    }
```

- [ ] **Step 2: Add `dismissDuplicateContactMatch` to `ProspectMutations.swift`**

Add right after `dismissPressContactMatch`:

```swift
    // #722: same shape as dismissVenueMatch above, for a suspected press/media contact.
    static func dismissPressContactMatch(_ item: QueueItem, _ recipientId: String,
                                         prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.looksLikePressContactDismissed = true }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // #726: Dan judged a specific "looks like a duplicate outreach" heuristic guess to be wrong
    // for this one contact, unblocking it from sending.
    static func dismissDuplicateContactMatch(_ item: QueueItem, _ recipientId: String,
                                             prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.looksLikeDuplicateContactDismissed = true }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }
```

- [ ] **Step 3: Thread the closure through `ProspectRowView.swift`**

Add the parameter near `onDismissPressContactMatch`:

```swift
    var onDismissVenueMatch: (_ recipientId: String) -> Void = { _ in }
    var onDismissPressContactMatch: (_ recipientId: String) -> Void = { _ in }
    var onDismissDuplicateContactMatch: (_ recipientId: String) -> Void = { _ in }
```

Pass it through to `DraftReviewView` in the `body`:

```swift
                    onDismissVenueMatch: onDismissVenueMatch,
                    onDismissPressContactMatch: onDismissPressContactMatch,
                    onDismissDuplicateContactMatch: onDismissDuplicateContactMatch,
```

- [ ] **Step 4: Wire it in `ProspectRowFactory.swift`**

Add right after the `onDismissPressContactMatch` line:

```swift
            onDismissVenueMatch: { rid in ProspectMutations.dismissVenueMatch(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onDismissPressContactMatch: { rid in ProspectMutations.dismissPressContactMatch(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onDismissDuplicateContactMatch: { rid in ProspectMutations.dismissDuplicateContactMatch(item, rid, prospects: prospects, context: context, feedback: feedback) },
```

- [ ] **Step 5: Build and run the full Swift suite**

Run: `cd "mac" && xcodegen generate && ./scripts/run-tests-locked.sh`
Expected: build succeeds, all tests pass (this task adds no new tests, so this is a regression check).

- [ ] **Step 6: Commit**

```bash
git add mac/Overture/UI/DraftReviewView.swift mac/Overture/UI/ProspectMutations.swift mac/Overture/UI/ProspectRowView.swift mac/Overture/UI/ProspectRowFactory.swift
git commit -m "Show the duplicate-contact warning on the review card (#726)"
```

---

### Task 5: Full repo verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `cd "mac" && ./scripts/run-tests-locked.sh`
Expected: all tests pass.

- [ ] **Step 2: Confirm git status**

Run: `git status` and `git log --oneline -5`
Expected: four commits (Tasks 1 through 4, one per task) on the current branch, working tree clean.
