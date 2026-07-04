import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { scoreFit, type Candidate } from "./ranker";

type RankerFixtureCase = {
  description: string;
  candidate: Candidate;
  expectedExcluded: boolean;
  expectedScore: number;
  expectedTier: "high" | "longshot";
};

const rankerCases: RankerFixtureCase[] = JSON.parse(
  readFileSync(
    fileURLToPath(new URL("../../fixtures/ranker/cases.json", import.meta.url)),
    "utf8",
  ),
);

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

  it("treats a cold contact as neutral, not warm (#70): a bare send that got silence scores the same as a never contacted org", () => {
    const contacted = scoreFit(candidate({ priorRelationship: "contacted" }));
    const none = scoreFit(candidate({ priorRelationship: "none" }));
    expect(contacted.score).toBe(none.score);
  });

  it("ranks declined_by_you, warm, and lost_soft on the locked ladder (#70): all below booked, contacted and lost_hard clearly separated at the bottom", () => {
    const booked = scoreFit(candidate({ priorRelationship: "booked" }));
    const declinedByYou = scoreFit(candidate({ priorRelationship: "declined_by_you" }));
    const warm = scoreFit(candidate({ priorRelationship: "warm" }));
    const lostSoft = scoreFit(candidate({ priorRelationship: "lost_soft" }));
    const contacted = scoreFit(candidate({ priorRelationship: "contacted" }));
    const lostHard = scoreFit(candidate({ priorRelationship: "lost_hard" }));
    expect(booked.score).toBeGreaterThan(declinedByYou.score);
    expect(declinedByYou.score).toBeGreaterThan(warm.score);
    expect(warm.score).toBeGreaterThan(lostSoft.score);
    expect(lostSoft.score).toBeGreaterThan(contacted.score);
    expect(contacted.score).toBeGreaterThan(lostHard.score);
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

// Shared cross-language scoring fixture (#490). Ranker.swift is a hand port of this file (the app
// scouts natively; this engine is a reference mirror, see docs/scout-runbook.md), so the two pure
// scoring functions need to agree even though neither reads the other's output at runtime. The
// SAME cases decoded here are decoded by mac/OvertureTests/RankerTests.swift, so a one sided change
// to either side's point table fails whichever suite did not make the matching change.
describe("scoreFit shared ranker fixture", () => {
  it.each(rankerCases.map((c) => [c.description, c] as const))(
    "%s",
    (_description, testCase) => {
      const result = scoreFit(testCase.candidate);
      expect(result.excluded).toBe(testCase.expectedExcluded);
      expect(result.score).toBe(testCase.expectedScore);
      expect(result.tier).toBe(testCase.expectedTier);
    },
  );
});
