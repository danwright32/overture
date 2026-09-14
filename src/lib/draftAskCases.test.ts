import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { asksAboutPhotographyPlans } from "./prepEval";

// #2531: the TypeScript half of one shared judgment.
//
// #1889 put a deterministic check behind the runbook rule that a drafted pitch must actually ask for
// something, and it scored PRODUCED output in the eval only. A draft Dan writes or edits by hand never
// passed through it, so a pitch that admires the show and asks for nothing could still be sent. The Swift
// draft lint now carries the same finding, and two implementations in two languages must read one
// committed fixture rather than each holding its own idea of the rule (L26).
//
// `fixtures/draft-ask/cases.json` is that fixture. `DraftAskCasesTests` on the Swift side reads the same
// file and asserts the same verdicts, so the two cannot drift without one of them going red.
interface Case {
  name: string;
  from: string;
  asks: boolean;
  body: string;
}

const fixture = JSON.parse(
  readFileSync(join(__dirname, "..", "..", "fixtures", "draft-ask", "cases.json"), "utf8"),
) as { version: number; cases: Case[] };

// #2954: every body here is a COPY of one that lives in `fixtures/prep-eval`, and each case names its
// source in `from`. Nothing checked the copy still matched it, so the two could drift and this corpus
// would go on judging text no fixture actually contains, while passing. It nearly did: while building
// #2807 the same sentence had to be hand-edited on both sides to keep them in step (L41).
//
// `from` is a slash path into the named fixture, followed by a note saying how the body was DERIVED from
// what sits there. Two derivations are in use, and they are what the rejecting half of the corpus is
// built from: none of it is invented, so none of it can describe a draft the run could not produce (L48).
const REMOVED = " (ask sentence removed)";
const REMOVED_AND_REWRITTEN = " (ask sentence removed) plus the rewrite named in the runbook";
const DERIVATIONS = [REMOVED_AND_REWRITTEN, REMOVED];

// #3549 retired the per-contact second copy of the pitch, and 24 of these bodies were copied from one.
// The bodies are real compliant drafts and are the reason this corpus words the ask nine different ways,
// so they are KEPT rather than deleted with their source (L104): a corpus cut by more than half would
// stop protecting exactly the good drafts it exists for.
//
// The exemption PROVES ITSELF rather than being taken on trust. A marked case must name an issue, and
// its original path must genuinely no longer resolve, so the marker cannot be used to silence a real
// drift: the moment that path resolves again, the case fails and has to go back to being checked.
const RETIRED = /^retired by (#\d+): /;

function resolve(path: string): unknown {
  const [file, ...rest] = path.split(".json/");
  const source = JSON.parse(
    readFileSync(join(__dirname, "..", "..", `${file}.json`), "utf8"),
  ) as unknown;
  let node: unknown = source;
  for (const step of rest.join(".json/").split("/")) {
    if (node === undefined || node === null) return undefined;
    node = Array.isArray(node) ? node[Number(step)] : (node as Record<string, unknown>)[step];
  }
  return node;
}

// Sentences, split the way a reader meets them. Only used to check that a derived body is the source
// MINUS one sentence, never to judge the ask itself.
function sentences(body: string): string[] {
  return body
    .split(/(?<=[.!?])\s+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

describe("every case still matches the fixture it was copied from (#2954)", () => {
  for (const testCase of fixture.cases) {
    it(`${testCase.name} still matches ${testCase.from}`, () => {
      const retired = RETIRED.exec(testCase.from);
      const stated = retired === null ? testCase.from : testCase.from.slice(retired[0].length);
      const derivation = DERIVATIONS.find((d) => stated.endsWith(d));
      const sourcePath =
        derivation === undefined ? stated : stated.slice(0, -derivation.length);
      const source = resolve(sourcePath);

      if (retired !== null) {
        expect(
          typeof source,
          `${sourcePath} resolves again, so ${testCase.name} must go back to being checked against it rather than claiming ${retired[1]} retired it`,
        ).not.toBe("string");
        return;
      }

      expect(typeof source, `${sourcePath} does not resolve to a body any more`).toBe("string");

      if (derivation === undefined) {
        expect(source).toBe(testCase.body);
        return;
      }

      // Each derivation is asserted as a real RELATIONSHIP to the source, never as "it is different",
      // which any edit to either side would satisfy while the copy drifted (L63).
      const sourceSentences = sentences(source as string);
      const caseSentences = sentences(testCase.body);
      const carriedOver = caseSentences.filter((s) => sourceSentences.includes(s));

      if (derivation === REMOVED) {
        // One sentence taken out and nothing put back: every sentence left is the source's.
        expect(caseSentences.length).toBe(sourceSentences.length - 1);
        expect(carriedOver.length).toBe(caseSentences.length);
        return;
      }

      // One sentence taken out and one of the runbook's named rewrites put in its place, so the count
      // holds and exactly one sentence is new.
      expect(caseSentences.length).toBe(sourceSentences.length);
      expect(caseSentences.length - carriedOver.length).toBe(1);
    });
  }

  // The derivation vocabulary is closed. A `from` carrying some other parenthetical would fall into the
  // exact-match branch above and fail confusingly; this says what is actually wrong.
  it("names no derivation this test cannot check", () => {
    for (const testCase of fixture.cases) {
      const note = testCase.from.match(/\.json\/\S+?(\s.*)$/)?.[1];
      if (note !== undefined) expect(DERIVATIONS).toContain(note);
    }
  });
});

describe("the shared ask corpus (#2531)", () => {
  it("is the corpus both languages judge, and is not empty", () => {
    // A fixture that came back empty would pass every case below it, which is the shape where a guard
    // reports hardest on the thing it can see least of (L98).
    expect(fixture.cases.length).toBeGreaterThan(30);
    expect(fixture.cases.some((c) => c.asks)).toBe(true);
    expect(fixture.cases.some((c) => !c.asks)).toBe(true);
  });

  for (const testCase of fixture.cases) {
    it(`${testCase.asks ? "accepts" : "rejects"}: ${testCase.name}`, () => {
      expect(asksAboutPhotographyPlans(testCase.body)).toBe(testCase.asks);
    });
  }
});
