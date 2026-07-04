import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { normalizeGroupName, isConfidentMatch, isPossibleMatch } from "./groupNameMatch";

interface NormalizeCase {
  input: string;
  expected: string;
}

interface MatchCase {
  a: string;
  b: string;
  confident: boolean;
  possible: boolean;
}

interface GroupNameFixture {
  normalize: NormalizeCase[];
  match: MatchCase[];
}

// The shared cross-language drift guard (#492). The SAME committed cases the Swift side asserts
// (mac/OvertureTests/GroupNameDriftTests.swift) are asserted here against this side's own
// implementation, so a one-sided change to normalization or matching fails this test (or the
// Swift one) instead of silently reclassifying a warm past client as cold with nothing catching
// it. See fixtures/group-name-match/README.md.
const fixture = JSON.parse(
  readFileSync(
    fileURLToPath(new URL("../../fixtures/group-name-match/v1.json", import.meta.url)),
    "utf8",
  ),
) as GroupNameFixture;

describe("Group-name match cross-language fixture", () => {
  it.each(fixture.normalize)("normalizes $input to $expected", ({ input, expected }) => {
    expect(normalizeGroupName(input)).toBe(expected);
  });

  it.each(fixture.match)(
    "matches $a against $b the agreed way",
    ({ a, b, confident, possible }) => {
      expect(isConfidentMatch(a, b)).toBe(confident);
      expect(isPossibleMatch(a, b)).toBe(possible);
    },
  );
});
