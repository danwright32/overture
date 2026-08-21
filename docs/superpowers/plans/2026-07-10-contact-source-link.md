# Contact Source Link (#363) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the contact-confidence badge on the review card a clickable link to the page the Prep run actually read a high-confidence contact from, so "high confidence" is something Dan can check instead of an unverifiable assertion (#363).

**Architecture:** Add a new, dedicated `sourceUrl` field to the `PrepContact` JSON contract (prep-results v6), distinct from the existing `formUrl` (which stays the `form_or_dm` contact's own submission link and never doubles as a citation). Thread it through `PrepImporter` onto a new `Recipient.contactSourceURL` field exactly like the existing `contactFormURL`/`contactMethodRaw` fields, surface it on `RecipientSnapshot`, and gate its display behind a single computed property (`contactSourceLinkURL`) that only ever returns a URL when `contactConfidence == .high`. This keeps the SwiftUI badge itself dumb and the display rule unit-testable, matching this codebase's existing `ContactDisplay` pattern.

**Tech Stack:** Swift 6 / SwiftUI / SwiftData (mac app), TypeScript + Vitest (fixture-shape guard), Swift Testing (`@Test`/`@Suite`).

## Global Constraints

- Follow test-driven development: write the failing test before the implementation in every task.
- No dashes as punctuation in any code comment, doc, or commit message (hyphens inside words like "form-only" are fine; write connector phrases as separate words otherwise).
- `sourceUrl`/`contactSourceURL` is purely additive; the tolerant version gate must keep accepting `v1.json` through `v5.json` unchanged.
- The link only ever shows for `confidence == "high"` (medium/generic-inbox and low/inferred contacts never get a source citation). This is enforced at the display layer (`RecipientSnapshot.contactSourceLinkURL`), not by the importer, so a stale value left over from a since-downgraded confidence is inert rather than misleading.
- `contactSourceURL` is a distinct field from `contactFormURL`. Never conflate the two: `contactFormURL` (JSON `formUrl`) stays reserved for a `form_or_dm` contact's own submission link.
- Run `mac/scripts/run-tests-locked.sh` for the Swift suite and `pnpm test` (from repo root) for the TypeScript suite before considering any task done; run `scripts/test-all.sh` before the final commit that touches both sides.
- After adding/editing a `.swift` file (none are added here, only edited) run `cd mac && xcodegen generate` (not needed for this plan since no new Swift files are created, but re-check before committing if that changes).

---

### Task 1: Prep-results contract v6: add `sourceUrl` to `PrepContact`

**Files:**
- Modify: `mac/Overture/Domain/PrepResults.swift`
- Modify: `mac/OvertureTests/PrepResultsContractTests.swift`
- Create: `fixtures/prep-results/v6.json`
- Test: `mac/OvertureTests/PrepResultsContractTests.swift`

**Interfaces:**
- Consumes: `PrepResultsDecoder.decode(_:) throws -> PrepResults` (existing), `PrepContact` struct (existing, gains one field).
- Produces: `PrepContact.sourceUrl: String?` and `PrepResultsDecoder.supportedVersion == 6`, both consumed by Task 2 (`PrepImporter`) and Task 4 (TypeScript guard).

- [ ] **Step 1: Write the failing contract test**

Add this test to the end of `mac/OvertureTests/PrepResultsContractTests.swift`, inside the `PrepResultsContractTests` struct, after `decodesTheV5FixtureWithAnAlreadyCoveredNote`:

```swift
    // v6 (#363): an optional sourceUrl on a contacts[] entry, the page the run actually read a
    // high-confidence contact from, so the app's confidence badge can link Dan through to verify
    // it himself. Distinct from formUrl, which stays the form_or_dm contact's own submission
    // link. Only ever meaningful at confidence == "high"; the tolerant gate (1...6) still accepts
    // the v1/v2/v3/v4/v5 fixtures above.
    @Test func decodesTheV6FixtureWithASourceURL() throws {
        let results = try PrepResultsDecoder.decode(try fixture("v6.json"))
        #expect(results.version == 6)

        let multi = results.results[0]
        #expect(multi.naturalKey == "aurora-strings|2026-03-10|carnegie-hall")
        #expect(multi.contacts?.count == 2)
        #expect(multi.contacts?[0].confidence == "high")
        #expect(multi.contacts?[0].sourceUrl == "https://www.aurorastrings.example/about/staff")
        // A medium-confidence contact carries no source citation.
        #expect(multi.contacts?[1].confidence == "medium")
        #expect(multi.contacts?[1].sourceUrl == nil)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/PrepResultsContractTests`
Expected: build failure (`value of type 'PrepContact' has no member 'sourceUrl'`, the field does not exist yet), and separately the fixture file is missing.

- [ ] **Step 3: Add `sourceUrl` to `PrepContact` and bump the supported version**

In `mac/Overture/Domain/PrepResults.swift`, change the `PrepContact` struct:

```swift
struct PrepContact: Codable, Equatable, Sendable {
    var name: String?
    var role: String?
    var email: String?
    var method: String?       // named_decision_maker | generic_inbox | form_or_dm
    var confidence: String?   // high | medium | low
    var formUrl: String?
    var provenance: String?   // v2 (#392): act | presenter (never the host venue); v3 (#587) adds performer
    // v4 (#639, #634 Phase A): only meaningful when provenance == "performer", a direct, second-person
    // draft body for THIS contact, used instead of the shared (third-person) PrepResult.draft.body when
    // emailing a named performer directly rather than a third party describing them.
    var overrideBody: String?
    // v6 (#363): the page this contact was actually read from, so the app's confidence badge can
    // link Dan through to verify it himself. Only ever meaningful when confidence == "high" (the
    // runbook's STRICT verification bar); distinct from formUrl, which stays the form_or_dm
    // contact's own submission link and never doubles as a citation.
    var sourceUrl: String?
}
```

Change `PrepResultsDecoder.supportedVersion`:

```swift
enum PrepResultsDecoder {
    // Tolerant version gate (min...supported). An exact-match gate was the brittle pattern
    // that broke the results reader when its version bumped (#132):
    // bumping the contract leaves a closed range that still accepts older files, so a format
    // change can't silently make the reader reject the new (or old) shape (#140).
    static let supportedVersion = 6
    static let minimumVersion = 1
```

- [ ] **Step 4: Create the v6 fixture**

Create `fixtures/prep-results/v6.json`:

```json
{
  "version": 6,
  "generatedAt": "2026-07-10T00:00:00.000Z",
  "results": [
    {
      "naturalKey": "aurora-strings|2026-03-10|carnegie-hall",
      "contacts": [
        {
          "name": "Emma Robinson",
          "role": "Marketing Director",
          "email": "emma@aurorastrings.example",
          "method": "named_decision_maker",
          "confidence": "high",
          "provenance": "act",
          "sourceUrl": "https://www.aurorastrings.example/about/staff"
        },
        {
          "email": "tickets@presentingorg.example",
          "method": "generic_inbox",
          "confidence": "medium",
          "provenance": "presenter"
        }
      ],
      "draft": {
        "subject": "Photographing Aurora Strings at Carnegie Hall.",
        "body": "I photograph performing arts in New York and saw Aurora Strings is performing at Carnegie Hall on March 10. I shoot unobtrusive, no-flash documentary coverage and think it would suit your program. My rate is $250 an hour plus tax, one-hour minimum, with the gallery delivered within two weeks. Recent work is at danwrightphotography.com/music. Let me know how that lands.",
        "variant": "rate_stated"
      }
    }
  ]
}
```

> **The email body above is superseded and must not be copied (#2955).** This plan is dated 2026-07-10
> and the sample was correct then. Three rules changed after it: a cold pitch carries no rate and no
> turnaround (Dan, 2026-07-31), a draft links `danwrightphotography.com` and never a gallery path
> (#1832, 2026-07-30, and the app now REFUSES to send a body carrying one), and "let me know how that
> lands" is retired (2026-07-18). The plan is left as the record of what was planned; the current
> examples are in `fixtures/prep-results/`, held to the current rules by
> `SampleDraftsFollowCurrentRulesTests`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/PrepResultsContractTests`
Expected: `** TEST SUCCEEDED **`, and grep the output for `decodesTheV6FixtureWithASourceURL` to confirm it actually ran (a scoped run can silently execute 0 tests, per this repo's known xcodebuild gotcha).

- [ ] **Step 6: Commit**

```bash
git add mac/Overture/Domain/PrepResults.swift mac/OvertureTests/PrepResultsContractTests.swift fixtures/prep-results/v6.json
git commit -m "Add sourceUrl to the prep-results contract (v6, #363)"
```

---

### Task 2: Persist `contactSourceURL` through `Recipient` and `PrepImporter`

**Files:**
- Modify: `mac/Overture/Domain/Recipient.swift`
- Modify: `mac/Overture/Persistence/PrepImporter.swift`
- Test: `mac/OvertureTests/RecipientTests.swift`
- Test: `mac/OvertureTests/PrepImporterTests.swift`

**Interfaces:**
- Consumes: `PrepContact.sourceUrl` (Task 1).
- Produces: `Recipient.contactSourceURL: String?` (stored property + init param), consumed by Task 3 (`RecipientSnapshot`).

- [ ] **Step 1: Write the failing `Recipient` test**

Add to `mac/OvertureTests/RecipientTests.swift`, inside `RecipientTests`, near `provenanceAndSendStateRoundTripThroughRawStrings`:

```swift
    @Test func contactSourceURLDefaultsToNilAndRoundTripsThroughInit() {
        let noSource = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(noSource.contactSourceURL == nil)

        let withSource = Recipient(id: "b@act.example", email: "b@act.example", provenance: .act,
                                   contactSourceURL: "https://act.example/about/staff")
        #expect(withSource.contactSourceURL == "https://act.example/about/staff")
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/RecipientTests`
Expected: build failure (`incorrect argument label` / `extra argument 'contactSourceURL' in call`; the init parameter does not exist yet).

- [ ] **Step 3: Add the field and init parameter to `Recipient`**

In `mac/Overture/Domain/Recipient.swift`, add the stored property right after `contactFormURL`:

```swift
    var contactFormURL: String?
    // #363: the page this contact was actually read from, so the confidence badge can link Dan
    // through to verify it himself. Only ever meaningful when contactConfidence == .high;
    // RecipientSnapshot.contactSourceLinkURL is the single place that gate is enforced for
    // display, so a stale value left over from a since-downgraded confidence is inert rather
    // than shown as a false citation. Distinct from contactFormURL, which stays the form_or_dm
    // contact's own submission link.
    var contactSourceURL: String?
```

Update the custom init:

```swift
    init(id: String, email: String?, name: String? = nil, role: String? = nil,
         provenance: RecipientProvenance,
         contactMethodRaw: String? = nil, contactConfidenceRaw: String? = nil,
         contactFormURL: String? = nil, contactSourceURL: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.role = role
        self.provenanceRaw = provenance.rawValue
        self.contactMethodRaw = contactMethodRaw
        self.contactConfidenceRaw = contactConfidenceRaw
        self.contactFormURL = contactFormURL
        self.contactSourceURL = contactSourceURL
    }
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/RecipientTests`
Expected: `** TEST SUCCEEDED **`, grep output for `contactSourceURLDefaultsToNilAndRoundTripsThroughInit` to confirm it ran.

- [ ] **Step 5: Write the failing `PrepImporter` tests**

Add to `mac/OvertureTests/PrepImporterTests.swift`, inside `PrepImporterTests`, near `reIngestUpsertsTheSameContactInPlace`:

```swift
    // #363: a high-confidence contact's sourceUrl is captured onto the recipient on first ingest.
    @Test func capturesSourceURLOnANewHighConfidenceContact() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Aurora Strings", date: "2026-03-10", venue: "Carnegie Hall")

        let results = PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma Robinson", role: "Marketing Director", email: "emma@act.example",
                            method: "named_decision_maker", confidence: "high",
                            formUrl: nil, provenance: "act",
                            sourceUrl: "https://act.example/about/staff"),
            ])
        ])
        _ = PrepImporter.ingest(results, into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.first?.contactSourceURL == "https://act.example/about/staff")
    }

    // #363: a re-run correcting a contact also updates its sourceUrl in place, mirroring how the
    // same re-run already corrects contactFormURL/contactConfidenceRaw.
    @Test func reIngestUpdatesSourceURLInPlace() throws {
        let ctx = ModelContext(try container())
        let key = keptProspect(ctx, group: "Aurora Strings", date: "2026-03-10", venue: "Carnegie Hall")
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "now", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma", role: "Manager", email: "emma@act.example",
                            method: "generic_inbox", confidence: "medium", formUrl: nil, provenance: "act"),
            ])
        ]), into: ctx)
        _ = PrepImporter.ingest(PrepResults(version: 6, generatedAt: "later", results: [
            PrepResult(naturalKey: key, contacts: [
                PrepContact(name: "Emma Robinson", role: "Director", email: "emma@act.example",
                            method: "named_decision_maker", confidence: "high",
                            formUrl: nil, provenance: "act",
                            sourceUrl: "https://act.example/about/staff"),
            ])
        ]), into: ctx)

        let p = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(p?.recipients.count == 1)
        #expect(p?.recipients.first?.contactSourceURL == "https://act.example/about/staff")
    }
