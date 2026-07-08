# Manual add/remove recipient UI (#399) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Dan add or remove a recipient by hand on any show, before or after the first send, with a non-blocking confirmation and informational duplicate/venue-domain flags.

**Architecture:** Mac-app-only. A new pure calculator (`ManualRecipientCheck`) decides create/resume/blocked plus two informational flags, independent of SwiftUI/SwiftData. A new `Prospect` method branches delete-vs-suppress by the recipient's current send state. Two new `ProspectMutations` functions wire the calculator and the branch into the existing SwiftData model, reusing the existing `ActionFeedback` banner. `DraftReviewView`'s per-contact section stops being gated to post-send-only and gains an add popover and remove controls.

**Tech Stack:** Swift, SwiftUI, SwiftData, Swift Testing, xcodegen, xcodebuild.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-08-manual-recipient-add-remove-design.md`. Read it before starting if anything below is unclear; it is the source of truth for product decisions.
- Mac-app-only. Do NOT touch `scripts/` or `src/`.
- Branch: `399-manual-recipient-ui` (already created, spec doc already committed there). Continue on this branch.
- No em dashes, en dashes, or emoji in any code comment, commit message, or UI copy (repo-wide style rule, enforced by a pre-push hook).
- After adding any NEW `.swift` file: `cd mac && xcodegen generate` before building.
- Test command: `./mac/scripts/run-tests-locked.sh` from the repo root (never raw `xcodebuild test`, it wraps the run in a lock so it cannot collide with another test run on this Mac). Full suite only; there is no reliable per-suite scoped run in this repo (a scoped `-only-testing` filter can silently match zero tests and still report success).
- Manual adds are NEVER blocked for the venue/org reasons; only an exact-duplicate match to an already-active or already-settled contact blocks (see Task 3).
- `DraftReviewView`'s top-level `contactLine` (lines 61-90, showing `item.contactName`/`contactRole`/`contactEmail`/`contactFormURL`) is OUT OF SCOPE. It reads the same legacy `Prospect` singular fields the separate in-flight milestone (#650-654) is slated to delete, but rewriting it is that milestone's job, not this one. Do not touch it here.

---

### Task 1: `RecipientSuppressionReason.removedByDan` and its display label

**Files:**
- Modify: `mac/Overture/Domain/Recipient.swift:25-27` (the `RecipientSuppressionReason` enum).
- Modify: `mac/Overture/UI/QueueView+Model.swift:167-171` (the `RecipientSnapshot.statusLabel` switch over `suppressionReason`, inside the `.suppressed` case).
- Test: `mac/OvertureTests/ResultsImportTests.swift` (extend the existing `recipientSnapshotStatusLabelsAndAutoReplied` test at line 164).

**Interfaces:**
- Produces: `RecipientSuppressionReason.removedByDan` (new enum case), consumed by Task 2 and Task 3.

- [ ] **Step 1: Write the failing test.** In `mac/OvertureTests/ResultsImportTests.swift`, inside `recipientSnapshotStatusLabelsAndAutoReplied()` (starts at line 164), add this line right after the existing `.declined` suppression-reason assertion (currently line 184):

```swift
#expect(s(.suppressed, suppressionReason: .removedByDan).statusLabel == "Removed")
```

- [ ] **Step 2: Run to verify it fails.** `./mac/scripts/run-tests-locked.sh`. Expected: FAIL, `type 'RecipientSuppressionReason' has no member 'removedByDan'` (a compile error, not a runtime failure, since the enum case does not exist yet).

- [ ] **Step 3: Add the enum case.** In `mac/Overture/Domain/Recipient.swift`, change:

```swift
enum RecipientSuppressionReason: String, Codable, CaseIterable, Sendable {
    case bookedElsewhere, declined
}
```

to:

```swift
// #399: a third reason, distinct from an actual outcome. removedByDan means Dan hand-removed an
// already-sent contact without recording a decline (reply/decline stats stay honest); the other
// two cases both reflect a real event (the show booked elsewhere, or this contact declined).
enum RecipientSuppressionReason: String, Codable, CaseIterable, Sendable {
    case bookedElsewhere, declined, removedByDan
}
```

- [ ] **Step 4: Fix the now-non-exhaustive switch.** In `mac/Overture/UI/QueueView+Model.swift`, inside `RecipientSnapshot.statusLabel` (around line 167), change:

```swift
        case .suppressed:
            switch suppressionReason {
            case .bookedElsewhere: return "Paused (booked elsewhere)"
            case .declined: return "Paused (show declined)"
            }
```

to:

```swift
        case .suppressed:
            switch suppressionReason {
            case .bookedElsewhere: return "Paused (booked elsewhere)"
            case .declined: return "Paused (show declined)"
            case .removedByDan: return "Removed"
            }
