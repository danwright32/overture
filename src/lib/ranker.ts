// Fit-score ranker for Overture. Pure, deterministic scoring of an already-classified
// candidate. The upstream scout/Claude does the classification (self vs agency,
// discipline, coverage, reachability); this function only scores. See PLAN.md section 4.

export type Candidate = {
  reachable: boolean;
  priorRelationship: "booked" | "contacted" | "none";
  production: "self" | "agency" | "unknown";
  profile: "strong" | "weak" | "neutral";
  coverage: "likely_uncovered" | "likely_covered" | "unknown";
  discipline:
    | "dance"
    | "opera"
    | "theater"
    | "choral"
    | "music"
    | "band"
    | "comedy"
    | "other";
};

export type Tier = "high" | "longshot";

export type FitResult = {
  excluded: boolean;
  score: number;
  tier: Tier;
};

// The high tier gets the deep effort (named decision-maker, full personalization,
// the 3-touch follow-up); longshots get the lighter touch. A strong cold prospect
// (a couple of positive signals) clears this; a flat-neutral or dead-zone one does not.
const HIGH_TIER_THRESHOLD = 5;

// Prior warm relationship is Dan's top weight. A prior booking is sized to
// dominate every other signal combined, so a warm contact always outranks any
// cold prospect. A prior cold contact is only a mild nudge.
const PRIOR_RELATIONSHIP_POINTS: Record<Candidate["priorRelationship"], number> = {
  booked: 20,
  contacted: 3,
  none: 0,
};

// Self-produced groups convert; agency- or management-routed almost never do.
const PRODUCTION_POINTS: Record<Candidate["production"], number> = {
  self: 2,
  unknown: 0,
  agency: -2,
};

// Choir / school / youth-or-community ensemble / small company (strong) vs
// the competition-winner showcase rental (weak).
const PROFILE_POINTS: Record<Candidate["profile"], number> = {
  strong: 2,
  neutral: 0,
  weak: -2,
};

// A small self-produced show is likely uncovered; a prestige mainstage or
// touring act usually travels with its own shooter.
const COVERAGE_POINTS: Record<Candidate["coverage"], number> = {
  likely_uncovered: 2,
  unknown: 0,
  likely_covered: -2,
};

// Music is the baseline Dan keeps steady. Every other discipline is preferred
// and boosted: dance highest (his portfolio there is nearly empty), opera and
// theater explicitly above music, the rest a modest boost. "other"/unknown
// stays at baseline since there is no discipline signal to act on.
const DISCIPLINE_POINTS: Record<Candidate["discipline"], number> = {
  dance: 3,
  opera: 2,
  theater: 2,
  choral: 1,
  band: 1,
  comedy: 1,
  music: 0,
  other: 0,
};

export function scoreFit(candidate: Candidate): FitResult {
  const score =
    PRIOR_RELATIONSHIP_POINTS[candidate.priorRelationship] +
    PRODUCTION_POINTS[candidate.production] +
    PROFILE_POINTS[candidate.profile] +
    COVERAGE_POINTS[candidate.coverage] +
    DISCIPLINE_POINTS[candidate.discipline];
  const tier: Tier = score >= HIGH_TIER_THRESHOLD ? "high" : "longshot";
  return { excluded: !candidate.reachable, score, tier };
}
