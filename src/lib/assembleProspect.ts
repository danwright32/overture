// Turns a discovered+classified performance plus its match verdict into a scored
// prospect row, or a "skip" for anything that should never surface (blocked date,
// DNC-suppressed group, or unreachable venue). The score and tier come from the
// ranker; a "possible" match rides along for review without affecting the score.

import { scoreFit, type Candidate } from "./ranker";
import type { MatchVerdict } from "./historyMatch";
import { isBlockedDate } from "./blockedDates";

export type DiscoveredEvent = {
  group_name: string;
  discipline: Candidate["discipline"];
  venue: string | null;
  performance_date: string | null;
  source_listing_url: string | null;
  website_url: string | null;
};

export type Classification = {
  reachable: boolean;
  production: Candidate["production"];
  profile: Candidate["profile"];
  coverage: Candidate["coverage"];
  fit_reason: string;
};

export type ProspectRow = {
  group_name: string;
  discipline: string;
  venue: string | null;
  performance_date: string | null;
  source_listing_url: string | null;
  website_url: string | null;
  reachable: boolean;
  prior_relationship: string;
  production: string;
  profile: string;
  coverage: string;
  fit_score: number;
  tier: string;
  fit_reason: string;
  downbeat_client_id: string | null;
  matched_client_name: string | null;
  possible_match_source: string | null;
  possible_match_ref: string | null;
  possible_match_name: string | null;
  status: "new";
};

export type Decision =
  | { kind: "prospect"; row: ProspectRow }
  | { kind: "skip"; reason: "blocked" | "suppressed" | "unreachable" };

export function decideProspect(
  event: DiscoveredEvent,
  classification: Classification,
  verdict: MatchVerdict,
  blocked: Set<string>,
): Decision {
  if (isBlockedDate(event.performance_date, blocked)) {
    return { kind: "skip", reason: "blocked" };
  }
  if (verdict.suppressed) {
    return { kind: "skip", reason: "suppressed" };
  }

  const candidate: Candidate = {
    reachable: classification.reachable,
    priorRelationship: verdict.relationship,
    production: classification.production,
    profile: classification.profile,
    coverage: classification.coverage,
    discipline: event.discipline,
  };
  const fit = scoreFit(candidate);
  if (fit.excluded) {
    return { kind: "skip", reason: "unreachable" };
  }

  return {
    kind: "prospect",
    row: {
      group_name: event.group_name,
      discipline: event.discipline,
      venue: event.venue,
      performance_date: event.performance_date,
      source_listing_url: event.source_listing_url,
      website_url: event.website_url,
      reachable: classification.reachable,
      prior_relationship: verdict.relationship,
      production: classification.production,
      profile: classification.profile,
      coverage: classification.coverage,
      fit_score: fit.score,
      tier: fit.tier,
      fit_reason: classification.fit_reason,
      downbeat_client_id: verdict.downbeatClientId,
      matched_client_name: verdict.matchedClientName,
      possible_match_source: verdict.possible ? verdict.possible.source : null,
      // History rows have no id, so their ref is empty; emit null (the column is a
      // uuid and would reject ""). Downbeat client refs are real uuids.
      possible_match_ref:
        verdict.possible && verdict.possible.ref ? verdict.possible.ref : null,
      possible_match_name: verdict.possible ? verdict.possible.name : null,
      status: "new",
    },
  };
}
