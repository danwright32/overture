import { describe, it, expect } from "vitest";
import { applyRefinements, type EventRefinement } from "./refineClassifications";
import type { EventClassification } from "./classifyEvent";

function uncertain(over: Partial<EventClassification> = {}): EventClassification {
  return {
    discipline: "music",
    reachable: true,
    production: "unknown",
    profile: "neutral",
    coverage: "unknown",
    fit_reason: "Rules were unsure.",
    confidence: "uncertain",
    ...over,
  };
}

function confident(over: Partial<EventClassification> = {}): EventClassification {
  return { ...uncertain(), confidence: "confident", ...over };
}

const refinement = (over: Partial<EventRefinement> = {}): EventRefinement => ({
  title: "Mystery Ensemble",
  production: "self",
  profile: "strong",
  coverage: "likely_uncovered",
  discipline: "choral",
  ...over,
});

describe("applyRefinements", () => {
  it("overrides an uncertain event's fields and marks it confident", () => {
    const before = new Map([["Mystery Ensemble", uncertain()]]);
    const after = applyRefinements(before, [refinement()]);
    const c = after.get("Mystery Ensemble")!;
    expect(c.production).toBe("self");
    expect(c.profile).toBe("strong");
    expect(c.coverage).toBe("likely_uncovered");
    expect(c.discipline).toBe("choral");
    expect(c.confidence).toBe("confident");
  });

  it("never touches a confident rules verdict, even if a refinement is offered", () => {
    const before = new Map([["Mystery Ensemble", confident({ production: "agency" })]]);
    const after = applyRefinements(before, [refinement()]);
    expect(after.get("Mystery Ensemble")).toEqual(confident({ production: "agency" }));
  });

  it("leaves an uncertain event with no matching refinement unchanged", () => {
    const before = new Map([["Mystery Ensemble", uncertain()]]);
    const after = applyRefinements(before, [refinement({ title: "Someone Else" })]);
    expect(after.get("Mystery Ensemble")?.confidence).toBe("uncertain");
  });

  it("uses the refinement's fit_reason when given, else keeps the original", () => {
    const before = new Map([
      ["With Reason", uncertain()],
      ["Without Reason", uncertain()],
    ]);
    const after = applyRefinements(before, [
      refinement({ title: "With Reason", fit_reason: "A small self-produced choir." }),
      refinement({ title: "Without Reason" }),
    ]);
    expect(after.get("With Reason")?.fit_reason).toBe("A small self-produced choir.");
    expect(after.get("Without Reason")?.fit_reason).toBe("Rules were unsure.");
  });

  it("does not mutate the input map", () => {
    const before = new Map([["Mystery Ensemble", uncertain()]]);
    applyRefinements(before, [refinement()]);
    expect(before.get("Mystery Ensemble")?.confidence).toBe("uncertain");
  });
});
