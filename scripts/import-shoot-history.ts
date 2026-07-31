// One-shot importer: turns an iCalendar export of Dan's "Shoots" Google Calendar into the
// dated venue history the native Mac app reads, so a pitch can say he has shot this room before
// (#1887). The same fire-and-forget file boundary as the rest of the app.
//
// Idempotent: overwrites the file, and the records are sorted, so re-exporting an unchanged
// calendar produces an identical file.
//
//   pnpm import-shoot-history "/path/to/Shoots_dan@danwrightphotography.com.ics"
//
// Export the calendar from Google Calendar: Settings, click "Shoots" in the sidebar, then
// "Export calendar". Re-run this whenever it is worth refreshing; the app reports the file's
// age itself, so an old one says so rather than quietly under-reporting.
//
// By default it writes to the RELEASE handoff directory. A Debug build of the app reads a
// DIFFERENT directory (Overture-Debug), so pass --debug (or OVERTURE_HANDOFF_DIR) when loading
// history for a Debug run, or the app you are testing will never see the file.
//
//   pnpm import-shoot-history <ics-path> --debug
//   OVERTURE_HANDOFF_DIR=/some/dir pnpm import-shoot-history <ics-path>

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import {
  parseShootCalendar,
  shootHistoryFile,
  type RefusalReason,
} from "../src/lib/shootHistoryImport";

const REFUSAL_EXPLANATION: Record<RefusalReason, string> = {
  recurring: "repeats on a rule; a repeating entry is never read as a shoot",
  recurrence_instance: "one changed occurrence of a repeating entry",
  cancelled: "marked cancelled, so it is not a shoot that happened",
  all_day: "all-day, so it carries no time zone to date it by",
  unsupported_timezone: "a time zone this importer does not convert",
  unreadable_start: "its start date could not be read",
};

function handoffDirectory(useDebug: boolean): string {
  const override = process.env.OVERTURE_HANDOFF_DIR;
  if (override) return override;
  return join(
    homedir(),
    "Library",
    "Application Support",
    useDebug ? "Overture-Debug" : "Overture",
  );
}

function main() {
  const args = process.argv.slice(2);
  const useDebug = args.includes("--debug");
  const icsPath = args.find((a) => !a.startsWith("--"));
  if (!icsPath) {
    console.error("Usage: pnpm import-shoot-history <ics-path> [--debug]");
    process.exit(1);
  }

  const parsed = parseShootCalendar(readFileSync(icsPath, "utf8"));
  const file = shootHistoryFile(parsed.shoots, new Date());

  const outPath = join(handoffDirectory(useDebug), "overture-shoot-history.json");
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, JSON.stringify(file, null, 2) + "\n", "utf8");

  const venues = new Set(file.shoots.map((s) => s.venue)).size;
  console.log(
    `Read ${file.shoots.length} shoots at ${venues} distinct venue spellings; wrote ${outPath}`,
  );
  console.log(
    `Skipped ${parsed.skippedWithoutVenue} entries with no location (normal: not every calendar entry is at a venue)`,
  );

  // Refusals are printed in full, never summarised away. Each one is an event this importer
  // chose not to interpret, and the whole point of refusing rather than guessing is that
  // somebody can see what was left out.
  if (parsed.refusals.length === 0) {
    console.log("Refused 0 entries.");
    return;
  }
  console.log(`\nRefused ${parsed.refusals.length} entries, none of them counted as a shoot:`);
  for (const r of parsed.refusals) {
    console.log(`  ${r.title || "(untitled)"}: ${REFUSAL_EXPLANATION[r.reason]}`);
  }
}

main();
