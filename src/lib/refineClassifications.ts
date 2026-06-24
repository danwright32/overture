// The second half of the chosen hybrid classifier (#30). The rules in classifyEvent flag
// genuinely ambiguous events as `confidence: "uncertain"`; an AI refine pass (the Claude Code
// scout agent, on Dan's Max plan — no paid API) re-judges only those, and this folds the
// result back over the rules output. Keeping the refine slice small keeps cost near zero while
// recovering the nuance rules miss (e.g. a self-presented orchestra that is actually covered).

import type { Candidate } from "./ranker";
import type { EventClassification } from "./classifyEvent";

// What the AI returns for one previously-uncertain event. Only the four fields the rules
// struggle with are re-judged; fit_reason is optional (a fresh one-line reason if it has one).
export type EventRefinement = {
  title: string;
  production: Candidate["production"];
  profile: Candidate["profile"];
  coverage: Candidate["coverage"];
  discipline: Candidate["discipline"];
  fit_reason?: string;
};

// Folds AI refinements back over the rules classifications (keyed by event title). Only events
// the rules marked `uncertain` AND that have a refinement are overridden; an overridden event
// becomes `confident` (a deliberate second look resolved the ambiguity). Confident rules
// verdicts, and uncertain events with no refinement, are returned unchanged. Pure: the input
// map is not mutated.
export function applyRefinements(
  byTitle: Map<string, EventClassification>,
  refinements: EventRefinement[],
): Map<string, EventClassification> {
  const refinedByTitle = new Map(refinements.map((r) => [r.title, r]));
  const out = new Map(byTitle);
  for (const [title, c] of byTitle) {
    if (c.confidence !== "uncertain") continue;
    const r = refinedByTitle.get(title);
    if (!r) continue;
    out.set(title, {
      ...c,
      production: r.production,
      profile: r.profile,
      coverage: r.coverage,
      discipline: r.discipline,
      fit_reason: r.fit_reason ?? c.fit_reason,
      confidence: "confident",
    });
  }
  return out;
}
