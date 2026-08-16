import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// #2764 (phase 2 of #2620): the runbook must not state where its files are.
//
// `prep-run.sh` opens its prompt with "Follow $RUNBOOK exactly", and Write is a granted tool for the
// run. So every absolute path written in the runbook is an instruction, competing with the paths the
// prompt substitutes. Today the two agree closely enough not to matter, because only one run can exist
// at a time and it owns every file named. Under two slots the runbook's path names the OTHER live run's
// results file, and a run that follows the runbook rather than the prompt destroys work Dan has paid
// for. A rule that lives only in a prompt is a hope (L27), so this is the deterministic half.
//
// It is already wrong in a smaller way that has nothing to do with concurrency: the paths are written as
// `~/Library/Application Support/Overture/...`, which is the RELEASE handoff folder. A Debug run's own
// folder is `Overture-Debug`, so a run launched from a Debug build and following the runbook reads and
// writes the live files. That is the Debug/Release leak class #317 warns about.
const repoRoot = join(__dirname, "..", "..");
const runbookPath = join(repoRoot, "docs", "prep-runbook.md");
const runbook = readFileSync(runbookPath, "utf8");

// Every way the handoff folder can be spelled out. Not just the tilde form: an expanded /Users path or a
// bare "Application Support/Overture" is the same instruction.
const ABSOLUTE_PATH_PATTERNS = [
  /~\/Library\/Application Support\/Overture/g,
  /\/Users\/[A-Za-z0-9._-]+\/Library\/Application Support/g,
  /Application Support\/Overture(-Debug)?\//g,
];

describe("the prep runbook states no path of its own (#2764)", () => {
  it("names no handoff folder anywhere", () => {
    const offenders: string[] = [];
    runbook.split("\n").forEach((line, i) => {
      const hit = ABSOLUTE_PATH_PATTERNS.some((pattern) => {
        pattern.lastIndex = 0;
        return pattern.test(line);
      });
      if (hit) offenders.push(`docs/prep-runbook.md:${i + 1}  ${line.trim()}`);
    });
    expect(
      offenders,
      `The runbook states a path. The run is told to follow it exactly, so that path competes with the\n` +
        `one the prompt gives it, and under two run slots it names another live run's files.\n` +
        `Say "the work-list the prompt names" instead:\n${offenders.join("\n")}`,
    ).toEqual([]);
  });

  // The control. A guard that reports no offenders is indistinguishable from one whose patterns match
  // nothing, and matching nothing is exactly what a reword produces (L70). So the patterns are shown
  // catching the text they were written against, in the form it actually had.
  it("the patterns still catch the wording they were written against", () => {
    const asItWas = [
      "- **Read:** `~/Library/Application Support/Overture/overture-prep-queue.json`",
      "- **Write:** `/Users/someone/Library/Application Support/Overture/overture-prep-results.json`",
      "  see `Application Support/Overture-Debug/overture-prep-results.json` for a Debug run",
    ];
    for (const line of asItWas) {
      const matched = ABSOLUTE_PATH_PATTERNS.some((p) => {
        p.lastIndex = 0;
        return p.test(line);
      });
      expect(matched, `this guard would not have caught: ${line}`).toBe(true);
    }
  });

  // And the other half of the contract: the runbook has to SAY that the prompt decides, or the next
  // person to write a path in has nothing telling them not to. A negative guard with no positive rule
  // beside it is a rule nobody can read (L46: the reader is what makes the rule real).
  it("says out loud that the prompt supplies the paths", () => {
    expect(runbook).toMatch(/the prompt (names|gives|supplies)/i);
  });
});
