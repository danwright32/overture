import { describe, it, expect } from "vitest";
import { parseShootCalendar, shootHistoryFile } from "./shootHistoryImport";

// Every fixture below is the SHAPE of something measured in Dan's real export
// (Shoots_dan@danwrightphotography.com.ics, 379 VEVENTs, read 2026-07-31), not an invented
// one (L48). The counts quoted in each comment are from that file.

// The real file is CRLF, as RFC 5545 requires. Building fixtures with "\r\n" keeps the
// unfolding tests honest: a parser that only handles "\n" passes on hand-written fixtures and
// then reads nothing at all from the actual export.
function ics(...lines: string[]): string {
  return lines.join("\r\n") + "\r\n";
}

function event(...lines: string[]): string {
  return ics(
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "BEGIN:VEVENT",
    ...lines,
    "END:VEVENT",
    "END:VCALENDAR",
  );
}

describe("parseShootCalendar", () => {
  it("dates an evening show by its Eastern day, not its UTC day", () => {
    // 'Round Midnight at The Green Room 42. Stored as 2018-06-23T01:15Z, which is
    // 2018-06-22 21:15 in New York. 81 of 381 events (21%) shift a day like this, and
    // getting it wrong splits or fuses engagements silently (L39).
    const out = parseShootCalendar(
      event(
        "DTSTART:20180623T011500Z",
        "SUMMARY:‘Round Midnight",
        "LOCATION:The Green Room 42",
      ),
    );
    expect(out.refusals).toEqual([]);
    expect(out.shoots).toEqual([
      { venue: "The Green Room 42", date: "2018-06-22", title: "‘Round Midnight" },
    ]);
  });

  it("unfolds a continuation line before reading the value", () => {
    // 34 of 322 LOCATION lines in the real export are folded across two physical lines.
    const out = parseShootCalendar(
      event(
        "DTSTART:20240101T180000Z",
        "SUMMARY:Folded",
        "LOCATION:St. Paul’s Episcopal Church\\n199 Carroll Street\\, Brooklyn\\, NY\\, ",
        " 11231",
      ),
    );
    expect(out.shoots[0].venue).toBe(
      "St. Paul’s Episcopal Church\n199 Carroll Street, Brooklyn, NY, 11231",
    );
  });

  it("unescapes a newline and keeps it, rather than folding the venue itself", () => {
    // 42 LOCATION values carry an escaped newline. The importer deliberately does NOT turn it
    // into a comma or otherwise normalise the venue: all venue folding lives in Swift so this
    // cannot become a fourth name vocabulary (#1887).
    const out = parseShootCalendar(
      event(
        "DTSTART:20240101T180000Z",
        "SUMMARY:Newline",
        "LOCATION:Carnegie Hall\\n57th Street and Seventh Avenue\\nNew York NY 10019",
      ),
    );
    expect(out.shoots[0].venue).toBe(
      "Carnegie Hall\n57th Street and Seventh Avenue\nNew York NY 10019",
    );
  });

  it("leaves a wrapping double quote alone, because that is the app's to fold", () => {
    // 40 events carry a quote-wrapped LOCATION. Stripping it here would be venue
    // normalisation, which belongs in Swift beside every other fold.
    const out = parseShootCalendar(
      event(
        "DTSTART:20240101T180000Z",
        "SUMMARY:Quoted",
        'LOCATION:"Carnegie Hall\\, Carnegie Hall"',
      ),
    );
    expect(out.shoots[0].venue).toBe('"Carnegie Hall, Carnegie Hall"');
  });

  it("never mistakes a VTIMEZONE rule for an event", () => {
    // The real export opens with a VTIMEZONE whose DAYLIGHT/STANDARD parts each carry their
    // own DTSTART (19700308T020000) and an RRULE. A parser that reads properties without
    // tracking which component it is inside invents two events dated 1970 and refuses the
    // whole file as recurring.
    const out = parseShootCalendar(
      ics(
        "BEGIN:VCALENDAR",
        "BEGIN:VTIMEZONE",
        "TZID:America/New_York",
        "BEGIN:DAYLIGHT",
        "DTSTART:19700308T020000",
        "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
        "TZOFFSETFROM:-0500",
        "END:DAYLIGHT",
        "END:VTIMEZONE",
        "BEGIN:VEVENT",
        "DTSTART:20240101T180000Z",
        "SUMMARY:Real shoot",
        "LOCATION:Jalopy Theatre",
        "END:VEVENT",
        "END:VCALENDAR",
      ),
    );
    expect(out.refusals).toEqual([]);
    expect(out.shoots).toEqual([
      { venue: "Jalopy Theatre", date: "2024-01-01", title: "Real shoot" },
    ]);
  });

  it("reads a New York local time as the day it is written", () => {
    // 4 events carry DTSTART;TZID=America/New_York. The wall-clock date is already Eastern.
    const out = parseShootCalendar(
      event(
        "DTSTART;TZID=America/New_York:20240614T090000",
        "SUMMARY:Local time",
        "LOCATION:Roulette Intermedium",
      ),
    );
    expect(out.shoots[0].date).toBe("2024-06-14");
  });

  it("skips an event with no location without calling it a refusal", () => {
    // 59 of 381 events have no LOCATION at all. That is a normal non-venue entry, not a
    // parsing failure, and must not be reported as one.
    const out = parseShootCalendar(
      event("DTSTART:20240101T180000Z", "SUMMARY:Bill’s video due"),
    );
    expect(out.shoots).toEqual([]);
    expect(out.refusals).toEqual([]);
    expect(out.skippedWithoutVenue).toBe(1);
  });
});

