import { describe, it, expect } from "vitest";
import { scoreFit, type Candidate } from "./ranker";

// A neutral baseline candidate. Each test overrides only the signal it exercises.
function candidate(overrides: Partial<Candidate> = {}): Candidate {
  return {
    reachable: true,
    priorRelationship: "none",
    production: "unknown",
    profile: "neutral",
    coverage: "unknown",
    discipline: "music",
    ...overrides,
  };
}

describe("scoreFit geography gate", () => {
  it("excludes a candidate at a venue Dan cannot reach", () => {
    const result = scoreFit(candidate({ reachable: false }));
    expect(result.excluded).toBe(true);
  });

  it("does not exclude a candidate at a reachable venue", () => {
    const result = scoreFit(candidate({ reachable: true }));
    expect(result.excluded).toBe(false);
  });
});