```

- [ ] **Step 5: Run to verify it passes**, then run the full suite to confirm nothing else broke.

Run: `./mac/scripts/run-tests-locked.sh`
Expected: all green, including the new assertion.

- [ ] **Step 6: Commit.**

```bash
git add mac/Overture/Domain/Recipient.swift mac/Overture/UI/QueueView+Model.swift mac/OvertureTests/ResultsImportTests.swift
git commit -m "Add RecipientSuppressionReason.removedByDan (#399)"
```

---

### Task 2: `Prospect.removeOrSuppressRecipient` (the unified remove entry point)

**Files:**
- Modify: `mac/Overture/Domain/Prospect.swift` (add a new method near the existing `removeRecipient(id:)` at line 352).
- Test: `mac/OvertureTests/RecipientStorageTests.swift` (extend, following the existing `removeRecipientDropsById` test at line 59).

**Interfaces:**
- Consumes: Task 1's `RecipientSuppressionReason.removedByDan`.
- Produces: `Prospect.removeOrSuppressRecipient(id: String)`, consumed by Task 5.

- [ ] **Step 1: Write the failing tests.** In `mac/OvertureTests/RecipientStorageTests.swift`, add these three tests after `removeRecipientDropsById()` (after line 67):

```swift
    @Test func removeOrSuppressRecipientDeletesAPendingOne() throws {
        let ctx = try context()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@example.com"), recipient("b@example.com")])

        p.removeOrSuppressRecipient(id: "a@example.com")

        #expect(p.recipients.map(\.id) == ["b@example.com"])
    }

    @Test func removeOrSuppressRecipientSuppressesAnAlreadySentOne() throws {
        let ctx = try context()
        let p = makeProspect(ctx)
        let sent = recipient("a@example.com")
        sent.sendState = .sent
        sent.sentAt = Date()
        p.setRecipients([sent])

        p.removeOrSuppressRecipient(id: "a@example.com")

        #expect(p.recipients.map(\.id) == ["a@example.com"])
        #expect(sent.sendState == .suppressed)
        #expect(sent.suppressionReason == .removedByDan)
        #expect(sent.resolution == nil)
        #expect(sent.outcomeSource == nil)
    }

    @Test func removeOrSuppressRecipientIgnoresAnUnknownId() throws {
        let ctx = try context()
        let p = makeProspect(ctx)
        p.setRecipients([recipient("a@example.com")])

        p.removeOrSuppressRecipient(id: "nope@example.com")

        #expect(p.recipients.map(\.id) == ["a@example.com"])
    }
```

- [ ] **Step 2: Run to verify they fail.**

Run: `./mac/scripts/run-tests-locked.sh`
Expected: FAIL, `value of type 'Prospect' has no member 'removeOrSuppressRecipient'` (compile error).

- [ ] **Step 3: Implement.** In `mac/Overture/Domain/Prospect.swift`, add this method directly after `removeRecipient(id:)` (after line 357):

```swift
    // Dan removes a recipient by hand (#399). A never-sent contact is truly gone, nothing to lose.
    // An already-sent contact is never deleted: it just stops being pursued (no more follow-ups or
    // reminders) without recording a decline, so reply/decline stats stay honest. Distinct from the
    // real "Closed (not now)" mark (markOutcomeManually), which DOES mean Dan read an actual no.
    func removeOrSuppressRecipient(id: String) {
        guard let r = recipients.first(where: { $0.id == id }) else { return }
        if r.sendState == .pending {
            removeRecipient(id: id)
        } else {
            r.sendState = .suppressed
            r.suppressionReason = .removedByDan
        }
    }
