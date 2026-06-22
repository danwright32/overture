// Produces the results-file handoff the native Overture app ingests: runs the
// curated real events through the full foundation (match -> rank -> assemble) and
// writes a JSON file of fully-formed, ranked prospects. This is the prototype of
// what the scout run's final stage will emit; for now it is the dev bridge that
// gives the Mac app real data to develop against.
//
//   pnpm tsx scripts/export-results.ts
//
// Writes to ~/Library/Application Support/Overture/overture-results.json (the
// handoff location, sibling to Downbeat's downbeat-export.json) and also prints
// the JSON so it can be captured as a test fixture.

import { writeFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { readFileSync } from "node:fs";
import { loadDownbeatExport } from "../src/lib/downbeatBridge";
import { matchRelationship } from "../src/lib/historyMatch";
import { decideProspect } from "../src/lib/assembleProspect";
import { createRepo } from "../src/lib/prospectsRepo";
import { SEED_EVENTS } from "./seed-events";

const RESULTS_VERSION = 1;

function loadEnv(path = ".env.local"): Record<string, string> {
  const env: Record<string, string> = {};
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const s = line.replace(/\r$/, "");
    if (s.trimStart().startsWith("#") || !s.includes("=")) continue;
    const i = s.indexOf("=");
    env[s.slice(0, i).trim()] = s.slice(i + 1).trim();
  }
  return env;
}

// camelCase wire shape the Swift app decodes. Fully-formed, ranked prospects.
type ResultProspect = {
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
};

async function main() {
  const env = loadEnv();
  const url = env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceKey) {
    console.error("Missing Supabase env in .env.local");
    process.exit(1);
  }

  const { clients, venues } = loadDownbeatExport();
  const repo = createRepo(url, serviceKey);
  const [history, blocked] = await Promise.all([
    repo.loadHistory(),
    repo.loadBlockedDates(),
  ]);

  const prospects: ResultProspect[] = [];
  for (const { event, classification } of SEED_EVENTS) {
    const verdict = matchRelationship(event.group_name, clients, history);
    const decision = decideProspect(event, classification, verdict, blocked);
    if (decision.kind !== "prospect") continue;
    const r = decision.row;
    prospects.push({
      groupName: r.group_name,
      discipline: r.discipline,
      venue: r.venue,
      performanceDate: r.performance_date,
      sourceListingUrl: r.source_listing_url,
      websiteUrl: r.website_url,
      priorRelationship: r.prior_relationship,
      production: r.production,
      profile: r.profile,
      coverage: r.coverage,
      fitScore: r.fit_score,
      tier: r.tier,
      fitReason: r.fit_reason,
      matchedClientName: r.matched_client_name,
      possibleMatchSource: r.possible_match_source,
      possibleMatchName: r.possible_match_name,
    });
  }

  // Sort the queue order the app reads: performance date ascending, fit desc.
  prospects.sort((a, b) => {
    const da = a.performanceDate ?? "9999-99-99";
    const db = b.performanceDate ?? "9999-99-99";
    if (da !== db) return da < db ? -1 : 1;
    return b.fitScore - a.fitScore;
  });

  const file = {
    version: RESULTS_VERSION,
    generatedAt: new Date().toISOString(),
    prospects,
  };
  const json = JSON.stringify(file, null, 2);

  const outPath = join(
    homedir(),
    "Library",
    "Application Support",
    "Overture",
    "overture-results.json",
  );
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, json + "\n", "utf8");

  console.log(`Wrote ${prospects.length} prospects to ${outPath}`);
  console.log(json);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
