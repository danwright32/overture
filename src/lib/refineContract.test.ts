import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { classifyEvent, type ExtractedEvent } from "./classifyEvent";
import { buildUncertainPayload } from "./refineContract";
import { applyRefinements, type EventRefinement } from "./refineClassifications";

// Shared contract fixtures for the scout <-> refine-agent round trip (#159), mirroring the #157
// guard. run-scout WRITES overture-uncertain.json (buildUncertainPayload) and READS the agent's
// overture-refined.json (applyRefinements); the Claude Code scout agent (docs/scout-runbook.md) is
// the counterpart with no automated test, so these committed fixtures are its spec. A format change
// on either file fails a test here instead of the refine pass silently doing nothing (the #109 class).
const fixture = (name: string) =>
  readFileSync(
    fileURLToPath(new URL(`../../fixtures/scout-refine/${name}`, import.meta.url)),
    "utf8",
  );

// Two events the rules leave uncertain (one production-unknown, one self+neutral) and one the
// rules resolve confidently (an agency showcase), so the writer's filter is exercised too.
const SAMPLE_EVENTS: ExtractedEvent[] = [
  {
    title: "An Evening with the Velvet Notes",
    presenter: null,
    venue: "Zankel Hall",
    performanceDate: "2026-04-05",
    sourceUrl: "https://example.org/velvet-notes",
  },
  {
    title: "Winter Concert",
    presenter: "Hudson Valley Philharmonic Society",
    venue: "Stern Auditorium",
    performanceDate: "2026-04-12",
    sourceUrl: "https://example.org/hv-phil",
  },
  {
    title: "Rising Stars Gala",
    presenter: "Distinguished Concerts International",
    venue: "Stern Auditorium",
    performanceDate: "2026-04-20",
    sourceUrl: "https://example.org/rising-stars",
  },
];

const byTitle = new Map(SAMPLE_EVENTS.map((e) => [e.title, classifyEvent(e)]));

describe("Scout refine contract fixtures", () => {
  it("writes exactly the committed uncertain.json work-list from the sample events", () => {
    const payload = buildUncertainPayload(SAMPLE_EVENTS, byTitle);
    expect(payload).toEqual(JSON.parse(fixture("uncertain.json")));
  });

  it("hands the agent only the uncertain slice (the confident event is excluded)", () => {
    const payload = buildUncertainPayload(SAMPLE_EVENTS, byTitle);
    expect(payload).toHaveLength(2);
    expect(payload.map((p) => p.title)).toEqual([
      "An Evening with the Velvet Notes",
      "Winter Concert",
    ]);
  });

  it("folds the committed refined.json back over the rules verdicts", () => {
    const refinements = JSON.parse(fixture("refined.json")) as EventRefinement[];
    const out = applyRefinements(byTitle, refinements);

    // Fully re-judged: an overridden uncertain event becomes confident with the agent's fields.
    const a = out.get("An Evening with the Velvet Notes")!;
    expect(a.confidence).toBe("confident");
    expect(a.production).toBe("self");
    expect(a.profile).toBe("strong");
    expect(a.coverage).toBe("likely_uncovered");
    expect(a.discipline).toBe("music");
    expect(a.fit_reason).toBe("Self-presented vocal ensemble; likely uncovered.");

    // Refinement that omits fit_reason keeps the rules' original reason (the ?? fallback).
    const b = out.get("Winter Concert")!;
    expect(b.confidence).toBe("confident");
    expect(b.profile).toBe("strong");
    expect(b.fit_reason).toBe(byTitle.get("Winter Concert")!.fit_reason);

    // The already-confident event is untouched by the refine pass.
    const c = out.get("Rising Stars Gala")!;
    expect(c).toEqual(byTitle.get("Rising Stars Gala"));
  });

  it("keeps the join key intact: every refinement answers an event that was handed out", () => {
    const handed = new Set(
      buildUncertainPayload(SAMPLE_EVENTS, byTitle).map((p) => p.title),
    );
    const refinements = JSON.parse(fixture("refined.json")) as EventRefinement[];
    for (const r of refinements) expect(handed.has(r.title)).toBe(true);
  });
});