```

- [ ] **Step 4: Run to verify they pass**, then the full suite.

Run: `./mac/scripts/run-tests-locked.sh`
Expected: all green.

- [ ] **Step 5: Commit.**

```bash
git add mac/Overture/Domain/Prospect.swift mac/OvertureTests/RecipientStorageTests.swift
git commit -m "Add Prospect.removeOrSuppressRecipient (#399)"
```

---

### Task 3: `ManualRecipientCheck` pure calculator

**Files:**
- Modify: `mac/Overture/Domain/VenueParser.swift:16` (change `venueWords` from `private` to internal, so `ManualRecipientCheck` can reuse the same vocabulary).
- Create: `mac/Overture/Domain/ManualRecipientCheck.swift`.
- Test: Create `mac/OvertureTests/ManualRecipientCheckTests.swift`.

**Interfaces:**
- Consumes: `VenueParser.venueWords: [String]`, `ReplyDetection.email(from: String) -> String` (existing, confirmed to lowercase and trim), `RecipientSuppressionReason.removedByDan` (Task 1), `Recipient`'s existing `id`/`sendState`/`resolution`/`suppressionReason` properties.
- Produces: `ManualRecipientCheck.evaluate(email: String, existingRecipients: [Recipient], venue: String?) -> ManualRecipientCheck.Result`, consumed by Task 5. `Result` has `action: Action` (`.create`, `.resume(existingId: String)`, `.blocked(existingId: String)`), `sharesOrgWith: String?`, `looksLikeVenue: Bool`.

- [ ] **Step 1: Loosen `VenueParser.venueWords`'s access level.** In `mac/Overture/Domain/VenueParser.swift`, change:

```swift
    private static let venueWords = ["Hall", "Theatre", "Theater", "Center", "Centre",
```

to:

```swift
    static let venueWords = ["Hall", "Theatre", "Theater", "Center", "Centre",
```

(Same line, just drop `private`. The rest of the array declaration on the following lines is unchanged.)

- [ ] **Step 2: Write the failing tests.** Create `mac/OvertureTests/ManualRecipientCheckTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import Overture

@MainActor
@Suite("Manual recipient check (#399)")
struct ManualRecipientCheckTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func makeProspect(_ ctx: ModelContext, venue: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music", venue: venue,
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private func recipient(_ email: String, sendState: SendState = .sent,
                           resolution: RecipientResolution? = nil,
                           suppressionReason: RecipientSuppressionReason? = nil) -> Recipient {
        let r = Recipient(id: email, email: email, provenance: .manual)
        r.sendState = sendState
        r.resolution = resolution
        if let suppressionReason { r.suppressionReason = suppressionReason }
        return r
    }

    @Test func blocksAnAlreadyActiveExactMatch() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@example.com")])

        let result = ManualRecipientCheck.evaluate(email: "Jane@Example.com",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .blocked(existingId: "jane@example.com"))
    }

    @Test func resumesARemovedByDanMatch() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@example.com", sendState: .suppressed, suppressionReason: .removedByDan)])

        let result = ManualRecipientCheck.evaluate(email: "jane@example.com",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .resume(existingId: "jane@example.com"))
    }

    @Test func resumesADeclinedSoftMatch() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@example.com", resolution: .declinedSoft)])

        let result = ManualRecipientCheck.evaluate(email: "jane@example.com",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .resume(existingId: "jane@example.com"))
    }

    @Test func resumesADeclinedHardMatch() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@example.com", resolution: .declinedHard)])

        let result = ManualRecipientCheck.evaluate(email: "jane@example.com",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .resume(existingId: "jane@example.com"))
    }

    @Test func blocksABookedMatch() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@example.com", resolution: .booked)])

        let result = ManualRecipientCheck.evaluate(email: "jane@example.com",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .blocked(existingId: "jane@example.com"))
    }

    @Test func blocksABookedElsewhereSuppressedMatch() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@example.com", sendState: .suppressed, suppressionReason: .bookedElsewhere)])

        let result = ManualRecipientCheck.evaluate(email: "jane@example.com",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .blocked(existingId: "jane@example.com"))
    }

    @Test func flagsASharedDomainWithAnotherExistingRecipient() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        p.setRecipients([recipient("jane@aurorastrings.example")])

        let result = ManualRecipientCheck.evaluate(email: "bob@aurorastrings.example",
                                                    existingRecipients: p.recipients, venue: nil)

        #expect(result.action == .create)
        #expect(result.sharesOrgWith == "jane@aurorastrings.example")
    }

    @Test func flagsAVenueWordSuffixedDomain() throws {
        let result = ManualRecipientCheck.evaluate(email: "info@carnegiehall.org",
                                                    existingRecipients: [], venue: "Carnegie Hall")
        #expect(result.looksLikeVenue == true)
    }

    @Test func flagsABareProperNounVenueWithNoVenueWord() throws {
        let result = ManualRecipientCheck.evaluate(email: "info@wavehill.org",
                                                    existingRecipients: [], venue: "Wave Hill")
        #expect(result.looksLikeVenue == true)
    }

    @Test func flagsAMultiWordVenue() throws {
        let result = ManualRecipientCheck.evaluate(email: "info@madisonsquarepark.org",
                                                    existingRecipients: [], venue: "Madison Square Park")
        #expect(result.looksLikeVenue == true)
    }

    @Test func doesNotFlagAnUnrelatedDomain() throws {
        let result = ManualRecipientCheck.evaluate(email: "jane@aurorastrings.example",
                                                    existingRecipients: [], venue: "Carnegie Hall")
        #expect(result.looksLikeVenue == false)
    }

    @Test func aCleanAddHasNoFlagsAndCreates() throws {
        let result = ManualRecipientCheck.evaluate(email: "new@newcontact.example",
                                                    existingRecipients: [], venue: nil)
        #expect(result.action == .create)
        #expect(result.sharesOrgWith == nil)
        #expect(result.looksLikeVenue == false)
    }
}
```

- [ ] **Step 3: Run to verify they fail.**

Run: `./mac/scripts/run-tests-locked.sh`
Expected: FAIL, `cannot find 'ManualRecipientCheck' in scope` (compile error, the file does not exist yet).

- [ ] **Step 4: Implement.** Create `mac/Overture/Domain/ManualRecipientCheck.swift`:

```swift
import Foundation

// The manual add-a-contact check (#399): before creating a new Recipient by hand, decide whether
// the typed email already belongs to someone on this show (blocked, or resumable if pursuit had
// stopped), and surface two ALWAYS-informational, never-blocking flags: a shared domain with
// another existing contact, and a domain that looks like the venue's own. Pure and SwiftData-free
// so every branch is unit tested without a ModelContext, mirroring ConversationReminder/FollowUp's
// calculator style. Manual adds are never blocked for the venue/org reasons, only exact-duplicate
// identity blocks, and only when the match is still active or already settled.
enum ManualRecipientCheck {
    enum Action: Equatable {
        case create                        // no conflict, add a fresh Recipient
        case resume(existingId: String)    // matches a contact pursuit had stopped on; resume it
        case blocked(existingId: String)   // matches an already-active or settled contact
    }

    struct Result: Equatable {
        let action: Action
        let sharesOrgWith: String?   // id of another existing recipient on the same domain, if any
        let looksLikeVenue: Bool
    }

