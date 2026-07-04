import { describe, it, expect } from "vitest";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { buildResultsFile } from "./resultsContract";
import type { ProspectRow } from "./assembleProspect";

// Shared cross-language contract fixtures (#157), mirroring the #113 Downbeat guard. The SAME
// committed JSON the Swift reader decodes (mac/OvertureTests/ResultsContractTests.swift) is the
// EXACT output buildResultsFile produces here, so a format change on the writer side fails this
// test (or the Swift one) instead of silently breaking ingestion in production (the #109 trap).
const FIXTURE_DIR = new URL("../../fixtures/scout-results/", import.meta.url);
const fixture = (name: string) => readFileSync(new URL(name, FIXTURE_DIR), "utf8");
const fixtureFiles = readdirSync(fileURLToPath(FIXTURE_DIR)).filter((name) =>
  name.endsWith(".json"),
);

// The generatedAt the v2 fixture was baked with; passed in so the writer stays deterministic.
const GENERATED_AT = "2026-06-25T00:00:00.000Z";

// A row carries snake_case engine fields; only the ones buildResultsFile reads matter here.
function row(over: Partial<ProspectRow>): ProspectRow {
  return {
    group_name: "X",
    discipline: "music",
    venue: null,
    performance_date: null,
    source_listing_url: null,
    website_url: null,
    reachable: true,
    prior_relationship: "cold",
    production: "concert",
    profile: "professional",
    coverage: "full",
    fit_score: 0,
    tier: "C",
    fit_reason: "",
    downbeat_client_id: null,
    matched_client_name: null,
    possible_match_source: null,
    possible_match_ref: null,
    possible_match_name: null,
    status: "new",
    ...over,
  };
}

// Two nights of one run (collapse to opening night), a separate later run of the same group
// (partOfRelatedRun), and an undated prospect (sorts last, empty run source list).
const SAMPLE_ROWS: ProspectRow[] = [
  row({
    group_name: "Aurora Strings",
    venue: "Carnegie Hall",
    performance_date: "2026-03-10",
    source_listing_url: "https://example.org/aurora-10",
    website_url: "https://aurorastrings.example",
    prior_relationship: "warm",
    coverage: "full",
    fit_score: 88,
    tier: "A",
    fit_reason: "Repeat-client-adjacent ensemble at a flagship venue.",
    matched_client_name: "Aurora Strings",
  }),
  row({
    group_name: "Aurora Strings",
    venue: "Carnegie Hall",
    performance_date: "2026-03-11",
    source_listing_url: "https://example.org/aurora-11",
    website_url: "https://aurorastrings.example",
    prior_relationship: "warm",
    coverage: "full",
    fit_score: 88,
    tier: "A",
    fit_reason: "Repeat-client-adjacent ensemble at a flagship venue.",
    matched_client_name: "Aurora Strings",
  }),
  row({
    group_name: "Aurora Strings",
    venue: "Carnegie Hall",
    performance_date: "2026-03-20",
    source_listing_url: "https://example.org/aurora-20",
    website_url: "https://aurorastrings.example",
    prior_relationship: "warm",
    coverage: "full",
    fit_score: 80,
    tier: "B",
    fit_reason: "Later run of the same ensemble.",
    matched_client_name: "Aurora Strings",
  }),
  row({
    group_name: "Lumen Dance",
    discipline: "dance",
    prior_relationship: "cold",
    production: "showcase",
    coverage: "partial",
    fit_score: 55,
    tier: "C",
    fit_reason: "Possible match on a presenter name; unconfirmed.",
    possible_match_source: "instagram",
    possible_match_name: "Lumen Dance Collective",
  }),
];

describe("Scout results contract fixtures", () => {
  // #491: this side only ever writes the current version, so there is no TS decoder to run
  // against older fixtures (the Swift reader owns decoding, including the tolerant version
  // gate). Enumerating the directory still catches a malformed or incomplete committed file,
  // so a new fixture with no matching coverage on this side does not ship unnoticed.
  it("has at least one committed fixture file", () => {
    expect(fixtureFiles.length).toBeGreaterThan(0);
  });

  it.each(fixtureFiles)("has the documented top-level shape in %s", (name) => {
    const parsed: unknown = JSON.parse(fixture(name));
    expect(typeof parsed).toBe("object");
    const file = parsed as { version?: unknown; prospects?: unknown };
    expect(typeof file.version).toBe("number");
    expect(Array.isArray(file.prospects)).toBe(true);
  });

  it("writes exactly the committed v2 fixture from the sample rows", () => {
    const out = buildResultsFile(SAMPLE_ROWS, GENERATED_AT);
    expect(out).toEqual(JSON.parse(fixture("v2.json")));
  });

  it("collapses runs, flags related runs, and sorts the same way the reader expects", () => {
    const out = buildResultsFile(SAMPLE_ROWS, GENERATED_AT);
    expect(out.version).toBe(2);
    expect(out.prospects).toHaveLength(3);

    // Opening night of the collapsed run, with both nights' source URLs and the closing date.
    expect(out.prospects[0].performanceDate).toBe("2026-03-10");
    expect(out.prospects[0].runEndDate).toBe("2026-03-11");
    expect(out.prospects[0].partOfRelatedRun).toBe(true);
    expect(out.prospects[0].runSourceUrls).toEqual([
      "https://example.org/aurora-10",
      "https://example.org/aurora-11",
    ]);

    // The later, separate run of the same group: single night, still flagged related.
    expect(out.prospects[1].performanceDate).toBe("2026-03-20");
    expect(out.prospects[1].runEndDate).toBeNull();
    expect(out.prospects[1].partOfRelatedRun).toBe(true);

    // Undated prospect sorts last, with absent optionals as null and no run sources.
    expect(out.prospects[2].groupName).toBe("Lumen Dance");
    expect(out.prospects[2].venue).toBeNull();
    expect(out.prospects[2].performanceDate).toBeNull();
    expect(out.prospects[2].partOfRelatedRun).toBe(false);
    expect(out.prospects[2].runSourceUrls).toEqual([]);
  });
});
