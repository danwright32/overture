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
import { decideProspect, type DiscoveredEvent, type Classification, type ProspectRow } from "../../src/lib/assembleProspect";
import { classifyEvent, type EventClassification, type ExtractedEvent } from "../../src/lib/classifyEvent";
import { fetchCalendar, WINDOW_DAYS } from "../../src/lib/algoliaCalendar";
import { applyRefinements, type EventRefinement } from "../../src/lib/refineClassifications";
import { buildResultsFile } from "../../src/lib/resultsContract";
import { buildUncertainPayload } from "../../src/lib/refineContract";

function appSupport(name: string): string {
  return join(homedir(), "Library", "Application Support", "Overture", name);
}

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
  // The uncertain work-list shape is the #159 contract (src/lib/refineContract.ts), pinned by
  // refineContract.test.ts against fixtures/scout-refine/ and read back below via applyRefinements.
  const uncertainPayload = buildUncertainPayload(events, byTitle);
  writeFileSync(
    appSupport("overture-uncertain.json"),
    JSON.stringify(uncertainPayload, null, 2) + "\n",
    "utf8",
  );

  // Merge any refinements the agent produced on a prior pass, then classify from the result.
  const refinedPath = appSupport("overture-refined.json");
  const refinements: EventRefinement[] = existsSync(refinedPath)
    ? (JSON.parse(readFileSync(refinedPath, "utf8")) as EventRefinement[])
    : [];
  const classifications = applyRefinements(byTitle, refinements);
  if (refinements.length) console.log(`Applied ${refinements.length} AI refinements to uncertain events.`);

  const rows: ProspectRow[] = [];
  const uncertain = uncertainPayload.map((p) => p.title);
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
    rows.push(decision.row);
  }

  // Serialize, collapse multi-night runs, and sort — the whole writer contract lives in
  // buildResultsFile (src/lib/resultsContract.ts), pinned by resultsContract.test.ts and the
  // Swift ResultsContractTests against the shared fixtures (#157).
  const resultsFile = buildResultsFile(rows, new Date().toISOString());

  const outPath = join(homedir(), "Library", "Application Support", "Overture", "overture-results.json");
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, JSON.stringify(resultsFile, null, 2) + "\n", "utf8");

  console.log(`Wrote ${resultsFile.prospects.length} prospects to ${outPath}`);
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