    static func evaluate(email: String, existingRecipients: [Recipient], venue: String?) -> Result {
        let canonical = ReplyDetection.email(from: email)
        let emailDomain = domain(of: canonical)

        if let match = existingRecipients.first(where: { $0.id == canonical }) {
            let bookedElsewhere = match.sendState == .suppressed && match.suppressionReason == .bookedElsewhere
            let removedByDan = match.sendState == .suppressed && match.suppressionReason == .removedByDan
            let action: Action
            if match.resolution == .booked || bookedElsewhere {
                action = .blocked(existingId: match.id)
            } else if removedByDan || match.resolution == .declinedSoft || match.resolution == .declinedHard {
                action = .resume(existingId: match.id)
            } else {
                action = .blocked(existingId: match.id)   // still active and unresolved
            }
            return Result(action: action, sharesOrgWith: nil, looksLikeVenue: looksLikeVenue(emailDomain, venue: venue))
        }

        let orgMatch = existingRecipients.first { !emailDomain.isEmpty && domain(of: $0.id) == emailDomain }
        return Result(action: .create, sharesOrgWith: orgMatch?.id,
                      looksLikeVenue: looksLikeVenue(emailDomain, venue: venue))
    }

    private static func domain(of email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return "" }
        return String(email[email.index(after: at)...]).lowercased()
    }

    // A heuristic, not a lookup: strips common venue words (the same vocabulary VenueParser uses
    // for the automated importer, so "the venue" means the same thing on both paths), then checks
    // whether any remaining significant word appears in the email's domain. Can false-positive (an
    // unrelated org whose name happens to share a word) or false-negative (a venue whose domain
    // does not resemble its display name). Both are fine: the caller only ever surfaces this as an
    // informational flag, never a block.
    private static func looksLikeVenue(_ domain: String, venue: String?) -> Bool {
        guard !domain.isEmpty, let venue, !venue.isEmpty else { return false }
        let stripped = VenueParser.venueWords.reduce(venue) { result, word in
            result.replacingOccurrences(of: word, with: "", options: .caseInsensitive)
        }
        let words = stripped.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() }
        return words.contains { $0.count > 3 && domain.contains($0) }
    }
}
```

- [ ] **Step 5: Regenerate the Xcode project** (new Swift file added).

Run: `cd mac && xcodegen generate`
Expected: `Generated project at Overture.xcodeproj` with no errors.

- [ ] **Step 6: Run to verify the tests pass**, then the full suite.

Run: `./mac/scripts/run-tests-locked.sh`
Expected: all green.

- [ ] **Step 7: Commit.**

```bash
git add mac/Overture/Domain/VenueParser.swift mac/Overture/Domain/ManualRecipientCheck.swift mac/OvertureTests/ManualRecipientCheckTests.swift mac/Overture.xcodeproj
git commit -m "Add ManualRecipientCheck duplicate/venue-domain calculator (#399)"
```

---

### Task 4: New `ActionAck` banner strings

**Files:**
- Modify: `mac/Overture/App/ActionFeedback.swift` (add four new static functions to the `ActionAck` enum, after `saveFailed` at line 75).
- Test: `mac/OvertureTests/ActionFeedbackTests.swift` (add a new test after the existing `ActionAck`-string tests, near line 85).

**Interfaces:**
- Produces: `ActionAck.recipientAdded(name: String?, org: String, totalCount: Int, warnings: [String]) -> String`, `ActionAck.recipientAlreadyExists(name: String?, org: String) -> String`, `ActionAck.recipientResumed(name: String?, org: String) -> String`, `ActionAck.recipientRemoved(name: String?, org: String) -> String`. All four consumed by Task 5.

- [ ] **Step 1: Write the failing tests.** In `mac/OvertureTests/ActionFeedbackTests.swift`, add after the existing `remindLater` test (near line 85):

```swift
    @Test("recipientAdded reports the total count and any warnings")
    func recipientAddedMessage() {
        #expect(ActionAck.recipientAdded(name: "Jane Doe", org: "Aurora Strings", totalCount: 3, warnings: [])
                == "Added Jane Doe. 3 recipients on Aurora Strings now.")
        #expect(ActionAck.recipientAdded(name: nil, org: "Aurora Strings", totalCount: 1, warnings: [])
                == "Added the contact. 1 recipient on Aurora Strings now.")
        #expect(ActionAck.recipientAdded(name: "Jane Doe", org: "Aurora Strings", totalCount: 2,
                                         warnings: ["Heads up: looks like the venue's own domain."])
                == "Added Jane Doe. 2 recipients on Aurora Strings now. Heads up: looks like the venue's own domain.")
    }

    @Test("recipientAlreadyExists names who and the show")
    func recipientAlreadyExistsMessage() {
        #expect(ActionAck.recipientAlreadyExists(name: "Jane Doe", org: "Aurora Strings")
                == "Jane Doe is already a recipient on Aurora Strings.")
        #expect(ActionAck.recipientAlreadyExists(name: nil, org: "Aurora Strings")
                == "That contact is already a recipient on Aurora Strings.")
    }

    @Test("recipientResumed and recipientRemoved name who and the show")
    func recipientResumedAndRemovedMessages() {
        #expect(ActionAck.recipientResumed(name: "Jane Doe", org: "Aurora Strings")
                == "Resumed pursuing Jane Doe on Aurora Strings.")
        #expect(ActionAck.recipientRemoved(name: "Jane Doe", org: "Aurora Strings")
                == "Removed Jane Doe from Aurora Strings.")
    }
