// The event-scout pipeline: raw extracted events -> rule-classify -> match/rank/
// assemble -> write the results handoff the Mac app ingests. Deterministic and free;
// the rules classify the bulk and flag genuinely ambiguous events for an optional
// AI refine pass (printed at the end). See docs/scout-runbook.md.
//
//   pnpm tsx scripts/scout/run-scout.ts [events.json]
//
// With no argument it fetches the next 90 days live from Carnegie's Algolia calendar index
// (src/lib/algoliaCalendar.ts), the same window the native app pulls. Pass a JSON file of
// ExtractedEvent[] (e.g. scripts/scout/events.sample.json) to replay a fixed set instead.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { loadDownbeatExport } from "../../src/lib/downbeatBridge";
import { loadLocalHistory } from "../../src/lib/localHistory";
import { matchRelationship } from "../../src/lib/historyMatch";
import { decideProspect, type DiscoveredEvent, type Classification } from "../../src/lib/assembleProspect";
import { classifyEvent, type EventClassification, type ExtractedEvent } from "../../src/lib/classifyEvent";
import { fetchCalendar, WINDOW_DAYS } from "../../src/lib/algoliaCalendar";
import { applyRefinements, type EventRefinement } from "../../src/lib/refineClassifications";
import { groupIntoRuns } from "../../src/lib/runGrouping";

function appSupport(name: string): string {
  return join(homedir(), "Library", "Application Support", "Overture", name);
}

const RESULTS_VERSION = 2;

async function main() {
  const inputPath = process.argv[2];
  const events = inputPath
    ? (JSON.parse(readFileSync(inputPath, "utf8")) as ExtractedEvent[])
    : await fetchCalendar();
  console.log(
    inputPath
      ? `Read ${events.length} extracted events from ${inputPath}`
      : `Fetched ${events.length} upcoming events from Carnegie's calendar (next ${WINDOW_DAYS} days)`,
  );

  // History and blocked dates come from the same local files the Mac app reads:
  // booked/contacted/DNC history from the importer's overture-history.json, and
  // blocked dates from the Downbeat export (version 2; downbeat#52). A version-1
  // export or a missing history file leaves the scout running without that signal.
  const { clients, venues, blockedDates: blocked } = loadDownbeatExport();
  const history = loadLocalHistory();
  console.log(
    `Loaded ${history.length} history records and ${blocked.size} blocked dates.`,
  );
  if (history.length === 0) {
    console.warn("No local history found — repeat-client matching and DNC suppression are inactive.");
  }
  if (blocked.size === 0) {
    console.warn("No blocked dates in the Downbeat export — date-blocking is inactive (needs downbeat#52).");
  }

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

  const runs = groupIntoRuns(
    prospects as Array<{ groupName: string; venue: string | null; performanceDate: string | null; sourceListingUrl: string | null }>,
  );
  prospects.length = 0;
  for (const r of runs as Array<Record<string, unknown>>) {
    prospects.push({
      ...r,
      runEndDate: r.runEndDate,
      partOfRelatedRun: r.partOfRelatedRun,
      runSourceUrls: r.runSourceURLs,
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
