// #553: AGENTS.md is the file that tells every agent (and Dan) which commands to run, and nothing
// checked that those commands still exist. When one gets renamed, the doc keeps confidently naming
// the old one and every future session follows a stale instruction, burning time rediscovering the
// truth. That is not hypothetical: this milestone's documentation batch (#494, #495, #496, #502) was
// four instances of exactly this, including pnpm scripts that simply did not exist, each found only
// by a manual audit.
//
// These extractors are pure so the checking lives in a test (src/lib/docsCommands.test.ts), which
// runs in `pnpm test` and therefore in CI, rather than in a script nobody remembers to run.

import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";

// pnpm subcommands that are pnpm's OWN, not entries in package.json's "scripts". Documenting
// `pnpm install` must not be read as a claim that an "install" script exists.

const PNPM_BUILTINS = new Set([
  "install",
  "add",
  "remove",
  "update",
  "up",
  "run",
  "exec",
  "dlx",
  "why",
  "outdated",
  "store",
  "link",
  "publish",
  "init",
]);

// Every `pnpm <script>` the markdown documents, deduped, minus pnpm's own subcommands.
export function pnpmScriptsIn(markdown: string): string[] {
  const found = new Set<string>();
  for (const m of markdown.matchAll(/\bpnpm\s+([a-z][a-z0-9:_-]*)/g)) {
    const name = m[1];
    if (!PNPM_BUILTINS.has(name)) found.add(name);
  }
  return [...found].sort();
}

// Every shell/TS script path the markdown names, deduped. A leading "./" is dropped so
// `./scripts/x.sh` and `scripts/x.sh` are one entry.
export function scriptPathsIn(markdown: string): string[] {
  const found = new Set<string>();
  for (const m of markdown.matchAll(/(?:\.\/)?((?:mac\/)?scripts\/[A-Za-z0-9._-]+\.(?:sh|ts))/g)) {
    found.add(m[1]);
  }
  return [...found].sort();
}

// One nested directory level is allowed because #3640 put the bodies of AGENTS.md under
// docs/agents/. Before that this pattern stopped at the first slash, so every pointer the new index
// is MADE of (`docs/agents/testing.md` and its five siblings) was invisible to the guard whose whole
// job is catching a doc path that no longer resolves.
export function docPathsIn(markdown: string): string[] {
  const found = new Set<string>();
  for (const m of markdown.matchAll(
    /(?:\.\/)?(docs\/(?:[A-Za-z0-9._-]+\/)?[A-Za-z0-9._-]+\.md)/g,
  )) {
    found.add(m[1]);
  }
  return [...found].sort();
}

// Where a documented script path may legitimately live. AGENTS.md documents
// `./scripts/run-tests-locked.sh` immediately after telling you to `cd mac`, so a path written
// relative to the repo root and one written relative to mac/ are BOTH honest; resolving against both
// is the truthful reading, not a loophole. A path that resolves in neither is genuinely wrong.
export function candidatePathsFor(scriptPath: string): string[] {
  return [scriptPath, `mac/${scriptPath}`];
}

// The files Claude Code loads automatically, in the order a reader meets them: AGENTS.md, which is
// now an index, then the topic files holding the bodies #3640 moved out of it. This one is NOT a
// pure extractor like the rest of this module, deliberately: the corpus is DERIVED from the
// directory rather than listed in a constant, so a seventh topic file joins every check by existing
// rather than by somebody remembering to add it to a registry (L96). A directory that is missing
// entirely returns just AGENTS.md, which the caller's own coverage assertion then refuses.
export function agentInstructionFiles(repoRoot: string): string[] {
  const topicsDir = join(repoRoot, "docs", "agents");
  let topics: string[] = [];
  if (existsSync(topicsDir)) {
    topics = readdirSync(topicsDir)
      .filter((name) => name.endsWith(".md"))
      .sort()
      .map((name) => `docs/agents/${name}`);
  }
  return ["AGENTS.md", ...topics];
}