```

- [ ] **Step 2: Run to verify they fail.**

Run: `./mac/scripts/run-tests-locked.sh`
Expected: FAIL, `type 'ActionAck' has no member 'recipientAdded'` (and similarly for the other three; compile error).

- [ ] **Step 3: Implement.** In `mac/Overture/App/ActionFeedback.swift`, add these four functions inside `enum ActionAck` after `saveFailed` (after line 75):

```swift
    // #399: the manual add/remove confirmations. Never blocking, matches the ActionFeedback banner
    // firing after the change already happened.
    static func recipientAdded(name: String?, org: String, totalCount: Int, warnings: [String]) -> String {
        let who = (name?.isEmpty == false) ? name! : "the contact"
        let base = "Added \(who). \(totalCount) recipient\(totalCount == 1 ? "" : "s") on \(org) now."
        guard !warnings.isEmpty else { return base }
        return base + " " + warnings.joined(separator: " ")
    }

    static func recipientAlreadyExists(name: String?, org: String) -> String {
        let who = (name?.isEmpty == false) ? name! : "That contact"
        return "\(who) is already a recipient on \(org)."
    }

    static func recipientResumed(name: String?, org: String) -> String {
        let who = (name?.isEmpty == false) ? name! : "the contact"
        return "Resumed pursuing \(who) on \(org)."
    }

    static func recipientRemoved(name: String?, org: String) -> String {
        let who = (name?.isEmpty == false) ? name! : "the contact"
        return "Removed \(who) from \(org)."
    }
```

- [ ] **Step 4: Run to verify they pass**, then the full suite.

Run: `./mac/scripts/run-tests-locked.sh`
Expected: all green.

- [ ] **Step 5: Commit.**

```bash
git add mac/Overture/App/ActionFeedback.swift mac/OvertureTests/ActionFeedbackTests.swift
git commit -m "Add recipient add/remove ActionAck banner strings (#399)"
```

---

### Task 5: `ProspectMutations.addRecipientManually` and `removeRecipientManually`

**Files:**
- Modify: `mac/Overture/UI/ProspectMutations.swift` (add two new functions, after `markContact` at line 36).
- Test: `mac/OvertureTests/ProspectMutationsTests.swift` (extend, following the existing `markContactSetsResolutionAndResumesPausedRecipients` test at line 34).

**Interfaces:**
- Consumes: `Prospect.removeOrSuppressRecipient(id:)` (Task 2), `ManualRecipientCheck.evaluate` (Task 3), the four `ActionAck` functions (Task 4), `Prospect.addRecipient(_:)`/`updateRecipient(id:_:)` (existing).
- Produces: `ProspectMutations.addRecipientManually(_ item: QueueItem, email: String, name: String?, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback)` and `ProspectMutations.removeRecipientManually(_ item: QueueItem, _ recipientId: String, _ name: String?, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback)`, both consumed by Task 6.

- [ ] **Step 1: Write the failing tests.** In `mac/OvertureTests/ProspectMutationsTests.swift`, add after `markContactSetsResolutionAndResumesPausedRecipients()` (after line 47):

```swift
    @Test func addRecipientManuallyCreatesAFreshRecipient() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.addRecipientManually(QueueItem(p), email: "jane@newcontact.example", name: "Jane Doe",
                                                prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.map(\.id) == ["jane@newcontact.example"])
        #expect(p.recipients.first?.name == "Jane Doe")
        #expect(p.recipients.first?.provenance == .manual)
        #expect(feedback.message == "Added Jane Doe. 1 recipient on Aurora Strings now.")
    }

    @Test func addRecipientManuallyBlocksAnActiveDuplicate() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let existing = Recipient(id: "jane@example.com", email: "jane@example.com", provenance: .act)
        existing.sendState = .sent
        p.recipients = [existing]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.addRecipientManually(QueueItem(p), email: "jane@example.com", name: "Jane Doe",
                                                prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.count == 1)
        #expect(feedback.message == "Jane Doe is already a recipient on Aurora Strings.")
    }

    @Test func addRecipientManuallyResumesARemovedContact() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let removed = Recipient(id: "jane@example.com", email: "jane@example.com", provenance: .act)
        removed.sendState = .suppressed
        removed.suppressionReason = .removedByDan
        p.recipients = [removed]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.addRecipientManually(QueueItem(p), email: "jane@example.com", name: "Jane Doe",
                                                prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.sendState == .sent)
        #expect(p.recipients.first?.suppressionReasonRaw == nil)
        #expect(feedback.message == "Resumed pursuing Jane Doe on Aurora Strings.")
    }

    @Test func removeRecipientManuallyDeletesAPendingOneAndAcknowledges() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let pending = Recipient(id: "jane@example.com", email: "jane@example.com", provenance: .act)
        p.recipients = [pending]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.removeRecipientManually(QueueItem(p), "jane@example.com", "Jane Doe",
                                                   prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.isEmpty)
        #expect(feedback.message == "Removed Jane Doe from Aurora Strings.")
    }

    @Test func removeRecipientManuallySuppressesASentOneAndAcknowledges() throws {
        let ctx = ModelContext(try container())
        let p = makeProspect(ctx)
        let sent = Recipient(id: "jane@example.com", email: "jane@example.com", provenance: .act)
        sent.sendState = .sent
        p.recipients = [sent]
        try? ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.removeRecipientManually(QueueItem(p), "jane@example.com", "Jane Doe",
                                                   prospects: [p], context: ctx, feedback: feedback)

        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.sendState == .suppressed)
        #expect(p.recipients.first?.suppressionReason == .removedByDan)
        #expect(feedback.message == "Removed Jane Doe from Aurora Strings.")
    }
