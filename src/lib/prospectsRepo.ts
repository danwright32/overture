// Thin Supabase adapter for the scout: load history and blocked dates, check for
// an existing prospect (dedup), and insert. All access is server-side with the
// service-role key (RLS has no anon policies). Verified against the real database
// rather than unit-tested, the same pattern as the history importer.

import { createClient } from "@supabase/supabase-js";
import type { HistoryRecord } from "./bookingImport";
import type { ProspectRow } from "./assembleProspect";

export function createRepo(url: string, serviceKey: string) {
  const supabase = createClient(url, serviceKey, {
    auth: { persistSession: false },
  });

  return {
    async loadHistory(): Promise<HistoryRecord[]> {
      const { data, error } = await supabase
        .from("history")
        .select(
          "group_name, shoot_date, email, venue, first_contact, contact_type, status, raw_row",
        );
      if (error) throw error;
      return (data ?? []) as HistoryRecord[];
    },

    async loadBlockedDates(): Promise<Set<string>> {
      const { data, error } = await supabase
        .from("blocked_dates")
        .select("blocked_date");
      if (error) throw error;
      return new Set((data ?? []).map((r) => r.blocked_date as string));
    },

    async prospectExists(
      groupName: string,
      performanceDate: string | null,
      venue: string | null,
    ): Promise<boolean> {
      let query = supabase
        .from("prospects")
        .select("id", { count: "exact", head: true })
        .eq("group_name", groupName);
      query = performanceDate
        ? query.eq("performance_date", performanceDate)
        : query.is("performance_date", null);
      query = venue ? query.eq("venue", venue) : query.is("venue", null);
      const { count, error } = await query;
      if (error) throw error;
      return (count ?? 0) > 0;
    },

    async insertProspect(row: ProspectRow): Promise<void> {
      const { error } = await supabase.from("prospects").insert(row);
      if (error) throw error;
    },
  };
}
