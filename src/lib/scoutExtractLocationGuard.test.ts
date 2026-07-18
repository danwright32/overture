import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  findViolations,
  looksLikeBareLocation,
  type Extraction,
  type ViolationKind,
} from "./scoutExtractLocationGuard";

// Regression harness for docs/scout-extract-runbook.md's location rules (#988).
//
// The scout-extract run is a Claude Code workflow, not code, so the runbook plus these fixtures
// are its only spec (like fixtures/discipline-corpus/, nothing reads this corpus at runtime). The
// real agent is run against the gold corpus only periodically, because it costs a real run. What
// runs on every PR, cheaply and deterministically, is this: the rules the runbook cares about are
// encoded as pure checkers, the gold corpus proves the runbook's own worked examples pass them,
// and a companion corpus of the exact forbidden extractions proves each checker actually fires.
// The failure corpus is the permanent "seen it go red": if a checker silently stops flagging a
// violation, one of these cases turns green and the suite fails.

const corpusDir = fileURLToPath(new URL("../../fixtures/scout-extract-corpus/", import.meta.url));

interface GoldCase {
  id: string;
  runbook: string;
  pageText: string;
  venue: string | null;
  location: string | null;
}

interface ViolationCase extends GoldCase {
  why: string;
  expectViolation: ViolationKind;
}

function readCorpus<T>(filename: string): { version: number; cases: T[] } {
  return JSON.parse(readFileSync(`${corpusDir}${filename}`, "utf8"));
}

const gold = readCorpus<GoldCase>("location-cases.json");
const violations = readCorpus<ViolationCase>("violation-cases.json");

const extraction = (c: GoldCase): Extraction => ({ venue: c.venue, location: c.location });

describe("scout-extract location gold corpus", () => {
  it("has unique case ids", () => {
    const ids = gold.cases.map((c) => c.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  // The corpus must not silently shrink: every worked example the runbook (3a) writes out has a
  // gold case, so deleting one fails here rather than quietly narrowing coverage (measured-counts
  // -go-stale, so this asserts presence of the load-bearing cases, not a bare total).
  const requiredIds = [
    "baltimore-maryland-verbatim",
    "harrogate-uk-verbatim",
    "amsterdam-no-country",
    "southern-norway-region",
    "multi-city-string",
    "berlin-full-address",
    "no-location-is-null",
    "sakura-park-named-outdoor-venue",
    "downtown-brooklyn-is-location-only",
    "baltimore-city-is-location-only",
  ];
  for (const id of requiredIds) {
    it(`keeps the runbook worked example: ${id}`, () => {
      expect(gold.cases.some((c) => c.id === id)).toBe(true);
    });
  }

  for (const c of gold.cases) {
    it(`obeys the runbook: ${c.id}`, () => {
      expect(findViolations(c.pageText, extraction(c))).toEqual([]);
    });
  }
});

describe("scout-extract location violation corpus", () => {
  it("covers both violation kinds", () => {
    const kinds = new Set(violations.cases.map((c) => c.expectViolation));
    expect(kinds).toEqual(new Set<ViolationKind>(["location-not-verbatim", "location-in-venue"]));
  });

  for (const c of violations.cases) {
    it(`flags the forbidden extraction: ${c.id}`, () => {
      const found = findViolations(c.pageText, extraction(c)).map((v) => v.kind);
      expect(found).toContain(c.expectViolation);
    });
  }
});

describe("location verbatim rule (3a)", () => {
  it("passes a location that only differs from the page by whitespace reflow", () => {
    // Normalized HTML can put a newline where the page had a space; that is not a normalization
    // the run made, so it must not be flagged.
    const page = "Guest soloist\n   Baltimore, Maryland   Nov 14";
    expect(findViolations(page, { venue: null, location: "Baltimore, Maryland" })).toEqual([]);
  });

  it("flags a state name shortened to its two-letter abbreviation", () => {
    const page = "Guest soloist Baltimore, Maryland Nov 14";
    const found = findViolations(page, { venue: null, location: "Baltimore, MD" }).map((v) => v.kind);
    expect(found).toContain("location-not-verbatim");
  });

  it("flags a country appended to a bare city", () => {
    const page = "Concertgebouw Amsterdam Dec 2";
    const found = findViolations(page, { venue: null, location: "Amsterdam, Netherlands" }).map(
      (v) => v.kind,
    );
    expect(found).toContain("location-not-verbatim");
  });

  it("flags a city guessed from the org when the page names none", () => {
    const page = "Smoke Ring Quartet Gigs Oct 30";
    const found = findViolations(page, { venue: null, location: "New York, NY" }).map((v) => v.kind);
    expect(found).toContain("location-not-verbatim");
  });

  it("treats a null location as always allowed", () => {
    expect(findViolations("any page text", { venue: null, location: null })).toEqual([]);
  });
});

describe("looksLikeBareLocation (the venue-vs-location bar is not vacuous)", () => {
  // The runbook's own table: a named place (with its own proper name) is a venue; a bare
  // place-only string is a location and must never sit in venue. Both directions are asserted so
  // the heuristic cannot pass by flagging everything or nothing.
  const namedVenues = [
    "Weill Recital Hall",
    "Harrogate Convention Centre",
    "Sakura Park, W 122nd St & Riverside Dr",
    "Greeley Square",
    "Brooklyn Bridge Park Boathouse at Pier 5, Brooklyn, NY",
    "Concertgebouw",
  ];
  for (const v of namedVenues) {
    it(`does not treat a named venue as a bare location: ${v}`, () => {
      expect(looksLikeBareLocation(v)).toBe(false);
    });
  }

  const bareLocations = ["Baltimore, Maryland", "Harrogate, UK", "downtown Brooklyn, NY", "New York, NY"];
  for (const l of bareLocations) {
    it(`treats a place-only string as a bare location: ${l}`, () => {
      expect(looksLikeBareLocation(l)).toBe(true);
    });
  }
});
