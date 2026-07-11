import { describe, it, expect } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import {
  pnpmScriptsIn,
  scriptPathsIn,
  docPathsIn,
  candidatePathsFor,
} from "./docsCommands";

// #553: the guard on AGENTS.md itself. It is the file that steers every agent session, and until now
// nothing checked that the commands it confidently names still exist. #494, #495, #496 and #502 were
// four separate instances of that drift, including pnpm scripts that did not exist, each caught only
// by a manual audit long after the fact.
//
// This fails the build the moment a documented command goes missing, which is the whole point: the
// cost of stale instructions is paid by every future session, silently.

const repoRoot = join(__dirname, "..", "..");
const agentsMd = readFileSync(join(repoRoot, "AGENTS.md"), "utf8");
const packageJson = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8"));

describe("extractors", () => {
  it("finds the pnpm scripts a doc names", () => {
    expect(pnpmScriptsIn("run `pnpm typecheck`, then `pnpm test`")).toEqual([
      "test",
      "typecheck",
    ]);
  });

  // Documenting `pnpm install` is not a claim that an "install" script exists in package.json.
  it("ignores pnpm's own subcommands", () => {
    expect(pnpmScriptsIn("first `pnpm install`, then `pnpm add -D vitest`")).toEqual([]);
  });

  it("finds script paths with or without a leading ./", () => {
    expect(scriptPathsIn("run ./scripts/test-all.sh and mac/scripts/x.sh and scripts/test-all.sh"))
      .toEqual(["mac/scripts/x.sh", "scripts/test-all.sh"]);
  });

  it("finds doc paths", () => {
    expect(docPathsIn("see `docs/contracts.md` and docs/contracts.md")).toEqual([
      "docs/contracts.md",
    ]);
  });

  // A script may be documented relative to the repo root OR to mac/, because AGENTS.md names
  // ./scripts/run-tests-locked.sh right after telling you to cd mac.
  it("offers both the root and the mac/ reading of a script path", () => {
    expect(candidatePathsFor("scripts/run-tests-locked.sh")).toEqual([
      "scripts/run-tests-locked.sh",
      "mac/scripts/run-tests-locked.sh",
    ]);
  });
});

describe("AGENTS.md documents only commands that actually exist", () => {
  it("names at least one pnpm script (proves the check is not passing vacuously)", () => {
    expect(pnpmScriptsIn(agentsMd).length).toBeGreaterThan(0);
    expect(scriptPathsIn(agentsMd).length).toBeGreaterThan(0);
  });

  it.each(pnpmScriptsIn(agentsMd))(
    "`pnpm %s` resolves to a real script in package.json",
    (script) => {
      expect(Object.keys(packageJson.scripts)).toContain(script);
    },
  );

  it.each(scriptPathsIn(agentsMd))("`%s` exists on disk", (scriptPath) => {
    const resolved = candidatePathsFor(scriptPath).some((p) =>
      existsSync(join(repoRoot, p)),
    );
    expect(resolved).toBe(true);
  });

  it.each(docPathsIn(agentsMd))("`%s` exists on disk", (docPath) => {
    expect(existsSync(join(repoRoot, docPath))).toBe(true);
  });
});

// The check has to be able to FAIL, or it is decoration. Proves it catches each drift it exists for.
describe("the check actually catches drift", () => {
  it("would catch a pnpm script that no longer exists", () => {
    const stale = pnpmScriptsIn("run `pnpm lint` before pushing");
    expect(stale).toEqual(["lint"]);
    expect(Object.keys(packageJson.scripts)).not.toContain("lint");
  });

  it("would catch a script path that no longer exists", () => {
    const stale = scriptPathsIn("run `scripts/deploy-to-prod.sh`")[0];
    const resolved = candidatePathsFor(stale).some((p) => existsSync(join(repoRoot, p)));
    expect(resolved).toBe(false);
  });

  it("would catch a doc that no longer exists", () => {
    expect(existsSync(join(repoRoot, docPathsIn("see `docs/gone.md`")[0]))).toBe(false);
  });
});
