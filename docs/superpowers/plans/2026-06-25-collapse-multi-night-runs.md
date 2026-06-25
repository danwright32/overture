# Collapse Multi-Night Runs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse a show that runs several consecutive nights into one stored prospect carrying a date range, so Dan acts on the run once.

**Architecture:** A new pure "run grouping" stage runs after the existing per-event assembly, before upsert, in both the TS engine and the Swift app (kept in parity). It chains same-group+venue performances within 3 days into one run, augmenting the opening night's row with a closing date, the member nights' source URLs, and a related-run flag. Upsert re-recognizes a run by any member night so decisions survive the opening night ageing out of the window. Booking match generalizes to range overlap. The queue shows a date range and a related-run note.

**Tech Stack:** TypeScript + vitest (engine, `src/lib/`, `scripts/scout/`); Swift + Swift Testing + SwiftData (app, `mac/`), xcodegen project.

## Global Constraints

- Dates are `yyyy-MM-dd` strings; all date reasoning in America/New_York (the app's canonical zone). Day-diff math is calendar-day based.
- Run gap threshold: performances chain into one run when consecutive dates are **≤ 3 days apart** (up to 2 dark days). A larger gap starts a new run.
- TS and Swift run-grouping must behave identically; every grouping test exists on both sides.
- Opening date drives sort/timing/window/key (unchanged). `runEndDate` is `nil` for a single-night prospect.
- New Swift files require `cd mac && xcodegen generate` before `xcodebuild` sees them.
- Never chain `git commit && git push`. Commit and push are separate Bash calls.
- TDD: failing test first, watch it fail, minimal code, watch it pass, commit.

---

### Task 1: TS pure run-grouping

**Files:**
- Create: `src/lib/runGrouping.ts`
- Test: `src/lib/runGrouping.test.ts`

**Interfaces:**
- Produces: `groupIntoRuns<T extends RunRow>(rows: T[]): (T & RunFields)[]` where
  `RunRow = { groupName: string; venue: string | null; performanceDate: string | null; sourceListingUrl: string | null }`
  and `RunFields = { runEndDate: string | null; partOfRelatedRun: boolean; runSourceURLs: string[] }`.
  Consecutive same-group+venue rows (≤3 day gap) collapse to the opening row; undated rows pass through unmerged. Multiple runs/dates for the same group+venue each get `partOfRelatedRun: true`.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "vitest";
import { groupIntoRuns } from "./runGrouping";

function row(groupName: string, performanceDate: string | null, venue: string | null = "The Joyce", url = `u-${performanceDate}`) {
  return { groupName, venue, performanceDate, sourceListingUrl: url, fitScore: 9 };
}

describe("groupIntoRuns", () => {
  it("merges consecutive same-group+venue nights into one opening row with a range", () => {
    const out = groupIntoRuns([row("Mark Morris", "2026-07-14"), row("Mark Morris", "2026-07-15"), row("Mark Morris", "2026-07-16")]);
    expect(out).toHaveLength(1);
    expect(out[0].performanceDate).toBe("2026-07-14");
    expect(out[0].runEndDate).toBe("2026-07-16");
    expect(out[0].runSourceURLs.sort()).toEqual(["u-2026-07-14", "u-2026-07-15", "u-2026-07-16"]);
    expect(out[0].partOfRelatedRun).toBe(false);
  });

  it("chains across up to 2 dark days but splits on a larger gap", () => {
    const out = groupIntoRuns([row("X", "2026-07-01"), row("X", "2026-07-04"), row("X", "2026-07-20")]);
    expect(out).toHaveLength(2);
    expect(out[0].performanceDate).toBe("2026-07-01");
    expect(out[0].runEndDate).toBe("2026-07-04");
    expect(out[1].performanceDate).toBe("2026-07-20");
    expect(out[1].runEndDate).toBeNull();
  });

  it("flags two separate runs of the same group+venue as related", () => {
    const out = groupIntoRuns([row("Y", "2026-07-01"), row("Y", "2026-07-20")]);
    expect(out).toHaveLength(2);
    expect(out.every((r) => r.partOfRelatedRun)).toBe(true);
  });

  it("does not merge different venues", () => {
    const out = groupIntoRuns([row("Z", "2026-07-01", "Hall A"), row("Z", "2026-07-02", "Hall B")]);
    expect(out).toHaveLength(2);
    expect(out.every((r) => !r.partOfRelatedRun)).toBe(true);
  });

  it("leaves a single night with a null runEndDate and its own url", () => {
    const out = groupIntoRuns([row("Solo", "2026-07-01")]);
    expect(out[0].runEndDate).toBeNull();
    expect(out[0].runSourceURLs).toEqual(["u-2026-07-01"]);
  });

  it("passes undated rows through unmerged", () => {
    const out = groupIntoRuns([row("Undated", null), row("Undated", null)]);
    expect(out).toHaveLength(2);
    expect(out.every((r) => r.runEndDate === null && !r.partOfRelatedRun)).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run src/lib/runGrouping.test.ts`
Expected: FAIL — cannot find module `./runGrouping`.

- [ ] **Step 3: Write minimal implementation**

```ts
// Collapse a multi-night run (same group + venue, performances <=3 days apart) into the
// opening night's row, tagged with the run's closing date, all member source URLs, and a
// flag when the same group+venue has more than one run/date in the batch. Mirrors
// RunGrouping.swift. See docs/superpowers/specs/2026-06-25-multi-night-run-collapse-design.md.

export type RunRow = {
  groupName: string;
  venue: string | null;
  performanceDate: string | null;
  sourceListingUrl: string | null;
};

export type RunFields = {
  runEndDate: string | null;
  partOfRelatedRun: boolean;
  runSourceURLs: string[];
};

const GAP_DAYS = 3;

function canon(s: string | null): string {
  return (s ?? "").toLowerCase().replace(/\s+/g, " ").trim();
}

function dayNumber(date: string): number {
  const [y, m, d] = date.split("-").map(Number);
  return Math.floor(Date.UTC(y, m - 1, d) / 86_400_000);
}

export function groupIntoRuns<T extends RunRow>(rows: T[]): (T & RunFields)[] {
  const undated = rows.filter((r) => !r.performanceDate);
  const dated = rows.filter((r) => r.performanceDate);

  const byGroup = new Map<string, T[]>();
  for (const r of dated) {
    const key = `${canon(r.groupName)}|${canon(r.venue)}`;
    (byGroup.get(key) ?? byGroup.set(key, []).get(key)!).push(r);
  }

  const out: (T & RunFields)[] = [];
  for (const group of byGroup.values()) {
    group.sort((a, b) => (a.performanceDate! < b.performanceDate! ? -1 : 1));
    const runs: T[][] = [];
    for (const r of group) {
      const last = runs[runs.length - 1];
      const prev = last?.[last.length - 1];
      if (prev && dayNumber(r.performanceDate!) - dayNumber(prev.performanceDate!) <= GAP_DAYS) {
        last.push(r);
      } else {
        runs.push([r]);
      }
    }
    const related = runs.length > 1;
    for (const run of runs) {
      const open = run[0];
      const close = run[run.length - 1];
      out.push({
        ...open,
        runEndDate: run.length > 1 ? close.performanceDate : null,
        partOfRelatedRun: related,
        runSourceURLs: run.map((r) => r.sourceListingUrl).filter((u): u is string => !!u),
      });
    }
  }

  for (const r of undated) {
    out.push({ ...r, runEndDate: null, partOfRelatedRun: false, runSourceURLs: r.sourceListingUrl ? [r.sourceListingUrl] : [] });
  }
  return out;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm vitest run src/lib/runGrouping.test.ts`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add src/lib/runGrouping.ts src/lib/runGrouping.test.ts
git commit -m "Add pure run-grouping for the engine (#132)"
```

---

### Task 2: Swift pure run-grouping (parity)

**Files:**
- Create: `mac/Overture/Domain/RunGrouping.swift`
- Test: `mac/OvertureTests/RunGroupingTests.swift`

**Interfaces:**
- Produces: `RunGrouping.group(_ rows: [RunRow]) -> [GroupedRun]` where
  `RunRow` has `groupName: String, venue: String?, performanceDate: String?, sourceListingURL: String?`
  and `GroupedRun` carries the opening `RunRow`'s fields plus `runEndDate: String?`, `partOfRelatedRun: Bool`, `runSourceURLs: [String]`.
  Used by Task 5; keep the value types minimal so `ScoutService` can map `AssembledProspect` → `RunRow` → grouped result.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Overture

private func row(_ group: String, _ date: String?, venue: String? = "The Joyce", url: String? = nil) -> RunGrouping.RunRow {
    RunGrouping.RunRow(groupName: group, venue: venue, performanceDate: date, sourceListingURL: url ?? (date.map { "u-\($0)" }))
}

@Suite("Run grouping")
struct RunGroupingTests {
    @Test func mergesConsecutiveNightsIntoOneRunWithRange() {
        let out = RunGrouping.group([row("Mark Morris", "2026-07-14"), row("Mark Morris", "2026-07-15"), row("Mark Morris", "2026-07-16")])
        #expect(out.count == 1)
        #expect(out[0].row.performanceDate == "2026-07-14")
        #expect(out[0].runEndDate == "2026-07-16")
        #expect(out[0].runSourceURLs.sorted() == ["u-2026-07-14", "u-2026-07-15", "u-2026-07-16"])
        #expect(out[0].partOfRelatedRun == false)
    }

    @Test func chainsAcrossDarkDaysButSplitsOnLargerGap() {
        let out = RunGrouping.group([row("X", "2026-07-01"), row("X", "2026-07-04"), row("X", "2026-07-20")])
        #expect(out.count == 2)
        #expect(out[0].runEndDate == "2026-07-04")
        #expect(out[1].row.performanceDate == "2026-07-20")
        #expect(out[1].runEndDate == nil)
    }

    @Test func flagsSeparateRunsOfSameGroupVenueAsRelated() {
        let out = RunGrouping.group([row("Y", "2026-07-01"), row("Y", "2026-07-20")])
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.partOfRelatedRun })
    }

    @Test func doesNotMergeDifferentVenues() {
        let out = RunGrouping.group([row("Z", "2026-07-01", venue: "Hall A"), row("Z", "2026-07-02", venue: "Hall B")])
        #expect(out.count == 2)
        #expect(out.allSatisfy { !$0.partOfRelatedRun })
    }

    @Test func singleNightHasNilEndDate() {
        let out = RunGrouping.group([row("Solo", "2026-07-01")])
        #expect(out[0].runEndDate == nil)
        #expect(out[0].runSourceURLs == ["u-2026-07-01"])
    }

    @Test func undatedRowsPassThroughUnmerged() {
        let out = RunGrouping.group([row("U", nil, url: "a"), row("U", nil, url: "b")])
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.runEndDate == nil && !$0.partOfRelatedRun })
    }
}
```

- [ ] **Step 2: Generate project and run test to verify it fails**

Run: `cd mac && xcodegen generate && xcodebuild -scheme Overture -destination 'platform=macOS' test`
Expected: FAIL — `RunGrouping` not found.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

// Collapse a multi-night run (same group + venue, performances <=3 days apart) into the
// opening night, tagged with the run's closing date, all member source URLs, and a flag
// when the same group+venue has more than one run/date in the batch. Mirrors runGrouping.ts.
enum RunGrouping {
    struct RunRow: Equatable, Sendable {
        var groupName: String
        var venue: String?
        var performanceDate: String?
        var sourceListingURL: String?
    }

    struct GroupedRun: Equatable, Sendable {
        var row: RunRow
        var runEndDate: String?
        var partOfRelatedRun: Bool
        var runSourceURLs: [String]
    }

    private static let gapDays = 3

    private static func canon(_ s: String?) -> String {
        (s ?? "").lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func dayNumber(_ date: String) -> Int {
        let p = date.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return 0 }
        var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
        let secs = cal.date(from: c)?.timeIntervalSince1970 ?? 0
        return Int(secs / 86_400)
    }

    static func group(_ rows: [RunRow]) -> [GroupedRun] {
        let undated = rows.filter { $0.performanceDate == nil }
        let dated = rows.filter { $0.performanceDate != nil }

        var order: [String] = []
        var byGroup: [String: [RunRow]] = [:]
        for r in dated {
            let key = "\(canon(r.groupName))|\(canon(r.venue))"
            if byGroup[key] == nil { order.append(key); byGroup[key] = [] }
            byGroup[key]?.append(r)
        }

        var out: [GroupedRun] = []
        for key in order {
            let group = (byGroup[key] ?? []).sorted { ($0.performanceDate ?? "") < ($1.performanceDate ?? "") }
            var runs: [[RunRow]] = []
            for r in group {
                if let last = runs.last, let prev = last.last,
                   dayNumber(r.performanceDate!) - dayNumber(prev.performanceDate!) <= gapDays {
                    runs[runs.count - 1].append(r)
                } else {
                    runs.append([r])
                }
            }
            let related = runs.count > 1
            for run in runs {
                let open = run[0]
                out.append(GroupedRun(
                    row: open,
                    runEndDate: run.count > 1 ? run.last?.performanceDate : nil,
                    partOfRelatedRun: related,
                    runSourceURLs: run.compactMap { $0.sourceListingURL }
                ))
            }
        }
        for r in undated {
            out.append(GroupedRun(row: r, runEndDate: nil, partOfRelatedRun: false,
                                  runSourceURLs: r.sourceListingURL.map { [$0] } ?? []))
        }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test`
Expected: PASS (6 RunGrouping tests; whole suite green).

- [ ] **Step 5: Commit**

```bash
git add mac/Overture/Domain/RunGrouping.swift mac/OvertureTests/RunGroupingTests.swift mac/Overture.xcodeproj/project.pbxproj
git commit -m "Add pure run-grouping for the app, parity with the engine (#132)"
```

---

### Task 3: Wire run-grouping into the TS scout + emit new fields

**Files:**
- Modify: `scripts/scout/run-scout.ts` (the `prospects.push({...})` loop and the post-loop sort/write)
- Modify: `src/lib/assembleProspect.ts:26-49` (`ProspectRow` type — add the three fields, all optional-friendly)
- Test: `src/lib/runGrouping.test.ts` (already covers grouping; no new engine integration test needed — run-scout is the entry-point glue, exercised manually)

**Interfaces:**
- Consumes: `groupIntoRuns` from Task 1.
- Produces: results-file prospect objects now include `runEndDate: string | null`, `partOfRelatedRun: boolean`, `runSourceUrls: string[]`.

- [ ] **Step 1: Apply grouping before the sort in `run-scout.ts`**

In `scripts/scout/run-scout.ts`, add the import at the top with the other `src/lib` imports:

```ts
import { groupIntoRuns } from "../../src/lib/runGrouping";
```

The existing loop pushes objects shaped `{ groupName, ..., sourceListingUrl, ..., fitScore, tier, ... }` into `prospects`. After that loop finishes and BEFORE the `prospects.sort(...)` call, insert:

```ts
const runs = groupIntoRuns(
  prospects as Array<{ groupName: string; venue: string | null; performanceDate: string | null; sourceListingUrl: string | null }>,
);
prospects.length = 0;
for (const r of runs as Array<Record<string, unknown>>) {
  prospects.push({
    ...r,
    runEndDate: r.runEndDate,
    partOfRelatedRun: r.partOfRelatedRun,
    runSourceUrls: r.runSourceURLs,
  });
}
```

(The existing `prospects.sort` by performanceDate then fitScore then the `writeFileSync` of `{ version, generatedAt, prospects }` stay unchanged. Bump `RESULTS_VERSION` from 1 to 2 since the row shape grew.)

- [ ] **Step 2: Typecheck**

Run: `pnpm typecheck`
Expected: PASS (no errors). If `ProspectRow` callers complain, add `runEndDate?: string | null; partOfRelatedRun?: boolean; runSourceUrls?: string[];` to the `ProspectRow` type in `src/lib/assembleProspect.ts`.

- [ ] **Step 3: Run the full engine suite**

Run: `pnpm test`
Expected: PASS (all suites; existing assembleProspect tests unaffected).

- [ ] **Step 4: Commit**

```bash
git add scripts/scout/run-scout.ts src/lib/assembleProspect.ts
git commit -m "Group the TS scout's prospects into runs before writing results (#132)"
```

---

### Task 4: Swift schema + results contract for run fields

**Files:**
- Modify: `mac/Overture/Domain/Prospect.swift` (add stored properties + init params)
- Modify: `mac/Overture/Domain/ProspectAssembler.swift` (`AssembledProspect` — add the three fields, defaulted)
- Modify: `mac/Overture/Domain/ResultsFile.swift` (Codable DTO — add `runEndDate`, `partOfRelatedRun`, `runSourceUrls`, all optional for back-compat)
- Modify: `mac/Overture/Persistence/ResultsImporter.swift` (map the new DTO fields onto `Prospect`)
- Test: `mac/OvertureTests/ResultsImporterTests.swift` (add a decode+import assertion if the file exists; otherwise assert on `ResultsFile` decoding in the nearest existing persistence test)

**Interfaces:**
- Produces: `Prospect.runEndDate: String?`, `Prospect.partOfRelatedRun: Bool`, `Prospect.runSourceURLs: [String]`; `AssembledProspect` carries the same; `ResultsFile`'s prospect DTO decodes `runEndDate`/`partOfRelatedRun`/`runSourceUrls` (defaulting to `nil`/`false`/`[]` when absent).

- [ ] **Step 1: Write the failing test (results decode maps run fields)**

Add to the nearest persistence/results test suite (create `mac/OvertureTests/ResultsRunFieldsTests.swift` if none fits):

```swift
import Testing
import Foundation
@testable import Overture

@Suite("Results run fields")
struct ResultsRunFieldsTests {
    @Test func decodesRunRangeAndFlag() throws {
        let json = """
        {"version":2,"generatedAt":"2026-06-25T00:00:00Z","prospects":[
          {"groupName":"Mark Morris","discipline":"dance","venue":"The Joyce","performanceDate":"2026-07-14",
           "sourceListingUrl":"u1","websiteUrl":null,"priorRelationship":"none","production":"self","profile":"strong",
           "coverage":"likely_uncovered","fitScore":9,"tier":"high","fitReason":"r","matchedClientName":null,
           "possibleMatchSource":null,"possibleMatchName":null,
           "runEndDate":"2026-07-16","partOfRelatedRun":true,"runSourceUrls":["u1","u2","u3"]}
        ]}
        """
        let file = try JSONDecoder().decode(ResultsFile.self, from: Data(json.utf8))
        let p = file.prospects[0]
        #expect(p.runEndDate == "2026-07-16")
        #expect(p.partOfRelatedRun == true)
        #expect(p.runSourceUrls == ["u1", "u2", "u3"])
    }
}
```

(Match the exact `ResultsFile` type name and its prospect DTO property names already in `ResultsFile.swift`; adjust the JSON keys if the existing contract uses different casing.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd mac && xcodegen generate && xcodebuild -scheme Overture -destination 'platform=macOS' test`
Expected: FAIL — DTO has no `runEndDate`/`partOfRelatedRun`/`runSourceUrls`.

- [ ] **Step 3: Add the fields**

In `ResultsFile.swift`, add to the prospect DTO struct (defaulted for back-compat — older files omit them):

```swift
var runEndDate: String? = nil
var partOfRelatedRun: Bool = false
var runSourceUrls: [String] = []
```

In `Prospect.swift`, add stored properties (near `performanceDate`/`venue`):

```swift
var runEndDate: String?
var partOfRelatedRun: Bool = false
var runSourceURLs: [String] = []
```

Add matching parameters to `Prospect.init(...)` with defaults `runEndDate: String? = nil, partOfRelatedRun: Bool = false, runSourceURLs: [String] = []` and assign them.

In `ProspectAssembler.swift`, add to `AssembledProspect`:

```swift
var runEndDate: String? = nil
var partOfRelatedRun: Bool = false
var runSourceURLs: [String] = []
```

In `ResultsImporter.swift`, where it builds/updates a `Prospect` from the DTO, map the three fields (`runSourceURLs: p.runSourceUrls`, `runEndDate: p.runEndDate`, `partOfRelatedRun: p.partOfRelatedRun`).

- [ ] **Step 4: Run to verify it passes**

Run: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test`
Expected: PASS (new test green; existing suite green; SwiftData migration is automatic for optional/defaulted fields).

- [ ] **Step 5: Commit**

```bash
git add mac/Overture/Domain/Prospect.swift mac/Overture/Domain/ProspectAssembler.swift mac/Overture/Domain/ResultsFile.swift mac/Overture/Persistence/ResultsImporter.swift mac/OvertureTests/ResultsRunFieldsTests.swift mac/Overture.xcodeproj/project.pbxproj
git commit -m "Carry run range, related flag, and member URLs through the schema and results contract (#132)"
```

---

### Task 5: Wire run-grouping + re-recognition into the Swift scout

**Files:**
- Modify: `mac/Overture/Integration/ScoutService.swift` (`apply(...)` — group after the per-event decide loop; upsert matches a run by any member source URL)
- Test: `mac/OvertureTests/ScoutServiceTests.swift` (add run-collapse + re-recognition cases)

**Interfaces:**
- Consumes: `RunGrouping.group` (Task 2), the new `AssembledProspect`/`Prospect` fields (Task 4).
- Produces: `ScoutService.apply` stores one `Prospect` per run; a re-scout whose run opening night has aged out re-attaches to the existing record by shared `runSourceURLs`, preserving `status`/`dismissReason`.

- [ ] **Step 1: Write the failing tests**

Add to `ScoutServiceTests.swift` (use the suite's existing in-memory `ModelContext` helper):

```swift
@Test func collapsesAConsecutiveRunIntoOneProspect() throws {
    let ctx = makeContext()  // existing helper
    let events = [
        ExtractedEvent(title: "Mark Morris", presenter: "The Joyce Theater", venue: "The Joyce", performanceDate: "2026-07-14", sourceUrl: "u14"),
        ExtractedEvent(title: "Mark Morris", presenter: "The Joyce Theater", venue: "The Joyce", performanceDate: "2026-07-15", sourceUrl: "u15"),
        ExtractedEvent(title: "Mark Morris", presenter: "The Joyce Theater", venue: "The Joyce", performanceDate: "2026-07-16", sourceUrl: "u16"),
    ]
    let outcome = ScoutService.apply(events: events, clients: [], history: [], blocked: [], into: ctx)
    let stored = try ctx.fetch(FetchDescriptor<Prospect>())
    #expect(stored.count == 1)
    #expect(stored[0].performanceDate == "2026-07-14")
    #expect(stored[0].runEndDate == "2026-07-16")
    #expect(outcome.inserted == 1)
}

@Test func reRecognizesARunWhoseOpeningNightAgedOut() throws {
    let ctx = makeContext()
    let day1 = [
        ExtractedEvent(title: "Run", presenter: "Producer Org", venue: "Hall", performanceDate: "2026-07-14", sourceUrl: "n14"),
        ExtractedEvent(title: "Run", presenter: "Producer Org", venue: "Hall", performanceDate: "2026-07-15", sourceUrl: "n15"),
    ]
    _ = ScoutService.apply(events: day1, clients: [], history: [], blocked: [], into: ctx)
    let kept = try ctx.fetch(FetchDescriptor<Prospect>())[0]
    kept.statusRaw = "dismissed"   // Dan's decision
    try? ctx.save()

    // Next scout: the 14th has aged out of the window; only the 15th remains.
    let day2 = [ExtractedEvent(title: "Run", presenter: "Producer Org", venue: "Hall", performanceDate: "2026-07-15", sourceUrl: "n15")]
    _ = ScoutService.apply(events: day2, clients: [], history: [], blocked: [], into: ctx)
    let stored = try ctx.fetch(FetchDescriptor<Prospect>())
    #expect(stored.count == 1)               // re-attached, not duplicated
    #expect(stored[0].statusRaw == "dismissed")  // decision preserved
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test`
Expected: FAIL — first stores 3 prospects (no grouping); second duplicates (no any-URL re-recognition).

- [ ] **Step 3: Implement grouping + re-recognition in `apply`**

In `ScoutService.apply`, the current loop classifies each event and upserts per event. Restructure so it:
1. Builds the list of `AssembledProspect` (the `.prospect` decisions) instead of upserting inline.
2. Maps them to `RunGrouping.RunRow` (groupName=group_name, venue, performanceDate, sourceListingURL), calls `RunGrouping.group`, and folds each `GroupedRun` back into its opening `AssembledProspect` setting `runEndDate`, `partOfRelatedRun`, `runSourceURLs`.
3. Upserts one prospect per grouped run.

Generalize the existing `matchByStableSource(url:date:)` to match by ANY member URL:

```swift
private static func matchByAnyRunURL(_ urls: [String], in context: ModelContext) -> Prospect? {
    let candidates = Set(urls)
    guard !candidates.isEmpty else { return nil }
    let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
    return all.first { p in
        if let u = p.sourceListingURL, candidates.contains(u) { return true }
        return !Set(p.runSourceURLs).isDisjoint(with: candidates)
    }
}
```

In the upsert, the lookup order becomes: exact `naturalKey` → `matchByAnyRunURL(p.runSourceURLs)` → insert. On the any-URL match, re-key the existing record to the new natural key and `apply(p, to: existing)` (preserving status/dismissReason as the existing `apply` already does), then set `existing.runEndDate`, `existing.partOfRelatedRun`, `existing.runSourceURLs`. The `make(_:key:)` and `apply(_:to:)` helpers gain the three new fields.

- [ ] **Step 4: Run to verify they pass**

Run: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test`
Expected: PASS (both new tests; full suite green).

- [ ] **Step 5: Commit**

```bash
git add mac/Overture/Integration/ScoutService.swift mac/OvertureTests/ScoutServiceTests.swift
git commit -m "Collapse runs at scout time and re-recognize them by any member night (#132)"
```

---

### Task 6: Booking match by run-range overlap

**Files:**
- Modify: `mac/Overture/Domain/BookingMatch.swift:14-25` (the date-window guard)
- Test: `mac/OvertureTests/BookingMatchTests.swift`

**Interfaces:**
- Consumes: `Prospect.runEndDate` (Task 4).
- Produces: `BookingMatch.classify` treats a prospect as `[performanceDate, runEndDate ?? performanceDate]` and matches when that range overlaps the booking's `[startDate, endDate]`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func bookingMatchesAnyNightOfARun() {
    var p = makeProspect(performanceDate: "2026-07-14")  // existing helper
    p.runEndDate = "2026-07-16"
    let booking = DownbeatBooking(/* startDate: "2026-07-16", endDate: "2026-07-16", org matches */)
    #expect(BookingMatch.classify(prospect: p, booking: booking, sentAt: nil) != BookingOutcome.none)
}

@Test func bookingOutsideRunRangeDoesNotMatch() {
    var p = makeProspect(performanceDate: "2026-07-14")
    p.runEndDate = "2026-07-16"
    let booking = DownbeatBooking(/* startDate: "2026-07-20", endDate: "2026-07-20" */)
    #expect(BookingMatch.classify(prospect: p, booking: booking, sentAt: nil) == BookingOutcome.none)
}
```

(Match the real `classify` signature and return type from `BookingMatch.swift`; use the suite's existing prospect/booking builders.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test`
Expected: FAIL — the second-night/range cases don't match under the current exact-date guard.

- [ ] **Step 3: Generalize the date guard**

Replace the single-date containment (currently `perfDate >= booking.startDate && perfDate <= booking.endDate`) with range overlap:

```swift
let runStart = perfDate
let runEnd = prospect.runEndDate ?? perfDate
guard runStart <= booking.endDate && runEnd >= booking.startDate else { return .none }
```

(Leave the causation/`sendDay` timezone logic untouched — that's #115/#116.)

- [ ] **Step 4: Run to verify it passes**

Run: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add mac/Overture/Domain/BookingMatch.swift mac/OvertureTests/BookingMatchTests.swift
git commit -m "Match a booking against a run's full date range (#132)"
```

---

### Task 7: Display the run range and related-run note

**Files:**
- Modify: `mac/Overture/UI/QueueView+Model.swift` (`QueueItem` add `runEndDate`/`partOfRelatedRun`; a `runDateLabel` helper; the `QueueItem.init(_ prospect:)` mapping)
- Modify: `mac/Overture/UI/ProspectRowView.swift` (render the range label + related note)
- Test: `mac/OvertureTests/QueueModelTests.swift`

**Interfaces:**
- Consumes: `QueueItem.runEndDate`, `QueueItem.partOfRelatedRun`.
- Produces: `QueueModel.runDateLabel(start: String?, end: String?) -> String` ("Jun 25–28" for a range, the single date otherwise); `QueueModel.relatedRunNote(_ item: QueueItem) -> String?`.

- [ ] **Step 1: Write the failing test**

```swift
@Suite("Run display")
struct RunDisplayTests {
    @Test func formatsADateRangeWhenRunSpansNights() {
        #expect(QueueModel.runDateLabel(start: "2026-06-25", end: "2026-06-28") == "Jun 25–28")
    }
    @Test func showsSingleDateWhenNoRange() {
        #expect(QueueModel.runDateLabel(start: "2026-06-25", end: nil) == "Jun 25")
    }
    @Test func relatedRunNoteOnlyWhenFlagged() {
        var run = item(performanceDate: "2026-06-25"); run.partOfRelatedRun = true
        #expect(QueueModel.relatedRunNote(run) != nil)
        #expect(QueueModel.relatedRunNote(item(performanceDate: "2026-06-25")) == nil)
    }
}
```

(Extend the existing `item(...)` test helper in `QueueModelTests.swift` with a defaulted `partOfRelatedRun` param, and add `runEndDate`/`partOfRelatedRun` to the `QueueItem` initializer call there.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test`
Expected: FAIL — `runDateLabel`/`relatedRunNote`/`partOfRelatedRun` not found.

- [ ] **Step 3: Implement**

Add to `QueueItem` (in `QueueView+Model.swift`): `var runEndDate: String? = nil` and `var partOfRelatedRun: Bool = false`, and map them in `QueueItem.init(_ prospect: Prospect)`.

Add to `QueueModel` (reuse the file's existing `eastern`/`day`/month helpers):

```swift
static func runDateLabel(start: String?, end: String?) -> String {
    guard let start, let d = day(start) else { return "Date to be confirmed" }
    let cal = easternCalendar
    let startLabel = "\(shortMonth(cal.component(.month, from: d))) \(cal.component(.day, from: d))"
    guard let end, end != start, let e = day(end) else { return startLabel }
    let sameMonth = cal.component(.month, from: d) == cal.component(.month, from: e)
    let endLabel = sameMonth ? "\(cal.component(.day, from: e))" : "\(shortMonth(cal.component(.month, from: e))) \(cal.component(.day, from: e))"
    return "\(startLabel)–\(endLabel)"
}

static func relatedRunNote(_ item: QueueItem) -> String? {
    item.partOfRelatedRun ? "This group also performs at this venue on other dates" : nil
}
```

In `ProspectRowView.swift`, where the date/timing renders, use `runDateLabel(start: item.performanceDate, end: item.runEndDate)` and show `relatedRunNote(item)` (when non-nil) as a quiet caption like the existing history-flag line.

- [ ] **Step 4: Run to verify it passes**

Run: `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test`
Expected: PASS (full suite green).

- [ ] **Step 5: Commit**

```bash
git add mac/Overture/UI/QueueView+Model.swift mac/Overture/UI/ProspectRowView.swift mac/OvertureTests/QueueModelTests.swift
git commit -m "Show the run date range and related-run note in the queue (#132)"
```

---

## Final verification

- [ ] `pnpm test && pnpm typecheck` green (engine).
- [ ] `cd mac && xcodebuild -scheme Overture -destination 'platform=macOS' test` green (app).
- [ ] Push the branch and open a PR: `Closes #132`.
- [ ] Flag for Dan: eyeball a real scout — a known multi-night run shows as one entry with a range; a same-venue org with separate dates shows the related note.
