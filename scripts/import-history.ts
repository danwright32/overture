// One-shot importer: parses Dan's booking-log CSV into the local history file the native
// Mac app reads, ~/Library/Application Support/Overture/overture-history.json (sibling to
// overture-results.json, the same fire-and-forget file boundary the rest of the app uses).
// Idempotent: overwrites the file, so re-running gives a clean reload. The app merges this
// one-time legacy history with its own live activity at scout time (#19, #69).
//
//   pnpm import-history "/path/to/Lead Booking sources - 2026 Bookings.csv"
//
// Each row maps to a ranking status (booked / declined / warm / lost_soft / dnc); cold pitches
// that got silence are dropped as neutral. See src/lib/bookingImport.ts for the mapping.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { parseBookingCsv, appHistoryRecords } from "../src/lib/bookingImport";

function main() {
  const csvPath = process.argv[2];
  if (!csvPath) {
    console.error("Usage: pnpm import-history <csv-path>");
    process.exit(1);
  }

  const parsed = parseBookingCsv(readFileSync(csvPath, "utf8"));
  const records = appHistoryRecords(parsed);

  const outPath = join(
    homedir(),
    "Library",
    "Application Support",
    "Overture",
    "overture-history.json",
  );
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, JSON.stringify(records, null, 2) + "\n", "utf8");

  const byStatus = records.reduce<Record<string, number>>((acc, r) => {
    acc[r.status] = (acc[r.status] ?? 0) + 1;
    return acc;
  }, {});
  console.log(
    `Parsed ${parsed.length} rows; wrote ${records.length} history records to ${outPath}`,
  );
  console.log(`By status: ${JSON.stringify(byStatus)} (cold no-response rows dropped as neutral)`);
}

main();
