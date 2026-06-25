import { describe, it, expect } from "vitest";
import { parseHits, windowBoundsMs, params, fetchCalendar } from "./algoliaCalendar";

const sample = JSON.stringify({
  results: [
    {
      nbPages: 1,
      hits: [
        {
          title: "The Presence of Absence",
          licenseename: "Cuban Cultural Center",
          facility: "Thalia Spanish Theatre",
          url: "/calendar/2026/06/25/the-presence-0700pm",
          startdate: 1782428400000,
        },
        { title: "Bare Title", url: "/calendar/2026/07/10/bare", startdate: 1784000000000 },
      ],
    },
  ],
});

describe("algolia calendar parse", () => {
  it("maps hit fields to ExtractedEvent", () => {
    const { events } = parseHits(sample);
    expect(events).toHaveLength(2);
    expect(events[0]).toEqual({
      title: "The Presence of Absence",
      presenter: "Cuban Cultural Center",
      venue: "Thalia Spanish Theatre",
      performanceDate: "2026-06-25",
      sourceUrl: "https://www.carnegiehall.org/calendar/2026/06/25/the-presence-0700pm",
    });
  });

  it("tolerates a hit missing presenter and venue", () => {
    const { events } = parseHits(sample);
    expect(events[1].presenter).toBeNull();
    expect(events[1].venue).toBeNull();
    expect(events[1].performanceDate).toBe("2026-07-10");
  });

  it("reports the page count for pagination", () => {
    expect(parseHits(sample).nbPages).toBe(1);
  });

  it("returns no events on malformed input", () => {
    expect(parseHits("not json").events).toEqual([]);
  });
});

describe("algolia date window", () => {
  // 2026-06-25T03:00:00Z is 2026-06-24 in New York, so the window opens on the 24th ET.
  const now = new Date("2026-06-25T03:00:00Z");

  it("opens at Eastern midnight", () => {
    // 2026-06-24 00:00 America/New_York == 1782273600000 ms.
    expect(windowBoundsMs(now, 90).start).toBe(1782273600000);
  });

  it("spans the requested number of days", () => {
    const { start, end } = windowBoundsMs(now, 90);
    const days = (end - start) / 86_400_000;
    expect(days).toBeGreaterThanOrEqual(90);
    expect(days).toBeLessThanOrEqual(92);
  });

  it("builds params filtering startdate and page", () => {
    const p = params(1000, 2000, 1000, 0);
    expect(p).toContain("hitsPerPage=1000");
    expect(p).toContain("startdate");
    expect(p).toContain("page=0");
  });
});

describe("fetchCalendar", () => {
  function page(title: string, url: string, nbPages: number): string {
    return JSON.stringify({ results: [{ nbPages, hits: [{ title, url }] }] });
  }

  it("concatenates every page until the index is exhausted", async () => {
    let call = 0;
    const fake = (async () => {
      const p = call++;
      return { ok: true, text: async () => page(`Event ${p}`, `/calendar/2026/07/0${p + 1}/e`, 2) } as Response;
    }) as unknown as typeof fetch;
    const events = await fetchCalendar(new Date("2026-06-25T03:00:00Z"), fake);
    expect(events.map((e) => e.title)).toEqual(["Event 0", "Event 1"]);
    expect(call).toBe(2);
  });

  it("throws when the query fails", async () => {
    const fake = (async () => ({ ok: false, status: 500, text: async () => "" })) as unknown as typeof fetch;
    await expect(fetchCalendar(new Date(), fake)).rejects.toThrow(/500/);
  });
});
