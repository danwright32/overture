// Parses an iCalendar export of Dan's "Shoots" Google Calendar into the dated venue history
// the Mac app reads (#1895, part of #1887). One-shot and re-runnable: Dan exports the calendar
// by hand, this turns it into `overture-shoot-history.json`, and the app counts how many times
// he has shot each room.
//
// TWO THINGS THIS DELIBERATELY DOES NOT DO.
//
// 1. It does not FOLD a venue name. It undoes the file's own encoding (line unfolding, text
//    unescaping) and hands over the LOCATION exactly as the calendar holds it, newlines,
//    wrapping quotes and all. Every venue fold lives in Swift beside the existing ones, so this
//    importer cannot become a fourth name vocabulary drifting from the other three (#1887).
//
// 2. It does not interpret a recurring event. See `Refusal` below: the four shapes it will not
//    read are reported by name rather than guessed at.
//
// Measured against the real export 2026-07-31 (379 VEVENTs, CRLF, back to 2018): 322 events
// carry a LOCATION, 42 of those hold an escaped newline, 40 are wrapped in double quotes, 34
// are folded across two physical lines, 372 starts are UTC, 4 are New York local, 3 are all-day,
// and 3 RRULE plus 3 RECURRENCE-ID events are meetings with no location at all.

export type ShootRecord = {
  venue: string;
  date: string; // YYYY-MM-DD, in America/New_York
  title: string;
};

// Why refusing beats interpreting. An ICS library that expands a recurrence rule would turn one
// weekly booking into hundreds of dates, and the app would tell every recipient at that room
// that Dan "shoots there regularly", forever. One that ignores the rule counts a decade of
// weekly shoots as a single date. Both are silent and neither is detectable downstream, so the
// importer reads only what it is sure of and names the rest.
export type RefusalReason =
  | "recurring" // carries an RRULE
  | "recurrence_instance" // one modified occurrence of a recurring event
  | "cancelled" // STATUS:CANCELLED, a shoot that did not happen
  | "all_day" // a date with no time and so no zone to convert
  | "unsupported_timezone" // a TZID this importer was not built to convert
  | "unreadable_start"; // a DTSTART that does not parse at all

export type Refusal = { reason: RefusalReason; title: string };

export type ShootCalendarParse = {
  shoots: ShootRecord[];
  refusals: Refusal[];
  // An event with no LOCATION is a normal non-venue entry ("Bill's video due"), not a failure,
  // and must not be reported as one (L11: a message may claim only what its check measured).
  skippedWithoutVenue: number;
};

export type ShootHistoryFile = {
  version: 1;
  generatedAt: string;
  shoots: ShootRecord[];
};

const EASTERN = "America/New_York";

const easternDayFormatter = new Intl.DateTimeFormat("en-CA", {
  timeZone: EASTERN,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

// RFC 5545 line folding: a CRLF followed by a single space or tab continues the previous line.
// The real export folds 34 of its LOCATION lines, so a reader that skips this step silently
// truncates a third of the addresses it needs.
function unfold(text: string): string {
  return text.replace(/\r?\n[ \t]/g, "");
}

// RFC 5545 TEXT escaping. Done in ONE left-to-right pass rather than a chain of replacements:
// chained replaces would turn a literal backslash-n (written "\\\\n") into a newline.
function unescapeText(value: string): string {
  let out = "";
  for (let i = 0; i < value.length; i += 1) {
    const ch = value[i];
    if (ch !== "\\" || i === value.length - 1) {
      out += ch;
      continue;
    }
    i += 1;
    const next = value[i];
    if (next === "n" || next === "N") out += "\n";
    else out += next; // covers \, \; \\ and anything else an exporter escapes
  }
  return out;
}

type Property = { name: string; params: Record<string, string>; value: string };

function parseProperty(line: string): Property | null {
  const colon = line.indexOf(":");
  if (colon === -1) return null;
  const head = line.slice(0, colon);
  const value = line.slice(colon + 1);
  const [name, ...paramParts] = head.split(";");
  const params: Record<string, string> = {};
  for (const part of paramParts) {
    const eq = part.indexOf("=");
    if (eq === -1) continue;
    params[part.slice(0, eq).toUpperCase()] = part.slice(eq + 1);
  }
  return { name: name.toUpperCase(), params, value };
}

// The Eastern day a start value falls on, or the reason it cannot be read.
function easternDay(prop: Property): { date: string } | { refusal: RefusalReason } {
  if ((prop.params.VALUE ?? "").toUpperCase() === "DATE") return { refusal: "all_day" };

  const tzid = prop.params.TZID;
  const raw = prop.value.trim();

  // A local wall-clock time in New York is ALREADY the Eastern day; converting it would be a
  // second conversion of an already-converted value.
  if (tzid) {
    if (tzid !== EASTERN) return { refusal: "unsupported_timezone" };
    const m = /^(\d{4})(\d{2})(\d{2})T\d{6}$/.exec(raw);
    if (!m) return { refusal: "unreadable_start" };
    return { date: `${m[1]}-${m[2]}-${m[3]}` };
  }

  // A UTC instant. 81 of 381 events (21%) are evening shows whose UTC day is the NEXT day, so
  // this conversion is the difference between counting a shoot on the right night and the wrong
  // one (L39).
  const m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(raw);
  if (!m) return { refusal: "unreadable_start" };
  const instant = new Date(
    Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]),
  );
  if (Number.isNaN(instant.getTime())) return { refusal: "unreadable_start" };
  return { date: easternDayFormatter.format(instant) };
}

