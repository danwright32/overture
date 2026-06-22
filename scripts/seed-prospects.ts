// One-shot seeder: runs the curated real Carnegie events (scripts/seed-events.ts)
// through the full scout foundation (repeat-client match -> rank -> assemble) and
// inserts the resulting prospects, so the dashboard has real rows to develop against.
//
//   pnpm tsx scripts/seed-prospects.ts
//
// Idempotent at the row level: skips any prospect already present (same group +
// date + venue), so re-running tops up without duplicating. Reads Supabase creds
// from .env.local (service-role key, server-side only) and the Downbeat client/venue
// export from its default local path.

import { readFileSync } from "node:fs";
import { loadDownbeatExport } from "../src/lib/downbeatBridge";
import { matchRelationship } from "../src/lib/historyMatch";
import { decideProspect } from "../src/lib/assembleProspect";
import { createRepo } from "../src/lib/prospectsRepo";
import { SEED_EVENTS } from "./seed-events";

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
  const env = loadEnv();
  const url = env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceKey) {
    console.error(
      "Missing NEXT_PUBLIC_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in .env.local",
    );
    process.exit(1);
  }

  const { clients, venues } = loadDownbeatExport();
  console.log(
    `Loaded Downbeat export: ${clients.length} clients, ${venues.length} venues`,
  );

  const repo = createRepo(url, serviceKey);
  const [history, blocked] = await Promise.all([
    repo.loadHistory(),
    repo.loadBlockedDates(),
  ]);
  console.log(
    `Loaded ${history.length} history rows, ${blocked.size} blocked dates`,
  );

  let inserted = 0;
  let already = 0;
  const skipped: Record<string, number> = {};

  for (const { event, classification } of SEED_EVENTS) {
    const verdict = matchRelationship(event.group_name, clients, history);
    const decision = decideProspect(event, classification, verdict, blocked);

    if (decision.kind === "skip") {
      skipped[decision.reason] = (skipped[decision.reason] ?? 0) + 1;
      console.log(`  skip (${decision.reason}): ${event.group_name}`);
      continue;
    }

    const exists = await repo.prospectExists(
      event.group_name,
      event.performance_date,
      event.venue,
    );
    if (exists) {
      already += 1;
      console.log(`  exists: ${event.group_name} @ ${event.performance_date}`);
      continue;
    }

    await repo.insertProspect(decision.row);
    inserted += 1;
    console.log(
      `  + ${decision.row.tier}/${decision.row.fit_score} ${event.group_name}` +
        (decision.row.prior_relationship !== "none"
          ? ` [${decision.row.prior_relationship}]`
          : ""),
    );
  }

  console.log(
    `\nDone. Inserted ${inserted}, already present ${already}, skipped ${JSON.stringify(skipped)}.`,
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
