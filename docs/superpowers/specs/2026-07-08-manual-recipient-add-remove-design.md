# Manual add/remove recipient UI design (#399)

## Problem

Overture's contact-finder (the Prep run) picks recipients for a show automatically, but it
sometimes misses one, or Dan wants to add a contact it couldn't find, or stop pursuing a
contact he added by mistake. Today there is no way to do either: the per-contact "Contacts"
section in `DraftReviewView` only appears once a show has been sent at least once
(`conversationContactsSection`, gated `if item.isSent && !item.contacts.isEmpty`), and even
then it has no add or remove control, only outcome marking (In conversation / Booked /
Closed-not-now / Closed-no / Bounced, via the existing "Mark…" menu).

Issue #399 was narrowed 2026-07-04: the per-recipient status/provenance display already
shipped. What's left is genuinely editing the recipient list by hand.

## Scope

In scope:
- A manual add-a-contact control, working both before and after the first send.
- A remove control, working both before and after the first send, with different underlying
  behavior depending on whether that recipient has ever been emailed.
- A non-blocking confirmation notice on add, including an informational duplicate-org and
  venue-domain heads-up when relevant.
- Fixing `DraftReviewView`'s Approve-button gate, which currently checks a legacy singular
  `Prospect` field slated for deletion by a separate in-flight milestone.

