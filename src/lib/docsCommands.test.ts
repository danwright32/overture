import { describe, it, expect } from "vitest";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import {
  pnpmScriptsIn,
  scriptPathsIn,
  docPathsIn,
  candidatePathsFor,
  steeringDocPaths,
} from "./docsCommands";

// #553: the guard on AGENTS.md itself. It is the file that steers every agent session, and until now
// nothing checked that the commands it confidently names still exist. #494, #495, #496 and #502 were
// four separate instances of that drift, including pnpm scripts that did not exist, each caught only
// by a manual audit long after the fact.
//
// This fails the build the moment a documented command goes missing, which is the whole point: the
// cost of stale instructions is paid by every future session, silently.

const repoRoot = join(__dirname, "..", "..");

// #3640: AGENTS.md was split into an index plus topic files under docs/agents/, because it had passed
// the character limit for a file loaded into every session. The commands did not stop being
// documented, they moved, so a guard that still read only AGENTS.md would keep passing while covering
// a fraction of what it did. An exemption that is correct still leaves its content with no reviewer
// unless one is named in the same change (L129).
//
// The list comes from DISK rather than from a constant here, so a seventh topic file is covered the
// day it is written rather than the day somebody remembers this test (L96).
const steeringDocs = steeringDocPaths(repoRoot);
const steeringText = steeringDocs
  .map((p) => readFileSync(join(repoRoot, p), "utf8"))
  .join("\n");
const agentsMd = steeringText;
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

  // #3640: the split put the bodies under docs/agents/, so every pointer in AGENTS.md now names a
  // NESTED path. The extractor stopped one directory short, which is the worst shape for this: it
  // returns a shorter list rather than an error, so the guard goes on passing while the paths it was
  // written to check are exactly the ones it can no longer see (L96).
  it("finds a doc path in a subdirectory", () => {
    expect(docPathsIn("read `docs/agents/testing.md` before the run")).toEqual([
      "docs/agents/testing.md",
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
  // A scan that read no files and a tree with nothing to find leave the same empty result, and the
  // emptiest possible failure must not read as the cleanest possible pass (L98).
  it("reads the index AND its topic files, not the index alone", () => {
    expect(steeringDocs).toContain("AGENTS.md");
    expect(steeringDocs.filter((p) => p.startsWith("docs/agents/")).length).toBeGreaterThan(1);
  });

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

  // The half that #3640 could have lost silently: a stale script path written in a TOPIC file rather
  // than in the index.
  it("would catch a script named only in a topic file", () => {
    const stale = scriptPathsIn("run `scripts/gone-from-a-topic-file.sh`")[0];
    expect(stale).toBe("scripts/gone-from-a-topic-file.sh");
    expect(candidatePathsFor(stale).some((p) => existsSync(join(repoRoot, p)))).toBe(false);
  });
});
