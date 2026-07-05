# Event Scout Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the deterministic, tested foundation the event scout runs on: reading Downbeat's client/venue export, matching a discovered performance against past clients and outreach history, resolving venue facts, and assembling a scored prospect row.

**Architecture:** Pure TypeScript modules in `src/lib/`, each with one responsibility, all test-first against hand-crafted fixtures. The booked signal comes from Downbeat's local export; the contacted/suppression signal comes from the already-imported CSV `history` table. A thin Supabase adapter persists prospects, verified against the real database. No classification or calendar extraction here; those are later scout pieces and are passed in as inputs.

**Tech Stack:** TypeScript, Vitest, `@supabase/supabase-js`, `tsx`. Reuses `src/lib/ranker.ts` (`Candidate`, `scoreFit`) and `src/lib/bookingImport.ts` (`HistoryRecord`).

> **This plan predates Overture's pivot away from Supabase; it is not a description of the shipped system.** Tasks 2 through 7 (`downbeatBridge.ts`, `groupNameMatch.ts`, `historyMatch.ts`, `venueResolve.ts`, `assembleProspect.ts`, `blockedDates.ts`) shipped in `src/lib/` largely as planned. Task 1's schema migration and Task 8's Supabase adapter (`prospectsRepo.ts`) did not: Overture shipped with a native macOS app's local SwiftData store instead, so no `prospectsRepo.ts` exists and the `supabase/` directory has been removed. For the current architecture, read `AGENTS.md`.

## Global Constraints

- TypeScript everywhere; never use `any`.
- 2-space indentation; follow existing Prettier/ESLint config.
- No comments unless the logic is not self-evident.
- Test-first (TDD): failing test, watch it fail, minimal code, watch it pass, commit.
- All Supabase access is server-side via the service-role key (RLS has no anon policies). Read credentials from `.env.local` in Node, never the shell.
- Run a single test file with: `npx vitest run <path>`.
- Run a TS script with: `./node_modules/.bin/tsx <script>` (never `pnpm tsx`).
- `prior_relationship` / discipline / production / profile / coverage values must exactly match the enums in `src/lib/ranker.ts` and the DB migration `supabase/migrations/20260622150935_create_scout_tables.sql`.

---

## File Structure

- `supabase/migrations/<ts>_add_prospect_match_columns.sql` — adds match columns to `prospects`.
- `src/lib/downbeatBridge.ts` (+ test) — parse the Downbeat export envelope.
- `src/lib/groupNameMatch.ts` (+ test) — name normalization and the confident/possible predicates.
- `src/lib/historyMatch.ts` (+ test) — match against Downbeat clients and CSV history, produce the verdict.
- `src/lib/venueResolve.ts` (+ test) — resolve a performance venue against Downbeat venues.
- `src/lib/assembleProspect.ts` (+ test) — decide and build a prospect row via the ranker.
- `src/lib/blockedDates.ts` (+ test) — blocked-date predicate.
- `src/lib/prospectsRepo.ts` — thin Supabase adapter (loaders, dedup check, insert).

---

## Task 1: Schema migration — prospect match columns

**Files:**
- Create: `supabase/migrations/<timestamp>_add_prospect_match_columns.sql`

**Interfaces:**
- Produces: new nullable columns on `prospects`: `downbeat_client_id uuid`, `matched_client_name text`, `possible_match_source text`, `possible_match_ref uuid`, `possible_match_name text`.

- [ ] **Step 1: Create the migration file**

Run: `supabase migration new add_prospect_match_columns`

- [ ] **Step 2: Write the migration SQL**

In the new file:

```sql
-- Repeat-client match results for prospects. A confident Downbeat client match
-- fills downbeat_client_id + matched_client_name. A fuzzy "possible" match is
-- source-tagged (downbeat_client or history) for Dan to confirm in the queue.
alter table prospects
  add column downbeat_client_id  uuid,
  add column matched_client_name text,
  add column possible_match_source text
    check (possible_match_source in ('downbeat_client', 'history')),
  add column possible_match_ref  uuid,
  add column possible_match_name text;
```

- [ ] **Step 3: Apply the migration**

Run:
```bash
python3 - << 'PY'
import subprocess
pw=[l.split('=',1)[1].strip() for l in open('.env.local') if l.strip().startswith('SUPABASE_DB_PASSWORD=')][0]
print(subprocess.run(["supabase","db","push","-p",pw,"--yes"],text=True,capture_output=True).stdout)
PY
```
Expected: `Applying migration ...add_prospect_match_columns.sql...` and exit 0.

- [ ] **Step 4: Verify the columns exist**