```

- [ ] **Step 2: Run to verify they fail.**

Run: `./mac/scripts/run-tests-locked.sh`
Expected: FAIL, `type 'ProspectMutations' has no member 'addRecipientManually'` (and `removeRecipientManually`; compile error).

- [ ] **Step 3: Implement.** In `mac/Overture/UI/ProspectMutations.swift`, add these two functions and one private helper after `markContact` (after line 36):

```swift
    // Dan manually adds a contact by hand (#399): runs the exact-duplicate/org/venue check first,
    // then creates a fresh Recipient, resumes one pursuit had stopped on, or is blocked if the
    // email already belongs to an active or settled contact. The venue/org flags never block; they
    // only ride along in the confirmation banner.
    static func addRecipientManually(_ item: QueueItem, email: String, name: String?,
                                     prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = ManualRecipientCheck.evaluate(email: trimmedEmail, existingRecipients: model.recipients,
                                                    venue: model.venue)

        switch result.action {
        case .blocked:
            feedback.acknowledge(ActionAck.recipientAlreadyExists(name: trimmedName, org: model.groupName))
            return
        case .resume(let existingId):
            model.updateRecipient(id: existingId) { r in
                r.sendState = .sent
                r.suppressionReasonRaw = nil
                r.resolutionRaw = nil
                r.outcomeSourceRaw = nil
            }
        case .create:
            let canonical = ReplyDetection.email(from: trimmedEmail)
            model.addRecipient(Recipient(id: canonical, email: trimmedEmail,
                                         name: (trimmedName?.isEmpty == false) ? trimmedName : nil,
                                         provenance: .manual))
        }

        guard context.saveOrWarn(org: model.groupName, feedback: feedback) else { return }
        switch result.action {
        case .resume:
            feedback.acknowledge(ActionAck.recipientResumed(name: trimmedName, org: model.groupName))
        default:
            feedback.acknowledge(ActionAck.recipientAdded(name: trimmedName, org: model.groupName,
                                                           totalCount: model.recipients.count,
                                                           warnings: warningLines(for: result)))
        }
    }

    private static func warningLines(for result: ManualRecipientCheck.Result) -> [String] {
        var lines: [String] = []
        if result.sharesOrgWith != nil {
            lines.append("Heads up: shares a domain with another contact already on this show.")
        }
        if result.looksLikeVenue {
            lines.append("Heads up: looks like the venue's own domain.")
        }
        return lines
    }

    // Dan removes a recipient by hand (#399): Prospect.removeOrSuppressRecipient decides delete
    // versus stop-pursuing by that recipient's current send state.
    static func removeRecipientManually(_ item: QueueItem, _ recipientId: String, _ name: String?,
                                        prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.removeOrSuppressRecipient(id: recipientId)
        if context.saveOrWarn(org: model.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.recipientRemoved(name: name, org: model.groupName))
        }
    }
```

- [ ] **Step 4: Run to verify they pass**, then the full suite.

Run: `./mac/scripts/run-tests-locked.sh`
Expected: all green.

- [ ] **Step 5: Commit.**

```bash
git add mac/Overture/UI/ProspectMutations.swift mac/OvertureTests/ProspectMutationsTests.swift
git commit -m "Add ProspectMutations.addRecipientManually and removeRecipientManually (#399)"
```

---

### Task 6: UI wiring in `DraftReviewView`, `ProspectRowView`, `ProspectRowFactory`, and the Approve-button fix

**Files:**
- Modify: `mac/Overture/UI/DraftReviewView.swift` (the `conversationContactsSection`/`contactRow` around lines 232-297, the Approve button's `.disabled` at line 218, add two new `@State` properties and a new `addContactButton` view, add two new callback parameters).
- Modify: `mac/Overture/UI/ProspectRowView.swift` (thread the two new callback parameters through to `DraftReviewView`).
- Modify: `mac/Overture/UI/ProspectRowFactory.swift` (wire the two new callbacks to `ProspectMutations.addRecipientManually`/`removeRecipientManually`).

**Interfaces:**
- Consumes: Task 5's `ProspectMutations.addRecipientManually`/`removeRecipientManually`.
- Produces: nothing further consumed by another task; this is the last task.

- [ ] **Step 1: Add the two new callback parameters to `DraftReviewView`.** In `mac/Overture/UI/DraftReviewView.swift`, add these two lines to the property list, right after `onDismissContactReply` (after line 20):

```swift
    var onAddRecipient: (_ email: String, _ name: String?) -> Void = { _, _ in }
    var onRemoveRecipient: (_ recipientId: String) -> Void = { _ in }
```

- [ ] **Step 2: Add the two new `@State` properties for the add-contact popover.** Add these two lines right after `@State private var lostReasonSeeded = false` (after line 40):

```swift
    @State private var showAddContact = false
    @State private var addContactEmail = ""
    @State private var addContactName = ""
```

- [ ] **Step 3: Drop the post-send-only gate and add the empty state.** In `mac/Overture/UI/DraftReviewView.swift`, change `conversationContactsSection` (currently lines 234-243):

```swift
    @ViewBuilder private var conversationContactsSection: some View {
        if item.isSent && !item.contacts.isEmpty {
            VStack(alignment: .leading, spacing: OVSpacing.xs) {
                Text("Contacts")
                    .font(OVType.tag).foregroundStyle(OVColor.inkFaint).tracking(0.6)
                ForEach(item.contacts) { contactRow($0) }
            }
            .padding(.top, OVSpacing.xs)
        }
    }