describe("parseShootCalendar refuses rather than guesses", () => {
  // The four shapes this importer will not interpret. Refusing is the only behaviour that
  // cannot be silently wrong: a parser that expands a weekly rule turns one booking into
  // hundreds of shoots and says "he shoots there regularly" forever, and one that ignores the
  // rule counts a decade of weekly shoots as one. Measured on the real export, all four of
  // these events are meetings with no location, so the refusal costs nothing today.

  it("refuses a recurring event", () => {
    const out = parseShootCalendar(
      event(
        "DTSTART;TZID=America/New_York:20231009T080000",
        "RRULE:FREQ=WEEKLY;UNTIL=20240715T035959Z;BYDAY=MO",
        "SUMMARY:NPS Drip",
        "LOCATION:Somewhere",
      ),
    );
    expect(out.shoots).toEqual([]);
    expect(out.refusals).toEqual([{ reason: "recurring", title: "NPS Drip" }]);
  });

  it("refuses one instance of a recurring event", () => {
    const out = parseShootCalendar(
      event(
        "DTSTART;TZID=America/New_York:20240614T090000",
        "RECURRENCE-ID;TZID=America/New_York:20240614T090000",
        "SUMMARY:Daniel - Intercom",
        "LOCATION:Somewhere",
      ),
    );
    expect(out.shoots).toEqual([]);
    expect(out.refusals).toEqual([
      { reason: "recurrence_instance", title: "Daniel - Intercom" },
    ]);
  });

  it("refuses a cancelled event rather than counting a shoot that did not happen", () => {
    const out = parseShootCalendar(
      event(
        "DTSTART:20240101T180000Z",
        "STATUS:CANCELLED",
        "SUMMARY:Called off",
        "LOCATION:Merkin Hall",
      ),
    );
    expect(out.shoots).toEqual([]);
    expect(out.refusals).toEqual([{ reason: "cancelled", title: "Called off" }]);
  });

  it("refuses an all-day event, whose date has no timezone to convert", () => {
    // 3 events are all-day. Parsing a date-only value as UTC midnight and then converting to
    // Eastern lands it on the PREVIOUS day, so the conversion that is right for every other
    // event is wrong for these.
    const out = parseShootCalendar(
      event("DTSTART;VALUE=DATE:20240609", "SUMMARY:Morahan dance recital", "LOCATION:A room"),
    );
    expect(out.shoots).toEqual([]);
    expect(out.refusals).toEqual([{ reason: "all_day", title: "Morahan dance recital" }]);
  });

  it("refuses a timezone it was not built to convert, instead of assuming Eastern", () => {
    const out = parseShootCalendar(
      event(
        "DTSTART;TZID=Europe/London:20240101T180000",
        "SUMMARY:Abroad",
        "LOCATION:Wigmore Hall",
      ),
    );
    expect(out.shoots).toEqual([]);
    expect(out.refusals).toEqual([{ reason: "unsupported_timezone", title: "Abroad" }]);
  });

  it("refuses an event whose start it cannot read at all", () => {
    const out = parseShootCalendar(
      event("DTSTART:not-a-date", "SUMMARY:Broken", "LOCATION:A room"),
    );
    expect(out.refusals).toEqual([{ reason: "unreadable_start", title: "Broken" }]);
  });
});

describe("shootHistoryFile", () => {
  it("stamps the version and the export time so the app can tell a stale file", () => {
    const file = shootHistoryFile(
      [{ venue: "Jalopy Theatre", date: "2024-05-25", title: "The Smoke Show" }],
      new Date("2026-07-31T18:00:00.000Z"),
    );
    expect(file).toEqual({
      version: 1,
      generatedAt: "2026-07-31T18:00:00.000Z",
      shoots: [{ venue: "Jalopy Theatre", date: "2024-05-25", title: "The Smoke Show" }],
    });
  });

  it("sorts by date so a re-export of unchanged history is byte-identical", () => {
    const file = shootHistoryFile(
      [
        { venue: "B", date: "2024-05-25", title: "later" },
        { venue: "A", date: "2018-06-22", title: "earlier" },
      ],
      new Date("2026-07-31T18:00:00.000Z"),
    );
    expect(file.shoots.map((s) => s.date)).toEqual(["2018-06-22", "2024-05-25"]);
  });
});