Run:
```bash
python3 - << 'PY'
import json,urllib.request
env={l.split('=',1)[0].strip():l.split('=',1)[1].strip() for l in open('.env.local') if '=' in l and not l.strip().startswith('#')}
req=urllib.request.Request(f"{env['NEXT_PUBLIC_SUPABASE_URL']}/rest/v1/prospects?select=downbeat_client_id,matched_client_name,possible_match_source,possible_match_ref,possible_match_name&limit=1",
  headers={"apikey":env['SUPABASE_SERVICE_ROLE_KEY'],"Authorization":f"Bearer {env['SUPABASE_SERVICE_ROLE_KEY']}"})
print(urllib.request.urlopen(req,timeout=20).read().decode())
PY
```
Expected: `[]` (HTTP 200, columns recognized).

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/
git commit -m "Add prospect match columns (downbeat client + possible match)"
```

---

## Task 2: Downbeat export parser

**Files:**
- Create: `src/lib/downbeatBridge.ts`
- Test: `src/lib/downbeatBridge.test.ts`

**Interfaces:**
- Produces:
  - `type DownbeatClient = { id: string; displayName: string; shortName: string | null; email: string; contractEmail: string; phoneNumber: string | null; isTaxExempt: boolean | null; hasLeftReview: boolean; specialBehaviors: string[]; notes: string | null; hostingSite: string }`
  - `type DownbeatVenue = { id: string; name: string; address: string | null; editingProfile: string | null; specialBehaviors: string[]; staffNotificationEmails: string[]; notes: string | null }`
  - `type DownbeatExport = { clients: DownbeatClient[]; venues: DownbeatVenue[] }`
  - `parseDownbeatExport(json: string): DownbeatExport`
  - `loadDownbeatExport(path?: string): DownbeatExport`

- [ ] **Step 1: Write the failing tests**

```typescript
import { describe, it, expect } from "vitest";
import { parseDownbeatExport } from "./downbeatBridge";

const sample = JSON.stringify({
  version: 1,
  exportedAt: "2026-06-22T15:00:00Z",
  clients: [
    {
      id: "c1",
      displayName: "Every Voice Choirs",
      shortName: "Every Voice",
      email: "a@b.org",
      contractEmail: "a@b.org",
      phoneNumber: null,
      isTaxExempt: false,
      hasLeftReview: true,
      specialBehaviors: [],
      notes: null,
      hostingSite: "pixieset",
    },
  ],
  venues: [
    {
      id: "v1",
      name: "Merkin Hall",
      address: "129 W 67th St",
      editingProfile: "default",
      specialBehaviors: [],
      staffNotificationEmails: [],
      notes: null,
    },
  ],
});

