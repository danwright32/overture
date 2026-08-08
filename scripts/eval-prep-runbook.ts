// CLI glue for the on-demand prep-runbook eval (#591). Reuses the SAME scoring engine as the always-on
// vitest suite (src/lib/prepEval.ts), so a fixture's pass/fail rules can never drift between the two.
//
// This file does NO model call itself. scripts/eval-prep-runbook.sh drives the real (token-spending)
// claude run and hands each produced output here to be scored. It is also runnable standalone:
//
//   tsx scripts/eval-prep-runbook.ts --list                 # list fixture names
//   tsx scripts/eval-prep-runbook.ts --self-check           # score every fixture's own compliant sample
//   tsx scripts/eval-prep-runbook.ts <fixture> <produced>   # score a produced output against one fixture
//
// The <produced> file may hold raw claude output (optionally fenced or with surrounding prose); the JSON
// object is extracted from it. A file that carries no parseable JSON is a hard failure (fail loud, never
// a silent pass), since an unreadable output is the run having failed.

import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { evaluateFixture, extractPrepResultsJson, type PrepEvalFixture, type EvalResult } from "../src/lib/prepEval";

const FIXTURE_DIR = fileURLToPath(new URL("../fixtures/prep-eval/", import.meta.url));

function fixtureFiles(): string[] {
  return readdirSync(FIXTURE_DIR).filter((f) => f.endsWith(".json")).sort();
}

function loadFixture(path: string): PrepEvalFixture {
  return JSON.parse(readFileSync(path, "utf8")) as PrepEvalFixture;
}

function report(result: EvalResult): void {
  if (result.pass) {
    console.log(`PASS  ${result.name}`);
  } else {
    console.log(`FAIL  ${result.name}`);
    for (const f of result.failures) console.log(`        - ${f}`);
  }
}

function selfCheck(): number {
  let failed = 0;
  for (const file of fixtureFiles()) {
    const fixture = loadFixture(`${FIXTURE_DIR}${file}`);
    // #1909: the same narrowed scope the always-on suite uses. This checks a STORED sample, not a
    // model's answer, so it is judged on its own rule plus the durable invariants. scoreOne below
    // keeps the full set, because that is real output being judged on every rule the runbook states.
    const result = evaluateFixture(fixture, fixture.sampleCompliantOutput, { scope: "durable" });
    report(result);
    if (!result.pass) failed++;
  }
  console.log(`\n${failed === 0 ? "all fixtures self-check clean" : `${failed} fixture(s) failed self-check`}`);
  return failed === 0 ? 0 : 1;
}

function scoreOne(fixturePath: string, producedPath: string): number {
  const fixture = loadFixture(fixturePath);
  let produced: unknown;
  try {
    produced = extractPrepResultsJson(readFileSync(producedPath, "utf8"));
  } catch (e) {
    report({ name: fixture.name, pass: false, failures: [`could not read produced output: ${(e as Error).message}`] });
    return 1;
  }
  const result = evaluateFixture(fixture, produced);
  report(result);
  return result.pass ? 0 : 1;
}

function main(argv: string[]): number {
  const args = argv.slice(2);
  if (args[0] === "--list") {
    for (const f of fixtureFiles()) console.log(f.replace(/\.json$/, ""));
    return 0;
  }
  if (args[0] === "--self-check") {
    return selfCheck();
  }
  if (args.length === 2) {
    return scoreOne(args[0], args[1]);
  }
  console.error("usage: eval-prep-runbook.ts [--list | --self-check | <fixture.json> <produced.json>]");
  return 2;
}

process.exit(main(process.argv));