```

to:

```swift
    @ViewBuilder private var conversationContactsSection: some View {
        VStack(alignment: .leading, spacing: OVSpacing.xs) {
            Text("Contacts")
                .font(OVType.tag).foregroundStyle(OVColor.inkFaint).tracking(0.6)
            if item.contacts.isEmpty {
                Text("No contacts yet.").font(OVType.body).foregroundStyle(OVColor.inkFaint)
            } else {
                ForEach(item.contacts) { contactRow($0) }
            }
            addContactButton
        }
        .padding(.top, OVSpacing.xs)
    }

    // #399: opens a small popover to type an email (required) and name (optional). The add itself
    // runs the duplicate/venue check (ManualRecipientCheck via ProspectMutations); this view never
    // blocks the add on its own, it only requires a plausible email before enabling the button.
    private var addContactButton: some View {
        Button { showAddContact = true } label: {
            Label("Add contact", systemImage: "plus.circle")
                .font(OVType.meta).foregroundStyle(OVColor.forest)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAddContact, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: OVSpacing.sm) {
                Text("Add a contact").font(OVType.dateHeading).foregroundStyle(OVColor.ink)
                TextField("Email", text: $addContactEmail)
                    .textFieldStyle(.roundedBorder)
                TextField("Name (optional)", text: $addContactName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Add") {
                        onAddRecipient(addContactEmail, addContactName.isEmpty ? nil : addContactName)
                        addContactEmail = ""
                        addContactName = ""
                        showAddContact = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!addContactEmail.contains("@"))
                    Button("Cancel") { showAddContact = false }
                        .buttonStyle(.plain).foregroundStyle(OVColor.inkSoft)
                }
            }
            .padding(OVSpacing.md)
            .frame(width: 260)
        }
    }
