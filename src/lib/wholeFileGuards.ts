// #2726: find the source-text guards that a second, unrelated occurrence can answer.
//
// A guard that matches source text over a WHOLE FILE is satisfied by any occurrence in it, so a second
// legitimate use of the same construct elsewhere in that file answers the check while the region it was
// written about is broken (L135). A large file makes a coincidental match near certain, and the guard
// reads greenest exactly when it is blindest.
//
// The signature this finds is cheap and exact: a POSITIVE `#expect(src.contains("X"))` where `src` is a
// whole app file and `X` occurs in that file more than once. Every one of those CAN be answered by the
// other occurrence. Not every one IS a defect: three genuine call sites of the same sheet are three real
// answers to "is this presented". So this REPORTS rather than fails, and the reading is done by a person
// with `scripts/mutate.sh` in hand.
//
// Measured 2026-08-15 on this repo: 172 positive whole-file assertions, 18 of them at risk, and the four
// looked at first were all genuinely vacuous.

export interface SourceBinding {
  variable: string;
  appPath: string; // relative to mac/Overture, as written in the test
}

export interface ContainsAssertion {
  variable: string;
  needle: string;
  line: number;
}

export interface Finding {
  testFile: string;
  line: number;
  appPath: string;
  needle: string;
  occurrences: number;
}

// `let queueView = source("Overture/UI/QueueView.swift")`, in either spelling the repo uses.
const BINDING = /(\w+)\s*=\s*(?:SourceGuardHelper\.)?source\(\s*"Overture\/([^"]+)"/g;

// `#expect(model.contains("showSummary"))`. Positive only: a NEGATIVE assertion ("this file contains no
// X") is correctly whole-file, and reading it as at-risk would bury the real findings in the ones that
// are working as intended (L93).
const POSITIVE_CONTAINS = /#expect\(\s*(\w+)\.contains\(\s*"((?:[^"\\]|\\.)*)"\s*\)/g;

export function sourceBindings(testSource: string): SourceBinding[] {
  const out: SourceBinding[] = [];
  for (const m of testSource.matchAll(BINDING)) {
    out.push({ variable: m[1], appPath: m[2] });
  }
  return out;
}

export function positiveContainsAssertions(testSource: string): ContainsAssertion[] {
  const out: ContainsAssertion[] = [];
  for (const m of testSource.matchAll(POSITIVE_CONTAINS)) {
    out.push({
      variable: m[1],
      needle: unescapeSwift(m[2]),
      line: testSource.slice(0, m.index ?? 0).split("\n").length,
    });
  }
  return out;
}

// A Swift literal's escapes, so the needle compared against the app file is the string the guard actually
// searches for. Without this, every assertion containing a `\(` or a `\"` is compared as source text and
// silently matches nothing, which would make this report say "no risk" for the guards most likely to have
// it.
export function unescapeSwift(literal: string): string {
  return literal
    .replace(/\\"/g, '"')
    .replace(/\\n/g, "\n")
    .replace(/\\t/g, "\t")
    .replace(/\\\\/g, "\\");
}

export function countOccurrences(haystack: string, needle: string): number {
  if (needle === "") return 0;
  let count = 0;
  let from = 0;
  for (;;) {
    const at = haystack.indexOf(needle, from);
    if (at === -1) return count;
    count += 1;
    from = at + needle.length;
  }
}

export function findingsFor(
  testFile: string,
  testSource: string,
  readAppFile: (appPath: string) => string | null,
): Finding[] {
  const bindings = new Map(sourceBindings(testSource).map((b) => [b.variable, b.appPath]));
  if (bindings.size === 0) return [];

  const out: Finding[] = [];
  for (const assertion of positiveContainsAssertions(testSource)) {
    const appPath = bindings.get(assertion.variable);
    if (appPath === undefined) continue;
    const app = readAppFile(appPath);
    if (app === null) continue;
    const occurrences = countOccurrences(app, assertion.needle);
    if (occurrences > 1) {
      out.push({ testFile, line: assertion.line, appPath, needle: assertion.needle, occurrences });
    }
  }
  return out;
}

export function report(findings: Finding[], checked: number): string {
  const lines: string[] = [];
  lines.push(`positive whole-file contains assertions: ${checked}`);
  lines.push(`at risk (the searched text occurs more than once in the file): ${findings.length}`);
  lines.push("");
  if (findings.length === 0) {
    lines.push("Nothing at risk. Note this checks one signature, not every way a guard can be vacuous.");
    return lines.join("\n");
  }
  for (const f of [...findings].sort((a, b) => b.occurrences - a.occurrences)) {
    lines.push(`  ${f.testFile}:${f.line}  x${f.occurrences}  ${f.appPath}`);
    lines.push(`      "${f.needle.length > 70 ? `${f.needle.slice(0, 70)}...` : f.needle}"`);
  }
  lines.push("");
  lines.push("Each of these CAN be answered by the other occurrence. Whether it IS is a question for");
  lines.push("scripts/mutate.sh: break the site the guard is about and see whether it goes red.");
  return lines.join("\n");
}
