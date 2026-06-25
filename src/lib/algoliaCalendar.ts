// Carnegie's public calendar (/events) is a thin front-end over an Algolia search index
// (prod_Events). The visible page only renders ~3 days at a time, but the index holds the
// whole season, so the scout queries Algolia directly for the next 90 days instead of
// scraping the paginated DOM. Mirrors the native app's AlgoliaCalendar.swift so both scout
// paths pull the same window. These are the same public, search-only credentials the website
// ships in its own client JS (not secrets); if Carnegie rotates the key, update API_KEY.

import type { ExtractedEvent } from "./classifyEvent";

export const APP_ID = "Q0TMLOPF1J";
export const API_KEY = "d2d2b382f2659c44ef8927aad7a24172";
export const INDEX = "prod_Events";
export const ENDPOINT = "https://Q0TMLOPF1J-dsn.algolia.net/1/indexes/*/queries";
export const WINDOW_DAYS = 90;
export const HITS_PER_PAGE = 1000;
const MAX_PAGES = 5;

// Milliseconds between a UTC instant and the same wall-clock read in `tz` — used to pin a
// New York midnight to its true UTC instant without a date library.
function tzOffsetMs(tz: string, date: Date): number {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hour12: false,
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
  const p: Record<string, string> = {};
  for (const part of dtf.formatToParts(date)) p[part.type] = part.value;
  const asUTC = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour % 24, +p.minute, +p.second);
  return asUTC - date.getTime();
}

function easternMidnightMs(date: Date, addDays: number): number {
  const ymd = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit",
  }).format(date);
  const guess = new Date(`${ymd}T00:00:00Z`).getTime();
  const off = tzOffsetMs("America/New_York", new Date(guess));
  return guess - off + addDays * 86_400_000;
}

// The startdate window: midnight (New York) of today through midnight of the day after the
// last included day, so every performance on day+windowDays is covered. Lower bound
// inclusive, upper exclusive.
export function windowBoundsMs(today: Date, windowDays = WINDOW_DAYS): { start: number; end: number } {
  return { start: easternMidnightMs(today, 0), end: easternMidnightMs(today, windowDays + 1) };
}

export function params(startMs: number, endMs: number, hitsPerPage = HITS_PER_PAGE, page = 0): string {
  const numeric = JSON.stringify([`startdate>=${startMs}`, `startdate<${endMs}`]);
  return `query=&hitsPerPage=${hitsPerPage}&page=${page}&numericFilters=${encodeURIComponent(numeric)}`;
}

function nonBlank(s: string | null | undefined): string | null {
  const t = (s ?? "").trim();
  return t === "" ? null : t;
}

function dateFromCalendarUrl(url: string | null | undefined): string | null {
  if (!url) return null;
  const m = url.match(/\/calendar\/(\d{4})\/(\d{2})\/(\d{2})\//);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
}

type AlgoliaHit = {
  title: string;
  licenseename?: string | null;
  facility?: string | null;
  url?: string | null;
};

// Maps one page of Algolia hits to the same ExtractedEvent shape the rest of the pipeline
// classifies. `licenseename` is the presenter/renter (drives self vs agency), `facility` is
// the venue, and the date comes from the /calendar/yyyy/mm/dd url.
export function parseHits(raw: string): { events: ExtractedEvent[]; nbPages: number } {
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    return { events: [], nbPages: 0 };
  }
  const page = (json as { results?: Array<{ hits?: AlgoliaHit[]; nbPages?: number }> })?.results?.[0];
  if (!page) return { events: [], nbPages: 0 };
  const events: ExtractedEvent[] = (page.hits ?? []).map((h) => ({
    title: h.title,
    presenter: nonBlank(h.licenseename),
    venue: nonBlank(h.facility),
    performanceDate: dateFromCalendarUrl(h.url),
    sourceUrl: h.url ? `https://www.carnegiehall.org${h.url}` : null,
  }));
  return { events, nbPages: page.nbPages ?? 1 };
}

// Live fetch of the next 90 days, paginating until the index is exhausted (or the safety cap).
export async function fetchCalendar(today: Date = new Date(), fetchImpl: typeof fetch = fetch): Promise<ExtractedEvent[]> {
  const { start, end } = windowBoundsMs(today);
  const all: ExtractedEvent[] = [];
  for (let page = 0; page < MAX_PAGES; page++) {
    const body = JSON.stringify({ requests: [{ indexName: INDEX, params: params(start, end, HITS_PER_PAGE, page) }] });
    const res = await fetchImpl(ENDPOINT, {
      method: "POST",
      headers: {
        "x-algolia-api-key": API_KEY,
        "x-algolia-application-id": APP_ID,
        "content-type": "application/json",
      },
      body,
    });
    if (!res.ok) throw new Error(`Algolia query failed: ${res.status}`);
    const { events, nbPages } = parseHits(await res.text());
    all.push(...events);
    if (page + 1 >= nbPages) break;
  }
  return all;
}