describe("parseDownbeatExport", () => {
  it("parses clients and venues from a version-1 envelope", () => {
    const out = parseDownbeatExport(sample);
    expect(out.clients).toHaveLength(1);
    expect(out.clients[0].displayName).toBe("Every Voice Choirs");
    expect(out.venues[0].name).toBe("Merkin Hall");
  });

  it("defaults missing clients/venues arrays to empty", () => {
    const out = parseDownbeatExport(JSON.stringify({ version: 1 }));
    expect(out.clients).toEqual([]);
    expect(out.venues).toEqual([]);
  });

  it("throws on an unsupported version", () => {
    expect(() => parseDownbeatExport(JSON.stringify({ version: 2 }))).toThrow(
      /unsupported downbeat export version/i,
    );
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run src/lib/downbeatBridge.test.ts`
Expected: FAIL, "Cannot find module './downbeatBridge'".

- [ ] **Step 3: Implement**

```typescript
export type DownbeatClient = {
  id: string;
  displayName: string;
  shortName: string | null;
  email: string;
  contractEmail: string;
  phoneNumber: string | null;
  isTaxExempt: boolean | null;
  hasLeftReview: boolean;
  specialBehaviors: string[];
  notes: string | null;
  hostingSite: string;
};

export type DownbeatVenue = {
  id: string;
  name: string;
  address: string | null;
  editingProfile: string | null;
  specialBehaviors: string[];
  staffNotificationEmails: string[];
  notes: string | null;
};

export type DownbeatExport = {
  clients: DownbeatClient[];
  venues: DownbeatVenue[];
};

const SUPPORTED_VERSION = 1;

export function parseDownbeatExport(json: string): DownbeatExport {
  const data = JSON.parse(json) as {
    version?: number;
    clients?: DownbeatClient[];
    venues?: DownbeatVenue[];
  };
  if (data.version !== SUPPORTED_VERSION) {
    throw new Error(
      `Unsupported Downbeat export version: ${String(data.version)}`,
    );
  }
  return { clients: data.clients ?? [], venues: data.venues ?? [] };
}

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const DEFAULT_EXPORT_PATH = join(
  homedir(),
  "Library",
  "Application Support",
  "Overture",
  "downbeat-export.json",
);

export function loadDownbeatExport(path = DEFAULT_EXPORT_PATH): DownbeatExport {
  return parseDownbeatExport(readFileSync(path, "utf8"));
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run src/lib/downbeatBridge.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/lib/downbeatBridge.ts src/lib/downbeatBridge.test.ts
git commit -m "Add Downbeat export parser"
```

---

## Task 3: Group-name normalization and match predicates

**Files:**
- Create: `src/lib/groupNameMatch.ts`
- Test: `src/lib/groupNameMatch.test.ts`

**Interfaces:**
- Produces:
  - `normalizeGroupName(name: string): string`
  - `isConfidentMatch(a: string, b: string): boolean`
  - `isPossibleMatch(a: string, b: string): boolean`

- [ ] **Step 1: Write the failing tests**

```typescript
import { describe, it, expect } from "vitest";
import {
  normalizeGroupName,
  isConfidentMatch,
  isPossibleMatch,
} from "./groupNameMatch";

describe("normalizeGroupName", () => {
  it("lowercases, strips 'Presented by', drops the title line, removes punctuation", () => {
    expect(normalizeGroupName("Presented by Every Voice Choirs\nSpring Concert")).toBe(
      "every voice choirs",
    );
  });
  it("collapses whitespace and trims", () => {
    expect(normalizeGroupName("  The   Royal   Gala  ")).toBe("the royal gala");
  });
});

describe("isConfidentMatch", () => {
  it("matches identical normalized names", () => {
    expect(isConfidentMatch("Every Voice Choirs", "every voice choirs")).toBe(true);
  });
  it("matches when one name contains the other (>= 2 tokens)", () => {
    expect(
      isConfidentMatch("Every Voice Choirs - Spring Concert", "Every Voice Choirs"),
    ).toBe(true);
  });
  it("does not match on a single shared token", () => {
    expect(isConfidentMatch("Music Academy", "Larchmont Music")).toBe(false);
  });
});

describe("isPossibleMatch", () => {
  it("flags strong token overlap that is not a confident match", () => {
    expect(isPossibleMatch("Royal Foundation Music Arts", "The Royal Music Arts")).toBe(
      true,
    );
  });
  it("is false for a confident match (handled separately)", () => {
    expect(isPossibleMatch("Every Voice Choirs", "Every Voice Choirs")).toBe(false);
  });
  it("is false for weak overlap", () => {
    expect(isPossibleMatch("Brooklyn Youth Chorus", "Manhattan Opera Guild")).toBe(false);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run src/lib/groupNameMatch.test.ts`
Expected: FAIL, "Cannot find module './groupNameMatch'".

- [ ] **Step 3: Implement**

```typescript
export function normalizeGroupName(name: string): string {
  const firstLine = name.split("\n")[0] ?? "";
  return firstLine
    .toLowerCase()
    .replace(/^\s*presented by\s+/i, "")
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function tokens(name: string): string[] {
  return normalizeGroupName(name).split(" ").filter(Boolean);
}

export function isConfidentMatch(a: string, b: string): boolean {
  const na = normalizeGroupName(a);
  const nb = normalizeGroupName(b);
  if (na === "" || nb === "") return false;
  if (na === nb) return true;
  const shorter = na.length <= nb.length ? na : nb;
  const longer = shorter === na ? nb : na;
  if (longer.includes(shorter) && shorter.split(" ").length >= 2) return true;
  return false;
}

export function isPossibleMatch(a: string, b: string): boolean {
  if (isConfidentMatch(a, b)) return false;
  const ta = new Set(tokens(a));
  const tb = new Set(tokens(b));
  if (ta.size === 0 || tb.size === 0) return false;
  let shared = 0;
  for (const t of ta) if (tb.has(t)) shared += 1;
  const union = new Set([...ta, ...tb]).size;
  return shared / union >= 0.5;
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run src/lib/groupNameMatch.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/groupNameMatch.ts src/lib/groupNameMatch.test.ts
git commit -m "Add group-name normalization and match predicates"
```

---

## Task 4: History match — verdict from Downbeat clients + CSV history

**Files:**
- Create: `src/lib/historyMatch.ts`
- Test: `src/lib/historyMatch.test.ts`

**Interfaces:**
- Consumes: `DownbeatClient` (Task 2), `HistoryRecord` (`src/lib/bookingImport.ts`), `isConfidentMatch`/`isPossibleMatch` (Task 3), `Candidate["priorRelationship"]` (`src/lib/ranker.ts`).
- Produces:
  - `type PossibleMatch = { source: "downbeat_client" | "history"; ref: string; name: string }`
  - `type MatchVerdict = { relationship: "booked" | "contacted" | "none"; suppressed: boolean; downbeatClientId: string | null; matchedClientName: string | null; possible: PossibleMatch | null }`
  - `matchRelationship(name: string, clients: DownbeatClient[], history: HistoryRecord[]): MatchVerdict`

- [ ] **Step 1: Write the failing tests**

```typescript
import { describe, it, expect } from "vitest";
import { matchRelationship } from "./historyMatch";
import type { DownbeatClient } from "./downbeatBridge";
import type { HistoryRecord } from "./bookingImport";

function client(over: Partial<DownbeatClient> = {}): DownbeatClient {
  return {
    id: "c1",
    displayName: "Every Voice Choirs",
    shortName: null,
    email: "",
    contractEmail: "",
    phoneNumber: null,
    isTaxExempt: null,
    hasLeftReview: false,
    specialBehaviors: [],
    notes: null,
    hostingSite: "pixieset",
    ...over,
  };
}
function hist(over: Partial<HistoryRecord> = {}): HistoryRecord {
  return {
    group_name: "Some Group",
    shoot_date: null,
    email: null,
    venue: null,
    first_contact: null,
    contact_type: null,
    status: "No Response",
    raw_row: {},
    ...over,
  };
}

describe("matchRelationship", () => {
  it("returns booked with the client id on a confident Downbeat client match", () => {
    const v = matchRelationship("Every Voice Choirs", [client()], []);
    expect(v.relationship).toBe("booked");
    expect(v.downbeatClientId).toBe("c1");
    expect(v.matchedClientName).toBe("Every Voice Choirs");
    expect(v.suppressed).toBe(false);
  });

  it("returns booked when only the CSV history has a confident Booked row", () => {
    const v = matchRelationship("Larchmont Music Academy", [], [
      hist({ group_name: "Larchmont Music Academy", status: "Booked" }),
    ]);
    expect(v.relationship).toBe("booked");
    expect(v.downbeatClientId).toBeNull();
  });

  it("returns contacted on a confident history match that never booked", () => {
    const v = matchRelationship("Royal Gala Concert", [], [
      hist({ group_name: "Royal Gala Concert", status: "No Response" }),
    ]);
    expect(v.relationship).toBe("contacted");
  });

  it("suppresses when a confident history match is DNC", () => {
    const v = matchRelationship("Do Not Email Inc", [], [
      hist({ group_name: "Do Not Email Inc", status: "DNC" }),
    ]);
    expect(v.suppressed).toBe(true);
    expect(v.relationship).toBe("none");
  });

  it("returns none with a possible flag on a fuzzy client match", () => {
    const v = matchRelationship("Royal Foundation Music Arts", [
      client({ id: "c9", displayName: "The Royal Music Arts" }),
    ], []);
    expect(v.relationship).toBe("none");
    expect(v.possible).toEqual({
      source: "downbeat_client",
      ref: "c9",
      name: "The Royal Music Arts",
    });
  });

  it("returns none with no possible flag when nothing is close", () => {
    const v = matchRelationship("Manhattan Opera Guild", [client()], [hist()]);
    expect(v.relationship).toBe("none");
    expect(v.possible).toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run src/lib/historyMatch.test.ts`
Expected: FAIL, "Cannot find module './historyMatch'".

- [ ] **Step 3: Implement**

```typescript
import type { DownbeatClient } from "./downbeatBridge";
import type { HistoryRecord } from "./bookingImport";
import { isConfidentMatch, isPossibleMatch } from "./groupNameMatch";

export type PossibleMatch = {
  source: "downbeat_client" | "history";
  ref: string;
  name: string;
};

export type MatchVerdict = {
  relationship: "booked" | "contacted" | "none";
  suppressed: boolean;
  downbeatClientId: string | null;
  matchedClientName: string | null;
  possible: PossibleMatch | null;
};

function clientNames(c: DownbeatClient): string[] {
  return c.shortName ? [c.displayName, c.shortName] : [c.displayName];
}

function isBooked(status: string | null): boolean {
  return (status ?? "").trim().toLowerCase() === "booked";
}

function isDnc(status: string | null): boolean {
  return (status ?? "").trim().toLowerCase() === "dnc";
}

export function matchRelationship(
  name: string,
  clients: DownbeatClient[],
  history: HistoryRecord[],
): MatchVerdict {
  const confidentHistory = history.filter((h) =>
    isConfidentMatch(name, h.group_name),
  );

  if (confidentHistory.some((h) => isDnc(h.status))) {
    return {
      relationship: "none",
      suppressed: true,
      downbeatClientId: null,
      matchedClientName: null,
      possible: null,
    };
  }

  const confidentClient =
    clients.find((c) => clientNames(c).some((n) => isConfidentMatch(name, n))) ??
    null;

  const historyBooked = confidentHistory.some((h) => isBooked(h.status));

  if (confidentClient || historyBooked) {
    return {
      relationship: "booked",
      suppressed: false,
      downbeatClientId: confidentClient ? confidentClient.id : null,
      matchedClientName: confidentClient ? confidentClient.displayName : null,
      possible: null,
    };
  }

  if (confidentHistory.length > 0) {
    return {
      relationship: "contacted",
      suppressed: false,
      downbeatClientId: null,
      matchedClientName: null,
      possible: null,
    };
  }

  const possibleClient = clients.find((c) =>
    clientNames(c).some((n) => isPossibleMatch(name, n)),
  );
  if (possibleClient) {
    return {
      relationship: "none",
      suppressed: false,
      downbeatClientId: null,
      matchedClientName: null,
      possible: {
        source: "downbeat_client",
        ref: possibleClient.id,
        name: possibleClient.displayName,
      },
    };
  }

  const possibleHistory = history.find((h) => isPossibleMatch(name, h.group_name));
  return {
    relationship: "none",
    suppressed: false,
    downbeatClientId: null,
    matchedClientName: null,
    possible: possibleHistory
      ? { source: "history", ref: "", name: possibleHistory.group_name }
      : null,
  };
}
```

Note: `history` rows have no id in `HistoryRecord`; a possible history match carries an empty `ref` and the name only. (The repo can resolve the id later if needed.)

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run src/lib/historyMatch.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/historyMatch.ts src/lib/historyMatch.test.ts
git commit -m "Add repeat-client match verdict (Downbeat + history, DNC suppression)"
```

---

## Task 5: Venue resolver

**Files:**
- Create: `src/lib/venueResolve.ts`
- Test: `src/lib/venueResolve.test.ts`

**Interfaces:**
- Consumes: `DownbeatVenue` (Task 2), `normalizeGroupName` (Task 3, reused for venue names).
- Produces: `resolveVenue(venueName: string | null, venues: DownbeatVenue[]): DownbeatVenue | null`

- [ ] **Step 1: Write the failing tests**

```typescript
import { describe, it, expect } from "vitest";
import { resolveVenue } from "./venueResolve";
import type { DownbeatVenue } from "./downbeatBridge";

function venue(over: Partial<DownbeatVenue> = {}): DownbeatVenue {
  return {
    id: "v1",
    name: "Merkin Hall",
    address: "129 W 67th St",
    editingProfile: null,
    specialBehaviors: [],
    staffNotificationEmails: [],
    notes: null,
    ...over,
  };
}

describe("resolveVenue", () => {
  it("returns the venue whose name matches, ignoring case and punctuation", () => {
    expect(resolveVenue("merkin hall", [venue()])?.id).toBe("v1");
  });
  it("returns null when no venue matches", () => {
    expect(resolveVenue("Carnegie Hall", [venue()])).toBeNull();
  });
  it("returns null for a missing venue name", () => {
    expect(resolveVenue(null, [venue()])).toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run src/lib/venueResolve.test.ts`
Expected: FAIL, "Cannot find module './venueResolve'".

- [ ] **Step 3: Implement**

```typescript
import type { DownbeatVenue } from "./downbeatBridge";
import { normalizeGroupName } from "./groupNameMatch";

export function resolveVenue(
  venueName: string | null,
  venues: DownbeatVenue[],
): DownbeatVenue | null {
  if (!venueName) return null;
  const target = normalizeGroupName(venueName);
  if (target === "") return null;
  return venues.find((v) => normalizeGroupName(v.name) === target) ?? null;
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run src/lib/venueResolve.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/venueResolve.ts src/lib/venueResolve.test.ts
git commit -m "Add venue resolver against Downbeat venues"
```

---

## Task 6: Blocked-date predicate

**Files:**
- Create: `src/lib/blockedDates.ts`
- Test: `src/lib/blockedDates.test.ts`

**Interfaces:**
- Produces: `isBlockedDate(date: string | null, blocked: Set<string>): boolean`

- [ ] **Step 1: Write the failing tests**

```typescript
import { describe, it, expect } from "vitest";
import { isBlockedDate } from "./blockedDates";

describe("isBlockedDate", () => {
  it("is true when the ISO date is in the blocked set", () => {
    expect(isBlockedDate("2026-05-16", new Set(["2026-05-16"]))).toBe(true);
  });
  it("is false when the date is not blocked", () => {
    expect(isBlockedDate("2026-05-17", new Set(["2026-05-16"]))).toBe(false);
  });
  it("is false for a null date", () => {
    expect(isBlockedDate(null, new Set(["2026-05-16"]))).toBe(false);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run src/lib/blockedDates.test.ts`
Expected: FAIL, "Cannot find module './blockedDates'".

- [ ] **Step 3: Implement**

```typescript
export function isBlockedDate(
  date: string | null,
  blocked: Set<string>,
): boolean {
  if (!date) return false;
  return blocked.has(date);
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run src/lib/blockedDates.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/blockedDates.ts src/lib/blockedDates.test.ts
git commit -m "Add blocked-date predicate"
```

---

## Task 7: Assemble prospect (decision + ranker)

**Files:**
- Create: `src/lib/assembleProspect.ts`
- Test: `src/lib/assembleProspect.test.ts`

**Interfaces:**
- Consumes: `scoreFit`, `Candidate` (`src/lib/ranker.ts`); `MatchVerdict` (Task 4); `isBlockedDate` (Task 6).
- Produces:
  - `type DiscoveredEvent = { group_name: string; discipline: Candidate["discipline"]; venue: string | null; performance_date: string | null; source_listing_url: string | null; website_url: string | null }`
  - `type Classification = { reachable: boolean; production: Candidate["production"]; profile: Candidate["profile"]; coverage: Candidate["coverage"]; fit_reason: string }`
  - `type ProspectRow = { group_name: string; discipline: string; venue: string | null; performance_date: string | null; source_listing_url: string | null; website_url: string | null; reachable: boolean; prior_relationship: string; production: string; profile: string; coverage: string; fit_score: number; tier: string; fit_reason: string; downbeat_client_id: string | null; matched_client_name: string | null; possible_match_source: string | null; possible_match_ref: string | null; possible_match_name: string | null; status: "new" }`
  - `type Decision = { kind: "prospect"; row: ProspectRow } | { kind: "skip"; reason: "blocked" | "suppressed" | "unreachable" }`
  - `decideProspect(event: DiscoveredEvent, classification: Classification, verdict: MatchVerdict, blocked: Set<string>): Decision`

- [ ] **Step 1: Write the failing tests**

```typescript
import { describe, it, expect } from "vitest";
import { decideProspect, type DiscoveredEvent, type Classification } from "./assembleProspect";
import type { MatchVerdict } from "./historyMatch";

function event(over: Partial<DiscoveredEvent> = {}): DiscoveredEvent {
  return {
    group_name: "Every Voice Choirs",
    discipline: "choral",
    venue: "Merkin Hall",
    performance_date: "2026-05-16",
    source_listing_url: null,
    website_url: null,
    ...over,
  };
}
function classification(over: Partial<Classification> = {}): Classification {
  return {
    reachable: true,
    production: "self",
    profile: "strong",
    coverage: "likely_uncovered",
    fit_reason: "Self-produced choral concert at a reachable hall.",
    ...over,
  };
}
function verdict(over: Partial<MatchVerdict> = {}): MatchVerdict {
  return {
    relationship: "none",
    suppressed: false,
    downbeatClientId: null,
    matchedClientName: null,
    possible: null,
    ...over,
  };
}

describe("decideProspect", () => {
  it("skips a performance on a blocked date", () => {
    const d = decideProspect(event(), classification(), verdict(), new Set(["2026-05-16"]));
    expect(d).toEqual({ kind: "skip", reason: "blocked" });
  });

  it("skips a suppressed (DNC) group", () => {
    const d = decideProspect(event(), classification(), verdict({ suppressed: true }), new Set());
    expect(d).toEqual({ kind: "skip", reason: "suppressed" });
  });

  it("skips an unreachable performance", () => {
    const d = decideProspect(event(), classification({ reachable: false }), verdict(), new Set());
    expect(d).toEqual({ kind: "skip", reason: "unreachable" });
  });

  it("builds a scored prospect row carrying the verdict", () => {
    const d = decideProspect(
      event(),
      classification(),
      verdict({ relationship: "booked", downbeatClientId: "c1", matchedClientName: "Every Voice Choirs" }),
      new Set(),
    );
    expect(d.kind).toBe("prospect");
    if (d.kind !== "prospect") return;
    expect(d.row.prior_relationship).toBe("booked");
    expect(d.row.downbeat_client_id).toBe("c1");
    expect(d.row.tier).toBe("high");
    expect(d.row.fit_score).toBeGreaterThan(0);
    expect(d.row.status).toBe("new");
  });

  it("carries a possible match onto the row without scoring it", () => {
    const d = decideProspect(
      event(),
      classification({ production: "unknown", profile: "neutral", coverage: "unknown" }),
      verdict({ possible: { source: "downbeat_client", ref: "c9", name: "Royal Music" } }),
      new Set(),
    );
    if (d.kind !== "prospect") throw new Error("expected prospect");
    expect(d.row.possible_match_source).toBe("downbeat_client");
    expect(d.row.possible_match_ref).toBe("c9");
    expect(d.row.possible_match_name).toBe("Royal Music");
    expect(d.row.prior_relationship).toBe("none");
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `npx vitest run src/lib/assembleProspect.test.ts`
Expected: FAIL, "Cannot find module './assembleProspect'".

- [ ] **Step 3: Implement**

```typescript
import { scoreFit, type Candidate } from "./ranker";
import type { MatchVerdict } from "./historyMatch";
import { isBlockedDate } from "./blockedDates";

export type DiscoveredEvent = {
  group_name: string;
  discipline: Candidate["discipline"];
  venue: string | null;
  performance_date: string | null;
  source_listing_url: string | null;
  website_url: string | null;
};

export type Classification = {
  reachable: boolean;
  production: Candidate["production"];
  profile: Candidate["profile"];
  coverage: Candidate["coverage"];
  fit_reason: string;
};

export type ProspectRow = {
  group_name: string;
  discipline: string;
  venue: string | null;
  performance_date: string | null;
  source_listing_url: string | null;
  website_url: string | null;
  reachable: boolean;
  prior_relationship: string;
  production: string;
  profile: string;
  coverage: string;
  fit_score: number;
  tier: string;
  fit_reason: string;
  downbeat_client_id: string | null;
  matched_client_name: string | null;
  possible_match_source: string | null;
  possible_match_ref: string | null;
  possible_match_name: string | null;
  status: "new";
};

export type Decision =
  | { kind: "prospect"; row: ProspectRow }
  | { kind: "skip"; reason: "blocked" | "suppressed" | "unreachable" };

export function decideProspect(
  event: DiscoveredEvent,
  classification: Classification,
  verdict: MatchVerdict,
  blocked: Set<string>,
): Decision {
  if (isBlockedDate(event.performance_date, blocked)) {
    return { kind: "skip", reason: "blocked" };
  }
  if (verdict.suppressed) {
    return { kind: "skip", reason: "suppressed" };
  }

  const candidate: Candidate = {
    reachable: classification.reachable,
    priorRelationship: verdict.relationship,
    production: classification.production,
    profile: classification.profile,
    coverage: classification.coverage,
    discipline: event.discipline,
  };
  const fit = scoreFit(candidate);
  if (fit.excluded) {
    return { kind: "skip", reason: "unreachable" };
  }

  return {
    kind: "prospect",
    row: {
      group_name: event.group_name,
      discipline: event.discipline,
      venue: event.venue,
      performance_date: event.performance_date,
      source_listing_url: event.source_listing_url,
      website_url: event.website_url,
      reachable: classification.reachable,
      prior_relationship: verdict.relationship,
      production: classification.production,
      profile: classification.profile,
      coverage: classification.coverage,
      fit_score: fit.score,
      tier: fit.tier,
      fit_reason: classification.fit_reason,
      downbeat_client_id: verdict.downbeatClientId,
      matched_client_name: verdict.matchedClientName,
      possible_match_source: verdict.possible ? verdict.possible.source : null,
      possible_match_ref: verdict.possible ? verdict.possible.ref : null,
      possible_match_name: verdict.possible ? verdict.possible.name : null,
      status: "new",
    },
  };
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npx vitest run src/lib/assembleProspect.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/assembleProspect.ts src/lib/assembleProspect.test.ts
git commit -m "Add prospect decision + assembly via ranker"
```

---

## Task 8: Prospects repository (thin Supabase adapter)

**Files:**
- Create: `src/lib/prospectsRepo.ts`

**Interfaces:**
- Consumes: `@supabase/supabase-js`; `HistoryRecord` (`src/lib/bookingImport.ts`); `ProspectRow` (Task 7); `normalizeGroupName` (Task 3).
- Produces:
  - `createRepo(url: string, serviceKey: string)` returning an object with:
    - `loadHistory(): Promise<HistoryRecord[]>`
    - `loadBlockedDates(): Promise<Set<string>>`
    - `prospectExists(groupName: string, performanceDate: string | null, venue: string | null): Promise<boolean>`
    - `insertProspect(row: ProspectRow): Promise<void>`

This task is a thin adapter over the network; it is verified against the real database with a one-off script rather than unit tests (matching the history importer pattern). Do not mock Supabase.

- [ ] **Step 1: Implement the adapter**

```typescript
import { createClient } from "@supabase/supabase-js";
import type { HistoryRecord } from "./bookingImport";
import type { ProspectRow } from "./assembleProspect";

export function createRepo(url: string, serviceKey: string) {
  const supabase = createClient(url, serviceKey, {
    auth: { persistSession: false },
  });

  return {
    async loadHistory(): Promise<HistoryRecord[]> {
      const { data, error } = await supabase
        .from("history")
        .select(
          "group_name, shoot_date, email, venue, first_contact, contact_type, status, raw_row",
        );
      if (error) throw error;
      return (data ?? []) as HistoryRecord[];
    },

    async loadBlockedDates(): Promise<Set<string>> {
      const { data, error } = await supabase
        .from("blocked_dates")
        .select("blocked_date");
      if (error) throw error;
      return new Set((data ?? []).map((r) => r.blocked_date as string));
    },

    async prospectExists(
      groupName: string,
      performanceDate: string | null,
      venue: string | null,
    ): Promise<boolean> {
      let query = supabase
        .from("prospects")
        .select("id", { count: "exact", head: true })
        .eq("group_name", groupName);
      query = performanceDate
        ? query.eq("performance_date", performanceDate)
        : query.is("performance_date", null);
      query = venue ? query.eq("venue", venue) : query.is("venue", null);
      const { count, error } = await query;
      if (error) throw error;
      return (count ?? 0) > 0;
    },

    async insertProspect(row: ProspectRow): Promise<void> {
      const { error } = await supabase.from("prospects").insert(row);
      if (error) throw error;
    },
  };
}
```

- [ ] **Step 2: Verify against the real database**

Create a throwaway check script `scripts/check-repo.ts`:

```typescript
import { readFileSync } from "node:fs";
import { createRepo } from "../src/lib/prospectsRepo";

const env: Record<string, string> = {};
for (const line of readFileSync(".env.local", "utf8").split("\n")) {
  if (line.trimStart().startsWith("#") || !line.includes("=")) continue;
  const i = line.indexOf("=");
  env[line.slice(0, i).trim()] = line.slice(i + 1).trim();
}
const repo = createRepo(
  env.NEXT_PUBLIC_SUPABASE_URL,
  env.SUPABASE_SERVICE_ROLE_KEY,
);
const history = await repo.loadHistory();
const blocked = await repo.loadBlockedDates();
console.log(`history rows: ${history.length}, blocked dates: ${blocked.size}`);
const exists = await repo.prospectExists("Nonexistent Group", "2099-01-01", null);
console.log(`prospectExists(fake) = ${exists}`);
```

Run: `./node_modules/.bin/tsx scripts/check-repo.ts`
Expected: `history rows: 156, blocked dates: 0` and `prospectExists(fake) = false`.

- [ ] **Step 3: Remove the throwaway script and commit**

```bash
rm scripts/check-repo.ts
git add src/lib/prospectsRepo.ts
git commit -m "Add prospects repository (Supabase adapter)"
```

---

## Task 9: Full-suite green check

**Files:** none (verification only).

- [ ] **Step 1: Run the whole suite**

Run: `npx vitest run`
Expected: all test files pass (ranker, bookingImport, downbeatBridge, groupNameMatch, historyMatch, venueResolve, blockedDates, assembleProspect).

- [ ] **Step 2: Typecheck**

Run: `npx tsc --noEmit`
Expected: exit 0, no output.

- [ ] **Step 3: Commit any final cleanup**

```bash
git commit -am "Tidy event scout foundation" --allow-empty
```

---

## Self-Review notes

- Spec section 4 modules all covered: downbeatBridge (T2), historyMatch (T3+T4), venueResolve (T5), assembleProspect (T7), blockedDates (T6), prospectsRepo (T8). Section 6 schema change covered by T1. Section 3.2 contract covered by T2 types. Section 5 data flow covered by `decideProspect` (T7) plus repo dedup (T8).
- Deferred per spec, not in this plan: the Downbeat Swift export (separate plan, separate repo), classification and calendar extraction (later scout pieces), the morning-run orchestration that calls `decideProspect` + repo per event.
- The orchestration that wires extraction → classification → `decideProspect` → dedup → insert belongs to scout piece 4 and will be planned with that piece.
