// The writer side of the scout <-> refine-agent contract (#159): the uncertain work-list the scout
// hands the Claude Code refine agent. Extracted from run-scout.ts so the writer is pure and testable
// against the shared fixtures (refineContract.test.ts), mirroring the #157 results guard. The reader
// side (the agent's overture-refined.json) is consumed by applyRefinements in refineClassifications.ts.

import type { Candidate } from "./ranker";
import type { ExtractedEvent, EventClassification } from "./classifyEvent";

// One entry in overture-uncertain.json: the event plus the rules' best guess, for the agent to
// re-judge. `title` is the join key the agent must echo back into overture-refined.json.
export type UncertainEvent = {
  title: string;
  presenter: string | null;
  venue: string | null;
  performanceDate: string | null;
  sourceUrl: string | null;
  rulesGuess: {
    production: Candidate["production"];
    profile: Candidate["profile"];
    coverage: Candidate["coverage"];
    discipline: Candidate["discipline"];
  };
};

// The events the rules marked uncertain, mapped to the work-list shape. Refining only this slice
// keeps the AI cost near zero; confident verdicts never reach the agent.
export function buildUncertainPayload(
  events: ExtractedEvent[],
  byTitle: Map<string, EventClassification>,
): UncertainEvent[] {
  return events
    .filter((e) => byTitle.get(e.title)?.confidence === "uncertain")
    .map((e) => {
      const c = byTitle.get(e.title)!;
      return {
        title: e.title,
        presenter: e.presenter,
        venue: e.venue,
        performanceDate: e.performanceDate,
        sourceUrl: e.sourceUrl,
        rulesGuess: {
          production: c.production,
          profile: c.profile,
          coverage: c.coverage,
          discipline: c.discipline,
        },
      };
    });
}
