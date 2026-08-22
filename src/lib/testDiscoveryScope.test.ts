import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join, relative, sep } from "node:path";
import { describe, expect, it } from "vitest";

// #3120: what `pnpm test` actually collects.
//
// `pnpm test` is `vitest run`, and with no config file vitest uses its default include,
// `**​/*.{test,spec}.?(c|m)[jt]s?(x)`, whose only exclusions are node_modules, dist and similar. This
// repo runs parallel agents in git worktrees under `.claude/worktrees/`, and each of those is a FULL
// checkout, so each contributed its own copy of every test file.
//
// Measured on this Mac 2026-08-22, in the ordinary working checkout: 16 real `*.test.ts` files under
// `src/`, 14 agent worktrees, and `Test Files  240 passed (240)`. Sixteen files, fifteen copies, and the
// fifteen are not the same code.
//
// Two things went wrong and neither looked like a failure. A half finished branch sitting in a worktree
// contributed its failing tests to the verdict on whoever ran `pnpm test` in the parent checkout, and
// the count itself read as thorough while moving with how many agents happened to be running. It is not
// a coverage gap: every real test did run. `pnpm test` is one of the two cheap lanes inside
// `scripts/test-all.sh`, which AGENTS.md requires before every push, so this ran constantly.
//
// The fix is an INCLUDE naming where this repo's tests live, not an exclude for `.claude/worktrees`: an
// include cannot be defeated by a future worktree directory with a different name, and an exclude can.
// `tsconfig.json` already does exactly this (`"include": ["src/**/*.ts", "scripts/**/*.ts"]`), which is
// why `pnpm typecheck` never had the defect, and `scripts/run-shell-fixtures.sh` names its directories
// for the same reason.

const repoRoot = join(__dirname, "..", "..");

/** Every `*.test.ts` under `dir`, relative to the repo root. `skip` names directories not to descend. */
function testFilesUnder(dir: string, skip: (name: string) => boolean): string[] {
  const found: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (skip(entry.name)) continue;
      found.push(...testFilesUnder(join(dir, entry.name), skip));
    } else if (entry.name.endsWith(".test.ts")) {
      found.push(relative(repoRoot, join(dir, entry.name)));
    }
  }
  return found;
}

const ignoredAlways = (name: string) => name === "node_modules" || name === ".git" || name === "dist";

/** This repo's own test files: the walk a correct collection would make. */
const ownTestFiles = testFilesUnder(repoRoot, (name) => ignoredAlways(name) || name === ".claude");

/** Everything vitest's DEFAULT include would have reached, nested checkouts and all. */
const everythingReachable = testFilesUnder(repoRoot, ignoredAlways);

describe("what pnpm test collects (#3120)", () => {
  it("is configured with an include naming this repo's own tests", () => {
    const configPath = join(repoRoot, "vitest.config.ts");
    expect(
      existsSync(configPath),
      "vitest.config.ts must exist, or vitest falls back to a default include that reaches every nested checkout",
    ).toBe(true);

    const config = readFileSync(configPath, "utf8")
      .split("\n")
      .map((line) => line.replace(/(^|\s)\/\/.*$/, ""))
      .join("\n");

    const includeBlock = config.match(/include:\s*\[([^\]]*)\]/);
    expect(includeBlock, "vitest.config.ts must set an explicit `include`").not.toBeNull();

    const patterns = [...(includeBlock as RegExpMatchArray)[1].matchAll(/["'`]([^"'`]+)["'`]/g)].map(
      (m) => m[1],
    );
    expect(patterns.length, "the include must name at least one pattern").toBeGreaterThan(0);

    // The property that matters, asserted on every pattern rather than on the first: a pattern anchored
    // at a directory of this repo cannot reach into a nested checkout, whatever that checkout is called.
    for (const pattern of patterns) {
      expect(
        pattern.startsWith("src/"),
        `include pattern ${pattern} is not anchored inside src/, so it can reach a nested checkout`,
      ).toBe(true);
    }
  });

  // The other half, and without it the include above would silently SKIP a real test file added
  // outside src/. An include is only correct while it still names everywhere the tests are.
  it("finds no test file of this repo's own outside where the include looks", () => {
    expect(
      ownTestFiles.length,
      "the walk found no test files at all, which cannot be true and would make every assertion here vacuous",
    ).toBeGreaterThanOrEqual(16);

    const strays = ownTestFiles.filter((path) => !path.startsWith(`src${sep}`));
    expect(
      strays,
      "these test files live outside src/, so the include in vitest.config.ts would not collect them",
    ).toEqual([]);
  });

  // Proof that the exclusion is doing something, on a machine where there is something to exclude.
  // Where there is not (a fresh clone, CI), the two walks agree and there is nothing to assert, which is
  // said in words rather than left as a silently passing test.
  it("reaches nothing outside this repo's own tree, and says when there was nothing to reach", () => {
    const extra = everythingReachable.filter((path) => !ownTestFiles.includes(path));
    if (extra.length === 0) {
      expect(everythingReachable.sort()).toEqual(ownTestFiles.sort());
      return;
    }
    // Every file the default include would have added must be one this repo does not own.
    for (const path of extra) {
      expect(
        path.startsWith(`.claude${sep}`),
        `${path} is reachable by a default include and is not a nested checkout, so it is unaccounted for`,
      ).toBe(true);
    }
  });
});
