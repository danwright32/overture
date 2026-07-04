import { describe, it, expect } from "vitest";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { parseLocalHistory } from "./localHistory";

// Shared cross-language contract fixture (#166), mirroring the #113 Downbeat guard. The SAME
// committed JSON is decoded here (the TS scout, via parseLocalHistory) and by the Swift app
// (mac/OvertureTests/LocalHistoryContractTests.swift, via [HistoryRecord]). A format change one
// reader hasn't caught up to fails a test instead of silently reading undefined and treating every
// org as cold in production (the #104 / #109 trap: the file is camelCase, the matcher is snake_case).
const FIXTURE_DIR = new URL("../../fixtures/local-history/", import.meta.url);
const fixture = (name: string) => readFileSync(new URL(name, FIXTURE_DIR), "utf8");
const fixtureFiles = readdirSync(fileURLToPath(FIXTURE_DIR)).filter((name) =>
  name.endsWith(".json"),
);

describe("Local history contract fixtures", () => {
  // #491: enumerates whatever is actually committed, so a new fixture file with no matching
  // decode case fails here instead of silently shipping with zero coverage on this side.
  it("has at least one committed fixture file", () => {
    expect(fixtureFiles.length).toBeGreaterThan(0);
  });

  it.each(fixtureFiles)("decodes %s without throwing", (name) => {
    expect(() => parseLocalHistory(fixture(name))).not.toThrow();
  });

  it("decodes the v1 fixture and bridges camelCase to the matcher's snake_case", () => {
    const out = parseLocalHistory(fixture("v1.json"));
    expect(out).toHaveLength(6);

    // The matcher reads group_name (snake_case); groupName must NOT survive, or matching and
    // DNC suppression silently read undefined (#104).
    expect(out[0]).toEqual({ group_name: "Aurora Strings", status: "booked" });
    expect((out[0] as Record<string, unknown>).groupName).toBeUndefined();

    // The full status vocabulary the ranker understands, plus a null status (decodes to cold).
    expect(out.map((r) => r.status)).toEqual([
      "booked",
      "dnc",
      "lost_soft",
      "warm",
      "contacted",
      null,
    ]);
    expect(out[5].group_name).toBe("Unknown Status Co");
  });
});
