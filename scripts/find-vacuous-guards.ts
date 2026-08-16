// #2726: report the source-text guards that a second, unrelated occurrence can answer (L135).
//
// Run: pnpm find-vacuous-guards
//
// Reports, never fails, and is wired into no gate. Not every finding is a defect: three genuine call
// sites of one sheet are three real answers to "is this presented", so a gate on this signature would
// fire on the ordinary case and be switched off within a day (L93). What it produces is a work-list.
//
// The reading is done with `scripts/mutate.sh`: break the site the guard is ABOUT, and see whether it
// goes red. That is the only thing that tells a coincidence from a defect.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { findingsFor, positiveContainsAssertions, report, sourceBindings, type Finding } from "../src/lib/wholeFileGuards";

const repoRoot = join(__dirname, "..");
const appRoot = join(repoRoot, "mac", "Overture");
const testRoots = ["OvertureTests", "OvertureHostedTests"].map((d) => join(repoRoot, "mac", d));

function swiftFilesUnder(root: string): string[] {
  const out: string[] = [];
  const walk = (dir: string) => {
    for (const entry of readdirSync(dir)) {
      const path = join(dir, entry);
      if (statSync(path).isDirectory()) walk(path);
      else if (entry.endsWith(".swift")) out.push(path);
    }
  };
  walk(root);
  return out;
}

const appCache = new Map<string, string | null>();
function readAppFile(relative: string): string | null {
  if (!appCache.has(relative)) {
    try {
      appCache.set(relative, readFileSync(join(appRoot, relative), "utf8"));
    } catch {
      appCache.set(relative, null);
    }
  }
  return appCache.get(relative) ?? null;
}

const testFiles = testRoots.flatMap(swiftFilesUnder);
// The same refusal every walk in this repo carries: a wrong path yields no files, and then every question
// below it is answered "nothing found", which is indistinguishable from a clean answer (#2311, L98).
if (testFiles.length < 100) {
  console.error(`Walked ${testFiles.length} test files, which is a broken path rather than a small suite.`);
  process.exit(2);
}

let checked = 0;
const findings: Finding[] = [];
for (const file of testFiles) {
  const source = readFileSync(file, "utf8");
  const bindings = new Set(sourceBindings(source).map((b) => b.variable));
  checked += positiveContainsAssertions(source).filter((a) => bindings.has(a.variable)).length;
  findings.push(...findingsFor(file.replace(`${repoRoot}/`, ""), source, readAppFile));
}

console.log(report(findings, checked));
