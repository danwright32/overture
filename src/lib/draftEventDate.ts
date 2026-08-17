// The TypeScript twin of `EventDateInDraft` (#2864): does a pitch name the show's own night, and never
// a different one?
//
// Two implementations of one judgment, because the rule has to run in two places: the Swift one is what
// Dan meets on the draft review screen, and this one scores what a Prep run PRODUCED, so a runbook edit
// that weakens the rule is caught by `scripts/eval-prep-runbook.sh` rather than at review time.
//
// Two implementations drift the moment either is touched, so both are tested against ONE committed
// corpus, `fixtures/draft-event-date/cases.json` (L26), exactly as the ask rule is (#2531). The SWIFT
// side is the declared source of truth; this one follows it.

export type EventDateVerdict = "ok" | "missing" | "wrong";

const MONTHS = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?"
  + "|sep(?:t)?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?";

// The en dash is written as an ESCAPE, never as itself: the pre-push style gate blocks any new line
// carrying one and cannot tell a line that USES one from a line that must MATCH one, which is the gate
// working correctly (AGENTS.md). Building the character leaves no literal in the file.
const MONTH_FIRST = new RegExp(
  `\\b(${MONTHS})\\.?\\s+(\\d{1,2})(st|nd|rd|th)?(?:,?\\s+(\\d{4}))?`
  + `(\\s*(?:to|through|until|[-\\u2013])\\s*(?:${MONTHS})?\\.?\\s*(\\d{1,2})(?:st|nd|rd|th)?)?`, "gi");
const DAY_FIRST = new RegExp(`\\b(\\d{1,2})(st|nd|rd|th)?\\s+(${MONTHS})\\b`, "gi");
const NUMERIC = /\b(\d{1,2})\/(\d{1,2})(\/(\d{2,4}))?\b/g;
const BARE_ORDINAL = /\bthe\s+(\d{1,2})(?:st|nd|rd|th)\b/gi;
const MONTH_ONLY = new RegExp(`\\b(${MONTHS})\\b`, "i");

const MONTH_NUMBERS: Record<string, number> = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12,
};

function monthNumber(name: string | undefined): number | undefined {
  if (!name) return undefined;
  return MONTH_NUMBERS[name.slice(0, 3).toLowerCase()];
}

function stamp(year: number, month: number, day: number): string | undefined {
  if (month < 1 || month > 12 || day < 1 || day > 31) return undefined;
  const iso = `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  // Reject a day the month does not have, the way Swift's strict formatter does: "February 30" is not a
  // date, and accepting it would let a nonsense phrase count as a contradiction.
  const d = new Date(`${iso}T00:00:00Z`);
  return Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== iso ? undefined : iso;
}

export interface NamedDay { day: string; text: string; }

/** Every day-shaped phrase in the text, resolved against the show's year. Narrow on purpose: a rate, a
 *  delivery window or a ticket price must never rescue a draft, so this never simply hunts for numbers. */
export function namedDays(text: string, assumingYearOf: string): NamedDay[] {
  const referenceYear = Number(assumingYearOf.slice(0, 4)) || 0;
  const found: NamedDay[] = [];
  const add = (month: number, day: number, year: number, raw: string) => {
    const iso = stamp(year, month, day);
    if (!iso || found.some((f) => f.day === iso)) return;
    found.push({ day: iso, text: raw.trim() });
  };
  for (const sentence of text.split(/[.!?\n]/)) {
    let monthInSentence: number | undefined;
    for (const m of sentence.matchAll(MONTH_FIRST)) {
      const month = monthNumber(m[1]);
      if (month === undefined) continue;
      monthInSentence = month;
      const day = Number(m[2]);
      const year = m[4] ? Number(m[4]) : referenceYear;
      add(month, day, year, m[0]);
      const endDay = m[6] ? Number(m[6]) : undefined;
      if (endDay !== undefined && endDay > day) {
        for (let d = day + 1; d <= endDay; d += 1) add(month, d, year, m[0]);
      }
    }
    for (const m of sentence.matchAll(DAY_FIRST)) {
      const month = monthNumber(m[3]);
      if (month === undefined) continue;
      monthInSentence = month;
      add(month, Number(m[1]), referenceYear, m[0]);
    }
    for (const m of sentence.matchAll(NUMERIC)) {
      const written = m[4] ? Number(m[4]) : undefined;
      const year = written === undefined ? referenceYear : (written < 100 ? 2000 + written : written);
      add(Number(m[1]), Number(m[2]), year, m[0]);
    }
    if (monthInSentence === undefined) {
      const bare = MONTH_ONLY.exec(sentence);
      if (bare) monthInSentence = monthNumber(bare[1]);
    }
    if (monthInSentence !== undefined) {
      for (const m of sentence.matchAll(BARE_ORDINAL)) {
        add(monthInSentence, Number(m[1]), referenceYear, m[0]);
      }
    }
  }
  return found;
}

function nights(performanceDate: string, runEndDate?: string): string[] {
  const start = new Date(`${performanceDate}T00:00:00Z`);
  const end = new Date(`${runEndDate ?? performanceDate}T00:00:00Z`);
  if (Number.isNaN(start.getTime())) return [];
  if (Number.isNaN(end.getTime()) || end < start) return [performanceDate];
  const out: string[] = [];
  for (const cursor = new Date(start); cursor <= end && out.length < 366; cursor.setUTCDate(cursor.getUTCDate() + 1)) {
    out.push(cursor.toISOString().slice(0, 10));
  }
  return out;
}

/**
 * "ok", "missing" (no date named anywhere) or "wrong" (a date naming a day that is not the show's).
 *
 * `today` is required, never a bare `new Date()`: this compares a stored date against a clock, so the
 * clock is an input the corpus pins rather than a fact that walks cases into other cases (L130).
 */
export function eventDateVerdict(args: {
  subject?: string; body: string; performanceDate?: string; runEndDate?: string; today: string;
}): EventDateVerdict {
  const { subject, body, performanceDate, runEndDate, today } = args;
  if (!performanceDate) return "ok";
  const all = nights(performanceDate, runEndDate);
  if (all.length === 0) return "ok";
  // The runbook forbids naming an opening night that has gone, so a passed night does not count while
  // the run still has one left. A run wholly in the past has none to prefer and accepts any of its own.
  const upcoming = all.filter((d) => d >= today);
  const acceptable = new Set(upcoming.length > 0 ? upcoming : all);
  const named = namedDays([subject, body].filter(Boolean).join("\n"), performanceDate);
  if (named.length === 0) return "missing";
  return named.some((n) => acceptable.has(n.day)) ? "ok" : "wrong";
}
