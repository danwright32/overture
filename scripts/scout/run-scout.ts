// The event-scout pipeline: raw extracted events -> rule-classify -> match/rank/
// assemble -> write the results handoff the Mac app ingests. Deterministic and free;
// the rules classify the bulk and flag genuinely ambiguous events for an optional
// AI refine pass (printed at the end). See docs/scout-runbook.md.
//
//   pnpm tsx scripts/scout/run-scout.ts [events.json]
//
// Default input is scripts/scout/events.sample.json (the real Carnegie extraction).
// The live extractor (scripts/scout/extract-carnegie.js) produces this same shape
// from the bot-protected calendar via a headless browser.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { loadDownbeatExport } from "../../src/lib/downbeatBridge";
import { matchRelationship } from "../../src/lib/historyMatch";
import { decideProspect, type DiscoveredEvent, type Classification } from "../../src/lib/assembleProspect";
import { classifyEvent, type EventClassification, type ExtractedEvent } from "../../src/lib/classifyEvent";
import { applyRefinements, type EventRefinement } from "../../src/lib/refineClassifications";
import { createRepo } from "../../src/lib/prospectsRepo";

function appSupport(name: string): string {
  return join(homedir(), "Library", "Application Support", "Overture", name);
}

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

async function main() {
  const inputPath = process.argv[2] ?? "scripts/scout/events.sample.json";
  const events = JSON.parse(readFileSync(inputPath, "utf8")) as ExtractedEvent[];
  console.log(`Read ${events.length} extracted events from ${inputPath}`);

  const env = loadEnv();
  const url = env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceKey) {
    console.error("Missing Supabase env in .env.local");
    process.exit(1);
  }

  const { clients, venues } = loadDownbeatExport();
  const repo = createRepo(url, serviceKey);
  const [history, blocked] = await Promise.all([repo.loadHistory(), repo.loadBlockedDates()]);

  // Pass 1: rule-classify every event (free, instant), keyed by title.
  const byTitle = new Map<string, EventClassification>();
  for (const e of events) byTitle.set(e.title, classifyEvent(e));

  // Hand the uncertain slice to the AI refine pass — the Claude Code scout agent (#30), on
  // Dan's Max plan, not a paid API. It reads this file, re-judges each event, and writes
  // overture-refined.json; the next run merges those in. Refining only the uncertain slice
  // keeps cost near zero.
  const uncertainEvents = events.filter((e) => byTitle.get(e.title)?.confidence === "uncertain");
  writeFileSync(
    appSupport("overture-uncertain.json"),
    JSON.stringify(
      uncertainEvents.map((e) => {
        const c = byTitle.get(e.title)!;
        return {
          title: e.title, presenter: e.presenter, venue: e.venue,
          performanceDate: e.performanceDate, sourceUrl: e.sourceUrl,
          rulesGuess: { production: c.production, profile: c.profile, coverage: c.coverage, discipline: c.discipline },
        };
      }),
      null, 2,
    ) + "\n",
    "utf8",
  );

  // Merge any refinements the agent produced on a prior pass, then classify from the result.
  const refinedPath = appSupport("overture-refined.json");
  const refinements: EventRefinement[] = existsSync(refinedPath)
    ? (JSON.parse(readFileSync(refinedPath, "utf8")) as EventRefinement[])
    : [];
  const classifications = applyRefinements(byTitle, refinements);
  if (refinements.length) console.log(`Applied ${refinements.length} AI refinements to uncertain events.`);

  const prospects: Record<string, unknown>[] = [];
  const uncertain = uncertainEvents.map((e) => e.title);
  const skipped: Record<string, number> = {};

  for (const e of events) {
    const c = classifications.get(e.title)!;

    const discovered: DiscoveredEvent = {
      group_name: e.title,
      discipline: c.discipline,
      venue: e.venue,
      performance_date: e.performanceDate,
      source_listing_url: e.sourceUrl,
      website_url: null,
    };
    const classification: Classification = {
      reachable: c.reachable,
      production: c.production,
      profile: c.profile,
      coverage: c.coverage,
      fit_reason: c.fit_reason,
    };

    const verdict = matchRelationship(e.title, clients, history);
    const decision = decideProspect(discovered, classification, verdict, blocked);
    if (decision.kind === "skip") {
      skipped[decision.reason] = (skipped[decision.reason] ?? 0) + 1;
      continue;
    }
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

  prospects.sort((a, b) => {
    const da = (a.performanceDate as string) ?? "9999-99-99";
    const db = (b.performanceDate as string) ?? "9999-99-99";
    if (da !== db) return da < db ? -1 : 1;
    return (b.fitScore as number) - (a.fitScore as number);
  });

  const outPath = join(homedir(), "Library", "Application Support", "Overture", "overture-results.json");
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(
    outPath,
    JSON.stringify({ version: RESULTS_VERSION, generatedAt: new Date().toISOString(), prospects }, null, 2) + "\n",
    "utf8",
  );

  console.log(`Wrote ${prospects.length} prospects to ${outPath}`);
  if (Object.keys(skipped).length) console.log(`Skipped: ${JSON.stringify(skipped)}`);
  if (uncertain.length) {
    const refined = refinements.length;
    console.log(
      `\n${uncertain.length} events the rules were unsure about, written to ${appSupport("overture-uncertain.json")}`,
    );
    console.log(
      refined
        ? `(${refined} already refined this run; re-run after refining the rest to merge them)`
        : `Refine them (Claude Code scout agent), write overture-refined.json, and re-run to merge.`,
    );
    for (const t of uncertain) console.log(`  ? ${t}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
