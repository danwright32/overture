// One-shot importer: loads Dan's booking-log CSV into the `history` table.
// Idempotent — clears the table first, so re-running gives a clean reload.
//
//   pnpm tsx scripts/import-history.ts "/path/to/Lead Booking sources - 2026 Bookings.csv"
//
// Reads Supabase credentials from .env.local (service-role key, which bypasses RLS).

import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";
import { parseBookingCsv } from "../src/lib/bookingImport";

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
  const csvPath = process.argv[2];
  if (!csvPath) {
    console.error("Usage: tsx scripts/import-history.ts <csv-path>");
    process.exit(1);
  }

  const env = loadEnv();
  const url = env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceKey) {
    console.error("Missing NEXT_PUBLIC_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in .env.local");
    process.exit(1);
  }

  const records = parseBookingCsv(readFileSync(csvPath, "utf8"));
  console.log(`Parsed ${records.length} history records from ${csvPath}`);

  const supabase = createClient(url, serviceKey, { auth: { persistSession: false } });

  // Clear existing rows for a clean reload (filter matches every row).
  const del = await supabase.from("history").delete().not("id", "is", null);
  if (del.error) throw del.error;

  let inserted = 0;
  for (let i = 0; i < records.length; i += 100) {
    const chunk = records.slice(i, i + 100);
    const { error } = await supabase.from("history").insert(chunk);
    if (error) throw error;
    inserted += chunk.length;
  }

  const { count, error: countErr } = await supabase
    .from("history")
    .select("*", { count: "exact", head: true });
  if (countErr) throw countErr;

  console.log(`Inserted ${inserted} records. history now has ${count} rows.`);
}

main().catch((e) => {
  console.error("Import failed:", e.message ?? e);
  process.exit(1);
});