```

- [ ] **Step 4: Add remove controls to `contactRow`.** In `mac/Overture/UI/DraftReviewView.swift`, change the `if c.sendState == .sent { ... }` block inside `contactRow` (currently lines 270-291):

```swift
            if c.sendState == .sent {
                HStack(spacing: OVSpacing.xs) {
                    Menu {
                        Button("In conversation") { onMarkContact(c.id, nil, false) }
                        Button("Booked") { onMarkContact(c.id, .booked, false) }
                        Button("Closed (not now)") { onMarkContact(c.id, .declinedSoft, false) }
                        Button("Closed (not interested)") { onMarkContact(c.id, .declinedHard, false) }
                        Button("Bounced") { onMarkContact(c.id, nil, true) }
                    } label: {
                        Text("Mark…").font(OVType.meta).foregroundStyle(OVColor.forest)
                            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 4)
                            .background(Capsule().strokeBorder(OVColor.forest.opacity(0.4), lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    if c.isAutoReplied {
                        Button("Not a real reply") { onDismissContactReply(c.id) }
                            .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                            .help("This wasn't a genuine reply (an auto-reply or out of office). Revert it; a new reply still flags.")
                    }
                }
                .padding(.leading, 20)
            }
```

to:

```swift
            if c.sendState == .sent {
                HStack(spacing: OVSpacing.xs) {
                    Menu {
                        Button("In conversation") { onMarkContact(c.id, nil, false) }
                        Button("Booked") { onMarkContact(c.id, .booked, false) }
                        Button("Closed (not now)") { onMarkContact(c.id, .declinedSoft, false) }
                        Button("Closed (not interested)") { onMarkContact(c.id, .declinedHard, false) }
                        Button("Bounced") { onMarkContact(c.id, nil, true) }
                        Divider()
                        // #399: distinct from every option above, none of which mean "stop pursuing
                        // without recording an outcome".
                        Button("Remove", role: .destructive) { onRemoveRecipient(c.id) }
                    } label: {
                        Text("Mark…").font(OVType.meta).foregroundStyle(OVColor.forest)
                            .padding(.horizontal, OVSpacing.sm).padding(.vertical, 4)
                            .background(Capsule().strokeBorder(OVColor.forest.opacity(0.4), lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    if c.isAutoReplied {
                        Button("Not a real reply") { onDismissContactReply(c.id) }
                            .buttonStyle(.plain).font(OVType.meta).foregroundStyle(OVColor.inkSoft)
                            .help("This wasn't a genuine reply (an auto-reply or out of office). Revert it; a new reply still flags.")
                    }
                }
                .padding(.leading, 20)
            } else if c.sendState == .pending {
                // #399: a never-sent contact can be removed outright (Prospect.removeOrSuppressRecipient
                // hard-deletes a still-pending row), so this is a plain delete, not a menu of outcomes.
                Button { onRemoveRecipient(c.id) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle").font(.system(size: 10))
                        Text("Remove").font(OVType.meta)
                    }
                    .foregroundStyle(OVColor.inkSoft)
                }
                .buttonStyle(.plain)
                .padding(.leading, 20)
                .help("Remove this contact")
            }
```

- [ ] **Step 5: Fix the Approve button's legacy-field dependency.** In `mac/Overture/UI/DraftReviewView.swift`, inside `actionRow`, change (currently line 218):

```swift
                .disabled(item.contactEmail == nil)
```

to:

```swift
                // #399: was item.contactEmail == nil, the legacy singular field a separate in-flight
                // milestone (#650-654) is slated to delete. hasPendingRecipient already means "at
                // least one recipient still pending with a real address", the same thing this gate
                // needs, so nothing new had to be added.
                .disabled(!item.hasPendingRecipient)
```

- [ ] **Step 6: Thread the two new callbacks through `ProspectRowView`.** In `mac/Overture/UI/ProspectRowView.swift`, add these two lines to the property list right after `onMarkContact` (after line 23):

```swift
    var onAddRecipient: (_ email: String, _ name: String?) -> Void = { _, _ in }
    var onRemoveRecipient: (_ recipientId: String) -> Void = { _ in }
```

Then, in the `DraftReviewView(...)` construction (around line 82-93), add these two lines right after `onMarkContact: onMarkContact` (after line 93):

```swift
                    onAddRecipient: onAddRecipient,
                    onRemoveRecipient: onRemoveRecipient,
```

- [ ] **Step 7: Wire the two new callbacks in `ProspectRowFactory`.** In `mac/Overture/UI/ProspectRowFactory.swift`, add these two entries to the `ProspectRowView(...)` construction, right after `onMarkContact` (after line 32):

```swift
            onAddRecipient: { email, name in
                ProspectMutations.addRecipientManually(item, email: email, name: name,
                                                        prospects: prospects, context: context, feedback: feedback)
            },
            onRemoveRecipient: { rid in
                let name = item.contacts.first(where: { $0.id == rid })?.displayName
                ProspectMutations.removeRecipientManually(item, rid, name,
                                                          prospects: prospects, context: context, feedback: feedback)
            },
```

- [ ] **Step 8: Build.**

Run: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Run the full test suite.**

Run: `./mac/scripts/run-tests-locked.sh`
Expected: all green (no unit test exists for the SwiftUI view itself; the underlying logic is covered by Tasks 1-5).

- [ ] **Step 10: Live-verify in the running app.** Build and launch a fresh Debug build (see this repo's live-verification recipe in `AGENTS.md`/past sessions: quit any running Overture first, build, launch, drive by clicking). Confirm: a not-yet-sent show shows an always-visible Contacts section with an Add button; adding a contact with just an email works and shows the banner; adding a duplicate active email is blocked with the right banner; adding an email matching a venue-like domain shows the heads-up flag in the banner without blocking; removing a not-yet-sent contact deletes it outright; on an already-sent show, the Mark menu's new Remove option suppresses the contact (status label reads "Removed") without setting a resolution; Approve is enabled exactly when at least one recipient has a real address.

- [ ] **Step 11: Commit.**

```bash
git add mac/Overture/UI/DraftReviewView.swift mac/Overture/UI/ProspectRowView.swift mac/Overture/UI/ProspectRowFactory.swift
git commit -m "Wire manual add/remove recipient UI into DraftReviewView (#399)"
```

---

## Self-Review

**Spec coverage:**
- Decision 1 (both stages visible): Task 6 Step 3 drops the `item.isSent` gate.
- Decision 2 (remove semantics by history): Task 2 (`removeOrSuppressRecipient`), Task 6 Step 4 (row wiring by `sendState`).
- Decision 3 (add form: email + optional name): Task 6 Step 3 (`addContactButton` popover, two fields).
- Decision 4 (reuse the existing banner): Task 4 (`ActionAck` strings), Task 5 (`feedback.acknowledge` calls).
- Decision 5 (exact-duplicate blocked vs resumed): Task 3 (`ManualRecipientCheck.evaluate`'s exact-match branch), Task 5 (the `switch result.action` in `addRecipientManually`).
- Decision 6 (duplicate-org and venue-domain flags, never blocking): Task 3 (`sharesOrgWith`/`looksLikeVenue`), Task 5 (`warningLines`, folded into the banner text, never gates the create/resume path).
- Decision 7 (no throttle framing, just total count): Task 4/5 (`recipientAdded`'s `totalCount` parameter, no cap concept anywhere).
- Decision 8 (Remove lives in the existing Mark menu): Task 6 Step 4.
- The incidental Approve-button fix: Task 6 Step 5.

**Placeholder scan:** every step above has complete, exact code; no TBD/TODO; Task 6 Step 10 is a live-verify step (expected for SwiftUI, matching this repo's own established plan convention, not a placeholder).

**Type consistency:** `RecipientSuppressionReason.removedByDan` (Task 1) is read by `ManualRecipientCheck` (Task 3) and written by `Prospect.removeOrSuppressRecipient` (Task 2). `Prospect.removeOrSuppressRecipient(id:)` (Task 2) is called by `ProspectMutations.removeRecipientManually` (Task 5), which is called by `ProspectRowFactory`'s `onRemoveRecipient` (Task 6). `ManualRecipientCheck.evaluate(email:existingRecipients:venue:) -> Result` (Task 3) is called by `ProspectMutations.addRecipientManually` (Task 5), whose `switch result.action` cases (`.blocked`, `.resume`, `.create`) match exactly what Task 3 defines. All four `ActionAck` functions (Task 4) are called with matching parameter names/types in Task 5. `onAddRecipient`/`onRemoveRecipient` (Task 6 Step 1) have identical signatures at their declaration in `DraftReviewView`, their forwarding declaration in `ProspectRowView` (Step 6), and their wiring in `ProspectRowFactory` (Step 7).