export function parseShootCalendar(text: string): ShootCalendarParse {
  const shoots: ShootRecord[] = [];
  const refusals: Refusal[] = [];
  let skippedWithoutVenue = 0;

  // Which component each line belongs to. Without this, the VTIMEZONE that opens every Google
  // export (its DAYLIGHT and STANDARD parts each carry a DTSTART of 19700308T020000 and an
  // RRULE) reads as events dated 1970 and poisons the refusal list.
  const stack: string[] = [];
  let current: Property[] | null = null;

  for (const line of unfold(text).split(/\r?\n/)) {
    if (line === "") continue;
    const prop = parseProperty(line);
    if (!prop) continue;

    if (prop.name === "BEGIN") {
      stack.push(prop.value.toUpperCase());
      if (stack.length === 2 && stack[1] === "VEVENT") current = [];
      continue;
    }
    if (prop.name === "END") {
      if (stack.length === 2 && stack[1] === "VEVENT" && current) {
        const outcome = readEvent(current);
        if (outcome.kind === "shoot") shoots.push(outcome.shoot);
        else if (outcome.kind === "refusal") refusals.push(outcome.refusal);
        else skippedWithoutVenue += 1;
        current = null;
      }
      stack.pop();
      continue;
    }
    // Only properties directly inside a VEVENT are collected, never one nested deeper (an
    // alarm) or in another component (the timezone).
    if (current && stack.length === 2 && stack[1] === "VEVENT") current.push(prop);
  }

  return { shoots, refusals, skippedWithoutVenue };
}

type EventOutcome =
  | { kind: "shoot"; shoot: ShootRecord }
  | { kind: "refusal"; refusal: Refusal }
  | { kind: "no_venue" };

function readEvent(props: Property[]): EventOutcome {
  const find = (name: string) => props.find((p) => p.name === name);
  const title = unescapeText(find("SUMMARY")?.value ?? "").trim();

  // Refusals are judged BEFORE the location check, deliberately: a shape this importer cannot
  // read should be reported by name even when it happens to carry no venue, so the count Dan is
  // shown is of everything that was not understood, not of a filtered subset.
  if (find("RRULE")) return { kind: "refusal", refusal: { reason: "recurring", title } };
  if (find("RECURRENCE-ID")) {
    return { kind: "refusal", refusal: { reason: "recurrence_instance", title } };
  }
  if ((find("STATUS")?.value ?? "").toUpperCase() === "CANCELLED") {
    return { kind: "refusal", refusal: { reason: "cancelled", title } };
  }

  const start = find("DTSTART");
  if (!start) return { kind: "refusal", refusal: { reason: "unreadable_start", title } };
  const day = easternDay(start);
  if ("refusal" in day) return { kind: "refusal", refusal: { reason: day.refusal, title } };

  const venue = unescapeText(find("LOCATION")?.value ?? "").trim();
  if (venue === "") return { kind: "no_venue" };

  return { kind: "shoot", shoot: { venue, date: day.date, title } };
}

// Sorted so that re-exporting an unchanged calendar produces an identical file, which is what
// makes "did anything actually change" answerable by looking at the file (L40).
export function shootHistoryFile(shoots: ShootRecord[], now: Date): ShootHistoryFile {
  const sorted = [...shoots].sort(
    (a, b) => a.date.localeCompare(b.date) || a.venue.localeCompare(b.venue) || a.title.localeCompare(b.title),
  );
  return { version: 1, generatedAt: now.toISOString(), shoots: sorted };
}