Out of scope (deliberately, per Dan's decisions below):
- Any daily send cap / throttle system. None exists today; #399's original "throttle cost"
  language does not become a real feature here.
- Blocking a manual add for any reason (venue, duplicate org, or otherwise). Automated
  Prep contact-finding keeps its hard venue/press disqualify rules
  ([[overture-contact-targeting-ladder]]); the manual path never does.
- A curated venue-name-to-domain map (#342/#388). This spec uses a lightweight heuristic
  instead; a real map, if built later, is a drop-in improvement to the same check.

## Decisions locked with Dan (2026-07-08, via feature-discovery + grilling interview)

1. **Both stages.** The recipient list is visible and editable before the first send, not just
   after. `conversationContactsSection`'s `item.isSent` gate is removed.
2. **Remove semantics depend on history.** A never-sent recipient is truly deleted (matches
   `Prospect.removeRecipient`'s existing behavior, nothing is lost). An already-sent recipient
   is never deleted; "Remove" stops future follow-ups/reminders without recording it as a
   decline, so reply/decline stats stay honest. This is a NEW action, distinct from the
   existing "Closed (not now)" mark (which does mean a real decline).
3. **Add form: email + optional name.** No role field. Email is required and validated; name is
   optional and affects the greeting (`Salutation.greeting`).
4. **Notice reuses the existing banner.** The `ActionFeedback`/`ActionAck` bottom banner
   already used elsewhere in the app, not a new UI component. The add already happened by the
   time the banner shows; nothing about it blocks.
5. **Exact-duplicate handling.** Adding an email that matches an already-ACTIVE recipient is
   blocked (told, not silently ignored, no new row created). Adding an email that matches a
   previously-removed/suppressed recipient RESUMES pursuing them instead of creating a
   duplicate row.
6. **Two informational flags, never blocking:** a duplicate-org heads-up (the new email shares
   a domain with another existing recipient on this show) and a venue-domain heads-up (the new
   email's domain looks like the venue's).
7. **No throttle framing.** The banner states the total recipient count on the show after the
   add; no cap/quota concept.
8. **Remove for a sent recipient lives in the existing Mark menu**, as a 6th option, not a
   separate UI element.

## Data model

`RecipientSuppressionReason` (`mac/Overture/Domain/Recipient.swift`) gains a third case:

```swift
enum RecipientSuppressionReason: String, Codable, CaseIterable, Sendable {
    case bookedElsewhere, declined, removedByDan
}
```

Removing an already-sent recipient sets `sendState = .suppressed` and
`suppressionReason = .removedByDan`, touching nothing else on the row (no `resolution`, no
`outcomeSource` change), deliberately distinct from a decline, so stats stay honest.

No other new persisted fields. The add path uses the existing `Recipient` initializer with
`provenance: .manual`, `role: nil`, `contactMethodRaw`/`contactConfidenceRaw`/`contactFormURL`
all `nil` (not applicable to a manual add). `Recipient.makeId(email:formURL:)`, which delegates
to `ReplyDetection.email(from:)` (confirmed to lowercase and trim), remains the identity used
for duplicate detection, so "the same person typed differently" (capitalization, stray spaces)
is still caught correctly.

## The duplicate / venue-domain check

A new pure, SwiftUI/SwiftData-free calculator, mirroring the existing style of
`ConversationReminder`/`FollowUp`:

```swift
// mac/Overture/Domain/ManualRecipientCheck.swift
enum ManualRecipientCheck {
    enum Action: Equatable {
        case create                      // no conflict, add a fresh Recipient
        case resume(existing: Recipient) // matches a previously-removed/suppressed recipient
        case blocked(existing: Recipient) // matches an already-active recipient
    }
    struct Result: Equatable {
        let action: Action
        let sharesOrgWith: Recipient?    // duplicate-org flag, nil if none
        let looksLikeVenue: Bool         // venue-domain flag
    }
    static func evaluate(email: String, existingRecipients: [Recipient], venue: String?) -> Result
}
```

- **Exact match**: canonicalize the typed email the same way `Recipient.makeId` does; compare
  against every existing recipient's `id`. `.blocked` when the match is still active and
  unresolved (`sendState != .suppressed && resolution == nil`) or when the show is already
  settled through that contact (`resolution == .booked`) or suppressed because another contact
  got the booking (`suppressionReason == .bookedElsewhere`), none of which make sense to
  re-pursue. `.resume` for every other match: `suppressionReason == .removedByDan`,
  `suppressionReason == .declined` (an untried contact swept up when the show closed via a
  decline, `Prospect.suppressUntriedRecipients(reason: .declined)`), or
  `resolution == .declinedSoft`/`.declinedHard` (an engaged contact who personally declined).
  All four are cases where pursuit stopped while the outcome was still genuinely open (a decline
  leaves the door open, unlike a booking), so re-adding is Dan explicitly deciding to try again.
- **Duplicate-org**: any OTHER existing recipient (not the exact match case) sharing the new
  email's domain (case-insensitive).
- **Venue-domain**: strip common venue words from `venue`, reusing `VenueParser.venueWords`
  (`Hall`, `Theatre`, `Theater`, `Center`, `Centre`, `Auditorium`, `Church`, `Cathedral`,
  `Chapel`, `Park`, `Museum`, `Library`, `Playhouse`) so the two checks share one vocabulary,
  then check whether any remaining word longer than 3 characters appears in the email's domain.
  This is a heuristic, not a lookup: it can false-positive (an unrelated org whose name happens
  to share a word with the venue) or false-negative (a venue whose real domain doesn't
  resemble its display name at all). Both are acceptable because the result is ALWAYS
  advisory (decision 6): Dan sees it and decides, nothing is blocked or auto-corrected on the
  strength of it. A future curated venue map (#342) can replace the heuristic without changing
  this function's signature.

## UI (`DraftReviewView.swift`)

- `conversationContactsSection` drops its `item.isSent` gate and always renders once there is
  at least one recipient (or shows a brief empty state when there are none yet).
- Each row's remove control depends on that recipient's `sendState`: `.pending` gets a small
  inline delete affordance; `.sent` gets a 6th "Remove" item added to the existing Mark menu.
  Both call the SAME mutation entry point on `Prospect` (e.g. `removeOrSuppressRecipient(id:)`),
  which branches delete-vs-suppress internally by reading the recipient's current state, so the
  view layer never has to know which behavior applies.
- A new "+ Add contact" button below the list opens a small popover (same pattern
  `FollowUpsView` already uses for its settings popover: `showSettings` state +
  `.popover(isPresented:)`) with two fields, email and optional name, and an Add button. On
  submit, calls `ManualRecipientCheck.evaluate`, then either creates a `Recipient` (banner:
  added + count + any flags), resumes an existing one (banner: resumed), or is blocked (banner:
  already on the list) per decision 5.
- **Incidental fix, done here since the code is already being touched**: the Approve button's
  `.disabled(item.contactEmail == nil)` (line ~218) currently gates on the legacy singular
  `Prospect.contactEmail` field, which the separate in-flight per-recipient-conversation-state
  milestone (#650-654) is slated to delete. Repointing this at whether at least one recipient
  has a usable contact path (mirroring `Recipient.isSendablePending`'s existing "has a real
  email and is still pending" check, or is already sent) avoids adding a new dependency on a
  field already marked for removal.

## Notices

New `ActionAck` strings (`mac/Overture/App/ActionFeedback.swift`), following the file's existing
pattern of one static function per acknowledgment:

- `recipientAdded(name:org:totalCount:warnings:)`: e.g. "Added Jane Doe. 3 recipients on Aurora
  Strings now." with any flags appended as a plain sentence.
- `recipientAlreadyExists(name:org:)`
- `recipientResumed(name:org:)`
- `recipientRemoved(name:org:)`

## Testing

- `ManualRecipientCheckTests.swift` (new): exact-duplicate-active blocks, exact-duplicate on a
  `.removedByDan`-suppressed match resumes, exact-duplicate on a `.declinedSoft`/`.declinedHard`
  resolution resumes, exact-duplicate on a `.booked` resolution or `.bookedElsewhere`
  suppression stays blocked, org-duplicate flags, venue-domain flags across a few real
  venue-name shapes (a venue-word-suffixed name, a bare proper noun with no venue word, a
  multi-word name), a clean add with no flags.
- `Prospect`/`Recipient` mutation tests (new or extending an existing file): the remove entry
  point deletes a `.pending` recipient and leaves no trace; suppresses a `.sent` recipient with
  `suppressionReason == .removedByDan` and touches neither `resolution` nor `outcomeSource`; a
  fresh add on a suppressed match flips it back to pursuable.
- `ActionAck` tests for the four new message strings, matching the file's existing per-message
  test coverage.
- `DraftReviewView` itself isn't unit-tested directly in this suite (SwiftUI views aren't); this
  gets verified by building the app and driving it live, same as any UI change here.
