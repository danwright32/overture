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

describe("scoreFit prior relationship (top weight)", () => {
  it("scores a fully neutral candidate at zero", () => {
    expect(scoreFit(candidate()).score).toBe(0);
  });

  it("ranks a previously booked group above one with no prior history", () => {
    const booked = scoreFit(candidate({ priorRelationship: "booked" }));
    const none = scoreFit(candidate({ priorRelationship: "none" }));
    expect(booked.score).toBeGreaterThan(none.score);
  });

  it("ranks a previously cold-contacted group above none but below booked", () => {
    const contacted = scoreFit(candidate({ priorRelationship: "contacted" }));
    const none = scoreFit(candidate({ priorRelationship: "none" }));
    const booked = scoreFit(candidate({ priorRelationship: "booked" }));
    expect(contacted.score).toBeGreaterThan(none.score);
    expect(contacted.score).toBeLessThan(booked.score);
  });

  it("treats a prior booking as the dominant signal: a booked group outranks a cold group that is strong on every other signal", () => {
    const booked = scoreFit(candidate({ priorRelationship: "booked" }));
    const strongCold = scoreFit(
      candidate({
        priorRelationship: "none",
        production: "self",
        profile: "strong",
        coverage: "likely_uncovered",
        discipline: "dance",
      }),
    );
    expect(booked.score).toBeGreaterThan(strongCold.score);
  });
});

describe("scoreFit production (self vs agency)", () => {
  it("rewards self-produced and penalizes agency-routed, with unknown between", () => {
    const self = scoreFit(candidate({ production: "self" }));
    const unknown = scoreFit(candidate({ production: "unknown" }));
    const agency = scoreFit(candidate({ production: "agency" }));
    expect(self.score).toBeGreaterThan(unknown.score);
    expect(unknown.score).toBeGreaterThan(agency.score);
  });
});

describe("scoreFit profile match", () => {
  it("rewards a strong profile and penalizes a weak one, with neutral between", () => {
    const strong = scoreFit(candidate({ profile: "strong" }));
    const neutral = scoreFit(candidate({ profile: "neutral" }));
    const weak = scoreFit(candidate({ profile: "weak" }));
    expect(strong.score).toBeGreaterThan(neutral.score);
    expect(neutral.score).toBeGreaterThan(weak.score);
  });
});

describe("scoreFit coverage", () => {
  it("rewards likely-uncovered and penalizes likely-covered, with unknown between", () => {
    const uncovered = scoreFit(candidate({ coverage: "likely_uncovered" }));
    const unknown = scoreFit(candidate({ coverage: "unknown" }));
    const covered = scoreFit(candidate({ coverage: "likely_covered" }));
    expect(uncovered.score).toBeGreaterThan(unknown.score);
    expect(unknown.score).toBeGreaterThan(covered.score);
  });
});

describe("scoreFit discipline preference", () => {
  const score = (d: Candidate["discipline"]) =>
    scoreFit(candidate({ discipline: d })).score;

  it("keeps music as the baseline (no boost or penalty)", () => {
    expect(score("music")).toBe(0);
  });

  it("ranks dance highest, above the explicitly boosted opera and theater", () => {
    expect(score("dance")).toBeGreaterThan(score("opera"));
    expect(score("dance")).toBeGreaterThan(score("theater"));
  });

  it("boosts opera and theater above music", () => {
    expect(score("opera")).toBeGreaterThan(score("music"));
    expect(score("theater")).toBeGreaterThan(score("music"));
  });

  it("boosts every other discipline above the music baseline", () => {
    expect(score("choral")).toBeGreaterThan(score("music"));
    expect(score("band")).toBeGreaterThan(score("music"));
    expect(score("comedy")).toBeGreaterThan(score("music"));
  });
});

describe("scoreFit tier", () => {
  it("puts a previously booked group in the high tier", () => {
    expect(scoreFit(candidate({ priorRelationship: "booked" })).tier).toBe("high");
  });

  it("puts a strong cold prospect in the high tier", () => {
    const strongCold = candidate({
      production: "self",
      profile: "strong",
      coverage: "likely_uncovered",
      discipline: "dance",
    });
    expect(scoreFit(strongCold).tier).toBe("high");
  });

  it("puts the dead-zone prospect (agency competition-winner, likely covered) in the longshot tier", () => {
    const deadZone = candidate({
      production: "agency",
      profile: "weak",
      coverage: "likely_covered",
    });
    expect(scoreFit(deadZone).tier).toBe("longshot");
  });

  it("puts a flat neutral prospect in the longshot tier", () => {
    expect(scoreFit(candidate()).tier).toBe("longshot");
  });
});
