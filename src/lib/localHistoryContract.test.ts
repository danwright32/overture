import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { parseLocalHistory } from "./localHistory";

// Shared cross-language contract fixture (#166), mirroring the #113 Downbeat guard. The SAME
// committed JSON is decoded here (the TS scout, via parseLocalHistory) and by the Swift app
// (mac/OvertureTests/LocalHistoryContractTests.swift, via [HistoryRecord]). A format change one
// reader hasn't caught up to fails a test instead of silently reading undefined and treating every
// org as cold in production (the #104 / #109 trap: the file is camelCase, the matcher is snake_case).
const fixture = (name: string) =>
  readFileSync(
    fileURLToPath(new URL(`../../fixtures/local-history/${name}`, import.meta.url)),
    "utf8",
  );

describe("Local history contract fixtures", () => {
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
