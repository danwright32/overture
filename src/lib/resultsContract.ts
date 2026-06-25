// The scout results wire contract: turns ranked ProspectRow[] into the exact JSON the Mac app
// ingests (Swift ResultsFileDecoder). Extracted from run-scout.ts so the writer side is pure
// and testable against the shared fixtures (#157), mirroring how parseDownbeatExport anchors
// the #113 Downbeat guard. A format change here fails resultsContract.test.ts (and the Swift
// ResultsContractTests) instead of silently breaking ingestion in production (the #109 trap).

import type { ProspectRow } from "./assembleProspect";
import { groupIntoRuns } from "./runGrouping";

export const RESULTS_VERSION = 2;

export type WireProspect = {
  groupName: string;
  discipline: string;
  venue: string | null;
  performanceDate: string | null;
  sourceListingUrl: string | null;
  websiteUrl: string | null;
  priorRelationship: string;
  production: string;
  profile: string;
  coverage: string;
  fitScore: number;
  tier: string;
  fitReason: string;
  matchedClientName: string | null;
  possibleMatchSource: string | null;
  possibleMatchName: string | null;
  runEndDate: string | null;
  partOfRelatedRun: boolean;
  runSourceUrls: string[];
};

export type ResultsFile = {
  version: number;
  generatedAt: string;
  prospects: WireProspect[];
};

// The snake_case engine row -> the camelCase wire base (no run fields yet). Only the fields the
// reader contract carries; reachable/downbeat_client_id/possible_match_ref/status stay internal.
export function serializeProspect(row: ProspectRow) {
  return {
    groupName: row.group_name,
    discipline: row.discipline,
    venue: row.venue,
    performanceDate: row.performance_date,
    sourceListingUrl: row.source_listing_url,
    websiteUrl: row.website_url,
    priorRelationship: row.prior_relationship,
    production: row.production,
    profile: row.profile,
    coverage: row.coverage,
    fitScore: row.fit_score,
    tier: row.tier,
    fitReason: row.fit_reason,
    matchedClientName: row.matched_client_name,
    possibleMatchSource: row.possible_match_source,
    possibleMatchName: row.possible_match_name,
  };
}

export function buildResultsFile(rows: ProspectRow[], generatedAt: string): ResultsFile {
  // Serialize, then collapse multi-night runs. groupIntoRuns returns the internal `runSourceURLs`
  // (capital); emit only the lowercase `runSourceUrls` the reader expects, with no stray key.
  const runs = groupIntoRuns(rows.map(serializeProspect));
  const prospects: WireProspect[] = runs.map(({ runSourceURLs, ...rest }) => ({
    ...rest,
    runSourceUrls: runSourceURLs,
  }));

  // Soonest performance first; undated last; ties broken by fit score descending.
  prospects.sort((a, b) => {
    const da = a.performanceDate ?? "9999-99-99";
    const db = b.performanceDate ?? "9999-99-99";
    if (da !== db) return da < db ? -1 : 1;
    return b.fitScore - a.fitScore;
  });

  return { version: RESULTS_VERSION, generatedAt, prospects };
}
