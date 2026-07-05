# Event Scout Foundation + Downbeat Client/Venue Bridge — Design

Date: 2026-06-22
Related issues: #20 (Downbeat as canonical client source), #18 (repeat-client matching), #14 (server-side-only DB access)

## 1. Context and scope

This is the first build piece of the Overture event scout. The full scout decomposes into four kinds of work:

1. The tested deterministic foundation (this spec).
2. Calendar extraction (driving the headless browser against venue calendars).
3. Classification (Claude judgment during the run, no API key: a written playbook, not a function).
4. Orchestration (the morning run that ties it together).

This spec covers **piece 1 (the foundation)** plus the **Downbeat bridge (issue #20)** that feeds it, because the two are tightly coupled: the foundation's repeat-client matching depends on the canonical client source the bridge provides.

Out of scope here: calendar extraction, the classification playbook, the orchestration/morning run, and all of Trigger 2 (contact finding, drafting, sending). Reachability and travel estimation remain Claude judgment (piece 3); piece 1 only resolves known venue facts that feed that judgment.

## 2. Two sources of "who Dan knows"

- **Downbeat client list** is the canonical, current roster of actual past clients. It provides the authoritative **booked** signal (the warm segment that converts at ~79%). Reached via the local bridge below.
- **The imported CSV history table** (156 rows already loaded) is the full outreach log. It provides the **contacted-but-not-booked** signal, **DNC suppression**, and **dedup** context. Downbeat does not contain non-clients, so this source stays necessary.

The matcher consults both. Precedence: a confident Downbeat client match yields `booked`; otherwise a history match yields `contacted`; otherwise `none`. A `DNC` history status suppresses the group entirely.

## 3. The Downbeat bridge (issue #20)

### 3.1 Mechanism: local JSON handoff

Downbeat lives at `~/Documents/Downbeat`. It is non-sandboxed (no entitlements; store at `~/Library/Application Support/default.store`) and local-only by deliberate design (an explicit code comment notes CloudKit cannot work for its schema). It already serializes its records with Codable `ClientSnapshot` and `VenueSnapshot` DTOs.

Downbeat exports a single JSON file to a fixed local path:

```
~/Library/Application Support/Overture/downbeat-export.json
```

The scout runs locally on Dan's Mac (Claude Code on the Max plan) and reads this file during its run. Rejected alternatives: cloud sync (impossible for the schema, and would push client PII to the cloud), and reading Downbeat's SwiftData SQLite store directly (Apple's private, undocumented, fragile format).

### 3.2 Data contract

Versioned envelope so format changes are detectable:

```json
{
  "version": 1,
  "exportedAt": "2026-06-22T15:00:00Z",
  "clients": [
    {
      "id": "<uuid>",
      "displayName": "Every Voice Choirs",
      "shortName": "Every Voice",
      "email": "...",
      "contractEmail": "...",
      "phoneNumber": "...",
      "isTaxExempt": false,
      "hasLeftReview": true,
      "specialBehaviors": ["..."],
      "notes": "...",
      "hostingSite": "pixieset"
    }
  ],
  "venues": [
    {
      "id": "<uuid>",
      "name": "Merkin Hall",
      "address": "...",
      "editingProfile": "...",
      "specialBehaviors": ["..."],
      "staffNotificationEmails": ["..."],
      "notes": "..."
    }
  ]
}
```

The full data lives in the local file. PII fields (emails, phones, staff emails, notes) are used locally only.

### 3.3 Privacy boundary (PII)

The cloud database stores only the minimum the review queue needs:

- Per prospect, for a client match: `downbeat_client_id`, the matched client's display name, and the `prior_relationship` verdict.
- Per prospect, for a venue: the reachability verdict, a short geography note, and a travel-fee likelihood, all computed locally from the venue address.

Client and venue emails, phone numbers, and notes never leave the Mac. They are read from the local file only when needed (for example, drafting in Trigger 2). Identity key across syncs is the Downbeat record UUID.

## 4. Overture side: piece 1 modules (TypeScript, test-first)

All pure logic is built test-first. The risky repeat-client matching gets full coverage.

1. **`downbeatBridge.ts`** — read and parse the export file into `{ clients, venues }`. A thin file reader plus a pure parser (validate envelope version, map records).
2. **`historyMatch.ts`** — `normalizeGroupName` (lowercase, strip "Presented by", drop the program-title line, remove punctuation, collapse whitespace); `matchClient(name, downbeatClients)` returns a confident booked match (with `downbeat_client_id`) or a fuzzy "possible"; `matchHistory(name, csvHistory)` returns `contacted`, a `DNC` suppression, or a possible flag. A combiner produces the final verdict per the precedence in section 2.
3. **`venueResolve.ts`** — `resolveVenue(venueName, downbeatVenues)` returns a known venue's address and notes, or null. Feeds the classification/reachability step later.
4. **`assembleProspect.ts`** — takes a raw event, its classification, and the match verdict; runs the ranker; returns a finished prospect row, or a "skip" for suppressed, blocked, or unreachable performances.
5. **`blockedDates.ts`** — `isBlockedDate(date, blockedSet)`.
6. **`prospectsRepo.ts`** — thin Supabase adapter: load history, load blocked dates, find an existing prospect (dedup), insert. Verified against the real database, the same pattern as the history importer. All access server-side via the service-role key (issue #14). (Superseded: Overture shipped with local file storage and a SwiftData store instead; `prospectsRepo.ts` and Supabase were never built.)

### Matching philosophy

A confident name match sets the prior-relationship score. A fuzzy near-match does not change the score; it is attached to the prospect as a "possible prior history, confirm?" flag for Dan's review. At scout time only the calendar's group name is available (no email yet; contacts come in Trigger 2), so matching is name-based. Precision is prioritized over recall, because a false match would catapult a stranger to the top of the queue and tee up a warm-toned draft.

## 5. Data flow for one performance

1. On a blocked date? Drop it.
2. Matches a `DNC` group? Drop it (suppressed).
3. Build the candidate (prior-relationship from the match), run the ranker. Unreachable (geography gate)? Drop it.
4. Already in the queue (same normalized group, date, venue)? Skip, so review state is never overwritten on a re-run.
5. Otherwise insert as a ranked prospect. A "possible" match is attached for confirmation, not scored.

## 6. Schema change (Overture migration)

Add to `prospects`:

- `downbeat_client_id uuid` (nullable, no foreign key; the canonical client matched on a confident booked match).
- `matched_client_name text` (nullable; the display name of the confident match, for the queue).
- `possible_match_source text` (nullable; `downbeat_client` or `history`; the source of an unconfirmed fuzzy match).
- `possible_match_ref uuid` (nullable, no foreign key; the matched record's id in that source).
- `possible_match_name text` (nullable; the display name to show Dan when asking him to confirm).

A fuzzy match can point at either a Downbeat client (a possible booked relationship) or a history row (a possible past contact), so the "possible" fields are source-tagged rather than a single history reference. The existing `prior_history_id` stays for a confirmed history (contacted) match.

## 7. Downbeat side (Swift, test-first in its own repo)

A small export feature: encode the client and venue lists (via the existing `ClientSnapshot` / `VenueSnapshot`) into the versioned envelope and write it atomically (temp file then rename) to the fixed path, triggered on record changes and on app launch. Built test-first with Downbeat's existing Swift Testing setup. This is the only change to Downbeat.

## 8. Testing and build sequence

Contract-first. Both sides implement the same JSON envelope; Overture is tested against hand-crafted sample export files and history fixtures, so it does not block on Downbeat.

1. Define the contract and fixtures.
2. Overture: `downbeatBridge`, `historyMatch`, `venueResolve`, `assembleProspect`, `blockedDates` (all test-first), the schema migration, then the thin `prospectsRepo` (verified against the real database).
3. Downbeat: the export feature.

The two sides meet at the file during the real morning run.

## 9. Risks

- **Name-matching viability.** Whether calendar group names resemble Downbeat client names closely enough for matching to work is unknown until the matcher runs against the real export. The confident-scores / fuzzy-flags design is the safety net: the failure mode is "Dan confirms a few maybes," not "a stranger gets warm-pitched."
- **Handoff staleness.** If Downbeat is not launched, the export ages. Mitigated by writing on change and on launch; a staleness warning can be added later.
