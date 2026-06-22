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

export type FitResult = {
  excluded: boolean;
};

export function scoreFit(candidate: Candidate): FitResult {
  return { excluded: !candidate.reachable };
}