```

- [ ] **Step 6: Run them to verify they fail**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/PrepImporterTests`
Expected: build failure (`extra argument 'sourceUrl' in call`: the `PrepContact` init doesn't accept it as a labeled call yet at this call site's position, and `Recipient.contactSourceURL` isn't read/written by `PrepImporter` yet), or, once Task 1 is committed, a runtime failure with `contactSourceURL == nil` instead of the expected URL.

- [ ] **Step 7: Wire `sourceUrl` through `PrepImporter`**

In `mac/Overture/Persistence/PrepImporter.swift`, in `ingestContacts`, update the `Recipient(...)` construction:

```swift
            } else {
                let recipient = Recipient(id: id, email: email, name: c.name, role: c.role,
                                          provenance: provenance, contactMethodRaw: c.method,
                                          contactConfidenceRaw: c.confidence, contactFormURL: c.formUrl,
                                          contactSourceURL: c.sourceUrl)
```

In `apply(_:email:provenance:venue:to:)`, add the line right after `r.contactFormURL = c.formUrl ?? r.contactFormURL`:

```swift
        r.contactFormURL = c.formUrl ?? r.contactFormURL
        r.contactSourceURL = c.sourceUrl ?? r.contactSourceURL
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/PrepImporterTests`
Expected: `** TEST SUCCEEDED **`, grep output for `capturesSourceURLOnANewHighConfidenceContact` and `reIngestUpdatesSourceURLInPlace` to confirm both ran.

- [ ] **Step 9: Commit**

```bash
git add mac/Overture/Domain/Recipient.swift mac/Overture/Persistence/PrepImporter.swift mac/OvertureTests/RecipientTests.swift mac/OvertureTests/PrepImporterTests.swift
git commit -m "Persist contactSourceURL through Recipient and PrepImporter (#363)"
```

---

### Task 3: Display gate, `RecipientSnapshot.contactSourceLinkURL`

**Files:**
- Modify: `mac/Overture/UI/QueueView+Model.swift`
- Test: `mac/OvertureTests/RecipientTests.swift`

**Interfaces:**
- Consumes: `Recipient.contactSourceURL` (Task 2), `RecipientSnapshot.contactConfidence: ContactConfidence?` (existing).
- Produces: `RecipientSnapshot.contactSourceURL: String?` (stored) and `RecipientSnapshot.contactSourceLinkURL: URL?` (computed, gated on `confidence == .high` and a parseable URL with a scheme), consumed by Task 4 (`DraftReviewView`'s `ConfidencePip`).

- [ ] **Step 1: Write the failing tests**

Add to `mac/OvertureTests/RecipientTests.swift`, inside `RecipientTests`, near `hasRecentDeliveryDelayIsFalseOnceResolved` (reuse the file's existing snapshot-building style):

```swift
    private func confidenceSnapshot(confidence: ContactConfidence?, sourceURL: String?) -> RecipientSnapshot {
        RecipientSnapshot(id: "a@act.example", name: "Emma", email: "a@act.example",
                          role: nil, provenance: .act, sendState: .pending,
                          replied: false, lastReplyText: nil, resolution: nil,
                          bounced: false, outcomeSource: nil,
                          contactConfidence: confidence, contactSourceURL: sourceURL)
    }

    @Test func contactSourceLinkURLIsSetForHighConfidenceWithAValidURL() {
        let s = confidenceSnapshot(confidence: .high, sourceURL: "https://act.example/about/staff")
        #expect(s.contactSourceLinkURL == URL(string: "https://act.example/about/staff"))
    }

    @Test func contactSourceLinkURLIsNilForMediumConfidenceEvenWithAURL() {
        let s = confidenceSnapshot(confidence: .medium, sourceURL: "https://act.example/about/staff")
        #expect(s.contactSourceLinkURL == nil)
    }

    @Test func contactSourceLinkURLIsNilForLowConfidenceEvenWithAURL() {
        let s = confidenceSnapshot(confidence: .low, sourceURL: "https://act.example/about/staff")
        #expect(s.contactSourceLinkURL == nil)
    }

    @Test func contactSourceLinkURLIsNilWhenNoSourceURLIsSet() {
        let s = confidenceSnapshot(confidence: .high, sourceURL: nil)
        #expect(s.contactSourceLinkURL == nil)
    }

    @Test func contactSourceLinkURLIsNilForAnUnparseableURL() {
        let s = confidenceSnapshot(confidence: .high, sourceURL: "not a url")
        #expect(s.contactSourceLinkURL == nil)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/RecipientTests`
Expected: build failure (`incorrect argument label in call`: `RecipientSnapshot` has no `contactSourceURL` init parameter and no `contactSourceLinkURL` member yet).

- [ ] **Step 3: Add the field and computed property to `RecipientSnapshot`**

In `mac/Overture/UI/QueueView+Model.swift`, add the stored property right after `contactFormURL`:

```swift
    var contactFormURL: String? = nil
    // #363: mirrors Recipient.contactSourceURL. See contactSourceLinkURL below for the display
    // gate (only ever a link at confidence == .high).
    var contactSourceURL: String? = nil
```

Add the computed property right after the stored-properties block, before `hasReplyDraft`:

```swift
    // #363: the confidence badge becomes a clickable link to where the contact was actually
    // verified, so "high confidence" is checkable instead of an unverifiable assertion. Gated
    // here (not in PrepImporter) so a contactSourceURL left over from a since-downgraded
    // confidence is inert rather than shown as a false citation, mirroring ContactDisplay's own
    // "decide purely, keep the SwiftUI row dumb" pattern.
    var contactSourceLinkURL: URL? {
        guard contactConfidence == .high, let contactSourceURL, !contactSourceURL.isEmpty,
              let url = URL(string: contactSourceURL), url.scheme != nil else { return nil }
        return url
    }
```

- [ ] **Step 4: Update the `Recipient` -> `RecipientSnapshot` mapping**

In the same file, in `extension RecipientSnapshot { init(_ r: Recipient) { ... } }`, add the new argument right after `contactFormURL: r.contactFormURL,`:

```swift
                  contactFormURL: r.contactFormURL,
                  contactSourceURL: r.contactSourceURL,
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd "mac" && ./scripts/run-tests-locked.sh -only-testing:OvertureTests/RecipientTests`
Expected: `** TEST SUCCEEDED **`, grep output for `contactSourceLinkURL` to confirm all five new tests ran.

- [ ] **Step 6: Commit**

```bash
git add mac/Overture/UI/QueueView+Model.swift mac/OvertureTests/RecipientTests.swift
git commit -m "Add RecipientSnapshot.contactSourceLinkURL display gate (#363)"
```

---

### Task 4: Badge UI, make `ConfidencePip` a link when a source exists

**Files:**
- Modify: `mac/Overture/UI/DraftReviewView.swift`

**Interfaces:**
- Consumes: `RecipientSnapshot.contactSourceLinkURL: URL?` (Task 3).
- Produces: no new interface; this is the leaf UI consumer.

This view has no dedicated unit-test file (`DraftReviewViewSendStateTests.swift` covers send-state behavior, not this badge), and the decision logic it depends on (`contactSourceLinkURL`) is already fully tested in Task 3, so this task is a direct, minimal UI change with no new test. This matches how the codebase already treats `ContactDisplay`-consuming SwiftUI code (the pure decision is tested, the view that renders it is not, e.g. `contactLine`'s `switch display` block above it).

- [ ] **Step 1: Update the call site**

In `mac/Overture/UI/DraftReviewView.swift`, in `contactLine`, change:

```swift
            if let conf = primary?.contactConfidence {
                ConfidencePip(confidence: conf)
            }
```

to:

```swift
            if let conf = primary?.contactConfidence {
                ConfidencePip(confidence: conf, sourceURL: primary?.contactSourceLinkURL)
            }
```

- [ ] **Step 2: Update `ConfidencePip` to render as a `Link` when a source URL is present**

Change the `ConfidencePip` struct:

```swift
private struct ConfidencePip: View {
    let confidence: ContactConfidence
    // #363: when set (only ever at confidence == .high, per RecipientSnapshot.contactSourceLinkURL),
    // the badge becomes a clickable link to the page the contact was verified on.
    let sourceURL: URL?
    var body: some View {
        let (label, color): (String, Color) = {
            switch confidence {
            case .high: return ("high confidence", OVColor.forest)
            case .medium: return ("medium confidence", OVColor.gold)
            case .low: return ("low confidence", OVColor.rust)
            }
        }()
        let pip = Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
        if let sourceURL {
            Link(destination: sourceURL) { pip }
        } else {
            pip
        }
    }
}
```

- [ ] **Step 3: Update the SwiftUI preview fixture, if it constructs `ConfidencePip` directly**

Run: `grep -n "ConfidencePip(" mac/Overture/UI/DraftReviewView.swift`
If any call site other than `contactLine` constructs `ConfidencePip(confidence:)` without `sourceURL:` (for example in a `#Preview` block), add `sourceURL: nil` to it.

- [ ] **Step 4: Build and run the full Swift suite**

Run: `cd "mac" && xcodegen generate && ./scripts/run-tests-locked.sh`
Expected: build succeeds, all tests pass (this task adds no new tests, so this step is a regression check, not a red/green cycle).

- [ ] **Step 5: Commit**

```bash
git add mac/Overture/UI/DraftReviewView.swift
git commit -m "Link the confidence badge to its verified source (#363)"
```

---

### Task 5: Runbook and contract docs

**Files:**
- Modify: `docs/prep-runbook.md`
- Modify: `docs/contracts.md`

**Interfaces:**
- Consumes: nothing (documentation only).
- Produces: nothing (documentation only); this task has no tests.

- [ ] **Step 1: Update the STRICT verification paragraph in `docs/prep-runbook.md`**

Read `docs/prep-runbook.md` and locate the paragraph starting with `**STRICT verification
(Dan's rule).**` (currently around line 197), which currently instructs the workflow to
"set `formUrl` to that source URL" for a high-confidence contact and runs through to
"same as any other unverified guess." at its end. NOTE: the live file's version of this
paragraph uses an em dash character in two places; when you view it with the Read tool
you will see it exactly as it exists on disk. Replace the ENTIRE paragraph with the
text below, which removes both em dashes (replaced with a colon and a semicolon) and
updates the `formUrl` instruction to `sourceUrl`:

```
**STRICT verification (Dan's rule).** `confidence: "high"` is allowed ONLY for an
address actually READ from a real page; set `sourceUrl` to that page's URL (v6, #363:
the app links the confidence badge to it so Dan can verify it himself, distinct from
`formUrl`, which stays reserved for a `form_or_dm` contact's own submission link and
never doubles as a citation). NEVER emit a pattern-guessed address (e.g. firstname@org)
as high; if you only inferred it, use `low` and say so, and omit `sourceUrl` (only
ever meaningful at `high`). Confidence mapping: named+read = high, generic inbox =
medium, form/DM or inferred = low. **For a named performer specifically**, only use
`high` if the source page corroborates that person against THIS SPECIFIC performance
(name plus instrument/role/context match, e.g. their own site lists this date/venue or
names this group); a bare name match with no such corroboration is a misidentification
risk, so mark it `low` instead, same as any other unverified guess.
```

- [ ] **Step 2: Add the version-6 section to `docs/contracts.md`**

Find the version-5 paragraph (currently around line 145) ending in `already-covered spec.` followed by the `### \`overture-reply-classify-queue.json\`...` header. Insert a new paragraph between them:

```
Version 6 (#363) adds an optional `sourceUrl` to a `contacts[]` entry: the page the run actually
read a high-confidence named contact from, so the app's confidence badge can link Dan through to
verify it himself instead of asking him to trust an unverifiable "high confidence" label. Only
ever meaningful when `confidence == "high"`; the app's own display gate
(`RecipientSnapshot.contactSourceLinkURL`) never shows a link for medium/low regardless of what's
set, so a stale or mistaken value on a lower-confidence contact is inert rather than misleading.
Distinct from the existing `formUrl`, which stays the `form_or_dm` contact's own actionable
submission link; the two fields never carry the same meaning. Purely additive; the reader's
tolerant gate (1 through 6) still accepts `v1.json`/`v2.json`/`v3.json`/`v4.json`/`v5.json`
unchanged, `v6.json` is the source-URL spec.
```

- [ ] **Step 3: Update the contract table row's version list**

Find this row near the top of `docs/contracts.md` (currently around line 30):

```
| `overture-prep-results.json` | Prep run (workflow) | App (`PrepImporter` / `PrepResultsDecoder`) | 1, 2, 3, 4, 5 | `fixtures/prep-results/` | `PrepResultsContractTests.swift` |
```

Change it to:

```
| `overture-prep-results.json` | Prep run (workflow) | App (`PrepImporter` / `PrepResultsDecoder`) | 1, 2, 3, 4, 5, 6 | `fixtures/prep-results/` | `PrepResultsContractTests.swift` |
```

- [ ] **Step 4: Commit**

```bash
git add docs/prep-runbook.md docs/contracts.md
git commit -m "Document the prep-results v6 sourceUrl field (#363)"
```

---

### Task 6: TypeScript fixture-shape guard

**Files:**
- Modify: `src/lib/fixtureShape.ts`
- Modify: `src/lib/fixtureShape.test.ts`

**Interfaces:**
- Consumes: `fixtures/prep-results/v6.json` (Task 1).
- Produces: nothing further downstream; this is the last task.

- [ ] **Step 1: Write the failing tests**

In `src/lib/fixtureShape.test.ts`, update the "covers exactly the known prep-results files" assertion:

```typescript
  it("covers exactly the known prep-results files", () => {
    expect(files.sort()).toEqual(["v1.json", "v2.json", "v3.json", "v4.json", "v5.json", "v6.json"]);
  });
```

Add a new rejection test after `"rejects a v4 file whose result already carries the v5 alreadyCoveredNote field"`:

```typescript
  it("rejects a v5 file whose contact already carries the v6 sourceUrl field", () => {
    const mutated = readJson("prep-results", "v5.json") as {
      results: Array<{ contacts?: Array<Record<string, unknown>> }>;
    };
    mutated.results[0].contacts![0].sourceUrl = "https://example.com/about/staff";
    expect(() => assertPrepResultsShape(mutated, "v5.json", 5)).toThrow(/sourceUrl.*before version 6/);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test -- fixtureShape`
Expected: FAIL. The "covers exactly" assertion fails because `assertPrepResultsShape` doesn't yet accept version 6 (`v6.json` isn't in the allowed version list, so decoding it throws), and the new rejection test fails because `sourceUrl` isn't yet a recognized/gated field.

- [ ] **Step 3: Update `assertPrepContact` and `assertPrepResultsShape`**

In `src/lib/fixtureShape.ts`, change `assertPrepContact`'s signature and body:

```typescript
function assertPrepContact(
  data: unknown,
  file: string,
  path: string,
  provenanceRequired: boolean,
  overrideBodyAllowed: boolean,
  sourceUrlAllowed: boolean,
): void {
  const o = requireObject(data, file, path);
  optionalString(o.name, file, `${path}.name`);
  optionalString(o.role, file, `${path}.role`);
  optionalString(o.email, file, `${path}.email`);
  requireString(o.method, file, `${path}.method`);
  requireString(o.confidence, file, `${path}.confidence`);
  optionalString(o.formUrl, file, `${path}.formUrl`);
  if (sourceUrlAllowed) {
    optionalString(o.sourceUrl, file, `${path}.sourceUrl`);
  } else if (o.sourceUrl !== undefined) {
    fail(file, `${path}.sourceUrl must not be present before version 6`);
  }
  if (provenanceRequired) {
    requireEnum(o.provenance, file, `${path}.provenance`, PROVENANCE);
  } else if (o.provenance !== undefined) {
    fail(file, `${path}.provenance must not be present before version 2`);
  }
  if (overrideBodyAllowed) {
    optionalString(o.overrideBody, file, `${path}.overrideBody`);
  } else if (o.overrideBody !== undefined) {
    fail(file, `${path}.overrideBody must not be present before version 4`);
  }
}
```

Update `assertPrepResultsShape`'s comment, version list, and both `assertPrepContact` call sites:

```typescript
// overture-prep-results.json (version 1: singular contact; version 2: contacts[], replaces it;
// version 3: adds "performer" to the provenance vocabulary, #587; version 5: adds an optional
// alreadyCoveredNote fit-risk flag on the result itself, #611; version 6: adds an optional
// sourceUrl per contact, #363)
export function assertPrepResultsShape(data: unknown, file: string, expectedVersion: number): void {
  const root = requireObject(data, file, "(root)");
  const version = requireVersion(root.version, file, [1, 2, 3, 4, 5, 6]);
  if (version !== expectedVersion) fail(file, `version ${version} does not match filename version ${expectedVersion}`);
  requireString(root.generatedAt, file, "generatedAt");
  const results = requireArray(root.results, file, "results");
  const overrideBodyAllowed = version >= 4;
  const alreadyCoveredNoteAllowed = version >= 5;
  const sourceUrlAllowed = version >= 6;
  results.forEach((item, i) => {
    const o = requireObject(item, file, `results[${i}]`);
    requireString(o.naturalKey, file, `results[${i}].naturalKey`);
    if (o.draft !== undefined) {
      const draft = requireObject(o.draft, file, `results[${i}].draft`);
      requireString(draft.subject, file, `results[${i}].draft.subject`);
      requireString(draft.body, file, `results[${i}].draft.body`);
      requireString(draft.variant, file, `results[${i}].draft.variant`);
    }
    if (alreadyCoveredNoteAllowed) {
      optionalString(o.alreadyCoveredNote, file, `results[${i}].alreadyCoveredNote`);
    } else if (o.alreadyCoveredNote !== undefined) {
      fail(file, `results[${i}].alreadyCoveredNote must not be present before version 5`);
    }
    if (version === 1) {
      if (o.contacts !== undefined) fail(file, `results[${i}].contacts must not be present before version 2`);
      if (o.contact !== undefined) assertPrepContact(o.contact, file, `results[${i}].contact`, false, overrideBodyAllowed, sourceUrlAllowed);
    } else {
      if (o.contact !== undefined) fail(file, `results[${i}].contact was replaced by contacts[] in version 2`);
      if (o.contacts !== undefined) {
        const contacts = requireArray(o.contacts, file, `results[${i}].contacts`);
        contacts.forEach((c, j) => assertPrepContact(c, file, `results[${i}].contacts[${j}]`, true, overrideBodyAllowed, sourceUrlAllowed));
      }
    }
  });
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test -- fixtureShape`
Expected: PASS, all `prep-results fixture shapes` tests including the two new/updated ones.

- [ ] **Step 5: Run the full TypeScript suite and typecheck**

Run: `pnpm test && pnpm typecheck`
Expected: both PASS.

- [ ] **Step 6: Commit**

```bash
git add src/lib/fixtureShape.ts src/lib/fixtureShape.test.ts
git commit -m "Guard the prep-results v6 sourceUrl field in the TS fixture-shape checker (#363)"
```

---

### Task 7: Full repo verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full cross-language test suite**

Run: `scripts/test-all.sh`
Expected: `pnpm typecheck`, `pnpm test`, and the Swift suite (`run-tests-locked.sh`) all pass.

- [ ] **Step 2: Manually verify in the running app**

Build and launch: `cd mac && ./scripts/run-tests-locked.sh && ../scripts/../mac/build-install.sh --launch` (or the `overture` shell alias, which wraps the same build-install script). In the review queue, open a prospect whose primary contact has `confidence: "high"` and a `sourceUrl` (use the Debug build's Gmail-connected dev flow, or temporarily hand-edit a local prospect's recipient via the DEBUG menu if one is available, to get a high-confidence contact with a source URL into the store). Confirm the badge renders as a clickable link that opens the source URL in the default browser, and that a medium/low-confidence contact's badge stays plain, unclickable text.

- [ ] **Step 3: Confirm git status**

Run: `git status` and `git log --oneline -7`
Expected: seven commits (Tasks 1 through 6, one per task) on the current branch, working tree clean.
