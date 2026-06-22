// Parses Dan's booking-log CSV (Downloads/Lead Booking sources ... .csv) into rows
// for the `history` table. The CSV is messy: quoted multi-line cells, embedded
// commas, two-email cells, and blank / "n/a" dates. Parsing is split from the
// one-shot import runner so the mapping logic stays pure and testable.

import { parse } from "csv-parse/sync";

export type HistoryRecord = {
  group_name: string;
  shoot_date: string | null;
  email: string | null;
  venue: string | null;
  first_contact: string | null;
  contact_type: string | null;
  status: string | null;
  raw_row: Record<string, string>;
};

// Trim outer whitespace; an empty result becomes null for optional fields.
function clean(value: string | undefined): string | null {
  const s = (value ?? "").trim();
  return s === "" ? null : s;
}

// Converts an M/D/YYYY cell to ISO YYYY-MM-DD, or null for blank / "n/a" /
// anything that is not a real calendar date.
export function parseShootDate(raw: string): string | null {
  const s = raw.trim();
  if (s === "" || s.toLowerCase() === "n/a") return null;

  const m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (!m) return null;

  const month = Number(m[1]);
  const day = Number(m[2]);
  const year = Number(m[3]);

  // Reject impossible dates (e.g. 13/40/2026) by round-tripping through Date.
  const d = new Date(Date.UTC(year, month - 1, day));
  if (
    d.getUTCFullYear() !== year ||
    d.getUTCMonth() !== month - 1 ||
    d.getUTCDate() !== day
  ) {
    return null;
  }

  const mm = String(month).padStart(2, "0");
  const dd = String(day).padStart(2, "0");
  return `${year}-${mm}-${dd}`;
}

// Maps one parsed CSV row (keyed by header) to a history record. group_name keeps
// internal line breaks (presenter + program title often span lines); every other
// field is cleaned to a trimmed value or null.
export function mapBookingRow(row: Record<string, string>): HistoryRecord {
  return {
    group_name: (row["Name of Group"] ?? "").trim(),
    shoot_date: parseShootDate(row["Date of shoot"] ?? ""),
    email: clean(row["Email"]),
    venue: clean(row["Venue"]),
    first_contact: clean(row["First Contact"]),
    contact_type: clean(row["Type of Contact"]),
    status: clean(row["Status"]),
    raw_row: row,
  };
}

// Parses the full CSV text into history records, handling quoted multi-line cells
// and embedded commas. Rows with no group name are dropped (trailing blank lines,
// stray separators).
export function parseBookingCsv(text: string): HistoryRecord[] {
  const rows = parse(text, {
    columns: true,
    skip_empty_lines: true,
    relax_column_count: true,
    bom: true,
  }) as Record<string, string>[];

  return rows.map(mapBookingRow).filter((r) => r.group_name !== "");
}
