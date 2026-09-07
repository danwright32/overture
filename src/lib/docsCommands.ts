// #553: AGENTS.md is the file that tells every agent (and Dan) which commands to run, and nothing
// checked that those commands still exist. When one gets renamed, the doc keeps confidently naming
// the old one and every future session follows a stale instruction, burning time rediscovering the
// truth. That is not hypothetical: this milestone's documentation batch (#494, #495, #496, #502) was
// four instances of exactly this, including pnpm scripts that simply did not exist, each found only
// by a manual audit.
//
// These extractors are pure so the checking lives in a test (src/lib/docsCommands.test.ts), which
// runs in `pnpm test` and therefore in CI, rather than in a script nobody remembers to run.

import { readdirSync } from "node:fs";
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

// #3640: the path may be NESTED. The split moved every body under docs/agents/, so the pointers this
// guard exists to check are all one directory down. The old expression stopped at the first slash and
// simply returned a shorter list, which is the failure that hides: a guard covering less reads exactly
// like a guard finding nothing wrong (L96, L98).
export function docPathsIn(markdown: string): string[] {
  const found = new Set<string>();
  for (const m of markdown.matchAll(/(?:\.\/)?(docs\/(?:[A-Za-z0-9._-]+\/)*[A-Za-z0-9._-]+\.md)/g)) {
    found.add(m[1]);
  }
  return [...found].sort();
}

// The files that STEER a session: the index, plus every topic file it points at.
//
// #3640 split AGENTS.md because it had passed the character limit for a file loaded into every
// session. The commands did not stop being documented, they moved, so anything that still read only
// AGENTS.md would keep passing while checking a fraction of what it used to.
//
// Read from DISK rather than listed here, so a seventh topic file joins the check the day it is
// written rather than the day somebody remembers to add it (L41, L96). An empty or missing topic
// directory THROWS rather than returning just the index, because "the split was reverted" and "the
// scan found nothing" would otherwise be the same silent, passing result (L98).
export function steeringDocPaths(repoRoot: string): string[] {
  const dir = "docs/agents";
  let entries: string[];
  try {
    entries = readdirSync(join(repoRoot, dir));
  } catch (cause) {
    throw new Error(
      `${dir}/ could not be read, so the steering docs cannot be checked. ` +
        `AGENTS.md points at it for every rule whose body was split out in #3640.`,
      { cause },
    );
  }
  const topics = entries
    .filter((name) => name.endsWith(".md"))
    .map((name) => `${dir}/${name}`)
    .sort();
  if (topics.length === 0) {
    throw new Error(
      `${dir}/ holds no .md files, so this check would silently cover the index alone. ` +
        `Either the split was undone, or the topic files moved.`,
    );
  }
  return ["AGENTS.md", ...topics];
}

// Where a documented script path may legitimately live. AGENTS.md documents
// `./scripts/run-tests-locked.sh` immediately after telling you to `cd mac`, so a path written
// relative to the repo root and one written relative to mac/ are BOTH honest; resolving against both
// is the truthful reading, not a loophole. A path that resolves in neither is genuinely wrong.
export function candidatePathsFor(scriptPath: string): string[] {
  return [scriptPath, `mac/${scriptPath}`];
}
